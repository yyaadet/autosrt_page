import AVFoundation
import AppKit
import Combine
import Foundation
import SwiftUI
import ffmpegkit

@MainActor
class SubtitleViewModel: ObservableObject {
    private let whisperService = WhisperService.shared
    private let videoService = VideoService.shared
    private let logger = LoggerService.shared
    private let translationService = TranslationService.shared
    private let notificationCenter = NSUserNotificationCenter.default
    private let analytics = AnalyticsService.shared
    private let wordService = WordService.shared
    private let settings = Settings.shared

    private static let subtitlesFileName = "subtitles.json"
    private static let editingSubtitlesFileName = "editing_subtitles.json"
    private static let selectedVideoURLKey = "LastSelectedVideoURL"
    private static let selectedTargetLanguageKey = "SelectedTargetLanguage"
    private static let selectedSourceLanguageKey = "SelectedSourceLanguage"
    private static let selectedFontSizeKey = "SelectedFontSize"
    private static let selectedQualityKey = "SelectedQuality"
    private static let playerTimeKey = "PlayerTime"
    private static let autoReTranslateKey = "AutoReTranslate"
    private static let autoTranslateAfterAsrKey = "AutoTranslateAfterAsr"
    private let userDefaults = UserDefaults.standard

    // Use Application Support directory for storing subtitle files
    private var applicationSupportDirectory: URL {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[
            0]
        // Ensure the directory exists
        try? FileManager.default.createDirectory(
            at: url, withIntermediateDirectories: true, attributes: nil)
        return url
    }

    private var subtitlesFileURL: URL {
        applicationSupportDirectory.appendingPathComponent(Self.subtitlesFileName)
    }
    private var editingSubtitlesFileURL: URL {
        applicationSupportDirectory.appendingPathComponent(Self.editingSubtitlesFileName)
    }

    enum SubtitleFontSize: String, CaseIterable {
        case small = "Small"
        case medium = "Medium"
        case large = "Large"

        var multiplier: Double {
            switch self {
            case .small: return 0.8
            case .medium: return 1.0
            case .large: return 1.2
            }
        }

        var pointSize: Double {
            return Settings.shared.videoService.fontSize * multiplier
        }
    }

    enum SubtitleFormat: String, CaseIterable {
        case srt = "SRT"
        case ass = "ASS"
    }

    struct SubtitleStatistics {
        var totalSubtitles: Int
        var translatedCount: Int
        var translatedRatio: Double {
            return Double(translatedCount) / Double(totalSubtitles)
        }
        var sourceCharacterCount: Int
        var targetCharacterCount: Int
    }

    @Published var subtitles: [Subtitle] = []
    @Published var editingSubtitles: [Subtitle] = []
    @Published var subtitleStatistics: SubtitleStatistics = .init(
        totalSubtitles: 0,
        translatedCount: 0,
        sourceCharacterCount: 0,
        targetCharacterCount: 0
    )
    @Published var isProcessing = false
    @Published var progress: Double = 0
    @Published var processedVideoURL: URL?
    @Published var tipsMessage: String = ""
    @Published var statusMessage: String = ""
    @Published var errorMessage: String?
    @Published var isInitialized = false
    @Published var player: AVPlayer?
    @Published var selectedQuality: VideoQuality = .high
    @Published var selectedVideoURL: URL?
    @Published var selectedFontSize: SubtitleFontSize = .medium
    @Published var sourceLanguage: Language = .None
    @Published var targetLanguage: Language = .SimplifiedChinese
    @Published var showingSubtitleEditor = false {
        didSet {
            if showingSubtitleEditor {
                analytics.trackEvent(
                    .subtitleEditViewOpened,
                    parameters: [
                        "subtitle_count": subtitles.count,
                        "source_language": sourceLanguage.rawValue,
                        "target_language": targetLanguage.rawValue,
                    ])
            }
        }
    }
    @Published var videoRendered = false
    @Published var availableModels: [String] = []
    @Published var selectedModel: String = Settings.shared.llmService.chatModel
    @Published var playerTime: Double = 0
    @Published var currentSubtitleIndex = -1
    @Published var autoReTranslate = false {
        didSet {
            userDefaults.set(autoReTranslate, forKey: Self.autoReTranslateKey)
        }
    }
    /// When true, "Generate Subtitles" does ASR + translate in one go (old behavior).
    /// When false, ASR only — user clicks "Translate" separately (new behavior).
    @Published var autoTranslateAfterAsr = false {
        didSet {
            userDefaults.set(autoTranslateAfterAsr, forKey: Self.autoTranslateAfterAsrKey)
        }
    }
    private var timeObserverToken: Any?
    private var generationTask: Task<Void, Never>?

    init() {
        restoreState()
    }

    /// True when source subtitles exist, user is not busy, and target language is set.
    /// UI can show / enable the "Translate" button based on this.
    var canTranslate: Bool {
        !subtitles.isEmpty && !isProcessing && targetLanguage != .None
    }

    /// True when at least one subtitle needs re-translation (source was edited post-translation).
    /// Checks both editingSubtitles (in-editor edits) and subtitles (saved edits).
    var hasNeedsRetranslation: Bool {
        editingSubtitles.contains { $0.needsRetranslation }
            || subtitles.contains { $0.needsRetranslation }
    }

    /// True when source subtitles exist and at least one lacks a translation.
    var hasUntranslatedSubtitles: Bool {
        !subtitles.isEmpty && subtitles.contains { !$0.isTranslated }
    }

    /// Stop the currently running subtitle generation (transcription + translation).
    func stopGeneration() {
        logger.log("User requested stop of subtitle generation")
        generationTask?.cancel()
        generationTask = nil
        isProcessing = false
        statusMessage = "Generation cancelled"
    }

    private func restoreState() {
        // Restore selected video URL
        if let urlString = userDefaults.string(forKey: Self.selectedVideoURLKey),
            let url = URL(string: urlString)
        {
            logger.log("Restoring video URL: \(urlString)")
            doSelectVideo(url)
        }

        // Restore subtitles from file
        if FileManager.default.fileExists(atPath: subtitlesFileURL.path) {
            do {
                let data = try Data(contentsOf: subtitlesFileURL)
                let decodedSubtitles = try JSONDecoder().decode([Subtitle].self, from: data)
                logger.log("Successfully restored \(decodedSubtitles.count) subtitles from file")
                subtitles = decodedSubtitles
                updateSubtitleStatistics()
            } catch {
                logger.log("Failed to decode subtitles from file: \(error)", level: .error)
            }
        }

        // Restore editing subtitles from file
        if FileManager.default.fileExists(atPath: editingSubtitlesFileURL.path) {
            do {
                let data = try Data(contentsOf: editingSubtitlesFileURL)
                let decodedSubtitles = try JSONDecoder().decode([Subtitle].self, from: data)
                logger.log(
                    "Successfully restored \(decodedSubtitles.count) editing subtitles from file")
                editingSubtitles = decodedSubtitles
            } catch {
                logger.log("Failed to decode editing subtitles from file: \(error)", level: .error)
            }
        }

        // Restore selected target language
        if let language = userDefaults.string(forKey: Self.selectedTargetLanguageKey) {
            self.targetLanguage = Language(rawValue: language) ?? .SimplifiedChinese
        }
        // Restore selected source language
        if let language = userDefaults.string(forKey: Self.selectedSourceLanguageKey) {
            self.sourceLanguage = Language(rawValue: language) ?? .English
        }
        // Restore selected font size
        if let raw = userDefaults.string(forKey: Self.selectedFontSizeKey),
            let size = SubtitleFontSize(rawValue: raw)
        {
            self.selectedFontSize = size
        }
        // Restore selected quality
        if let raw = userDefaults.string(forKey: Self.selectedQualityKey),
            let quality = VideoQuality(rawValue: raw)
        {
            self.selectedQuality = quality
        }
        // Restore player time
        let time = userDefaults.double(forKey: Self.playerTimeKey)
        if time > 0 {
            self.playerTime = time
            self.player?.seek(to: CMTime(seconds: time, preferredTimescale: 1))
        }

        autoReTranslate = userDefaults.bool(forKey: Self.autoReTranslateKey)
        autoTranslateAfterAsr = userDefaults.bool(forKey: Self.autoTranslateAfterAsrKey)

        if editingSubtitles.isEmpty {
            editingSubtitles = subtitles
        }
    }

    public func persistState() {
        // Only clear user defaults if its size is larger than 4MB
        if let appDomain = Bundle.main.bundleIdentifier {
            let prefsPath = ("~/Library/Preferences/" + appDomain + ".plist")
                .replacingOccurrences(
                    of: "~", with: NSHomeDirectory())
            if let attrs = try? FileManager.default.attributesOfItem(atPath: prefsPath),
                let fileSize = attrs[.size] as? UInt64
            {
                logger.log("UserDefaults plist size: \(fileSize) bytes", level: .info)
                if fileSize >= 4 * 1024 * 1024 {
                    UserDefaults.standard.removePersistentDomain(forName: appDomain)
                    UserDefaults.standard.synchronize()
                    logger.log("UserDefaults cleared due to exceeding 4MB", level: .warning)
                }
            }
        }

        // Save selected video URL
        userDefaults.set(selectedVideoURL?.absoluteString, forKey: Self.selectedVideoURLKey)

        // Save subtitles to file
        do {
            let data = try JSONEncoder().encode(subtitles)
            try data.write(to: subtitlesFileURL, options: .atomic)
            logger.log("Successfully persisted \(subtitles.count) subtitles to file")
        } catch {
            logger.log("Failed to encode or write subtitles to file: \(error)", level: .error)
        }

        // Save editing subtitles to file
        do {
            let data = try JSONEncoder().encode(editingSubtitles)
            try data.write(to: editingSubtitlesFileURL, options: .atomic)
            logger.log(
                "Successfully persisted \(editingSubtitles.count) editing subtitles to file")
        } catch {
            logger.log(
                "Failed to encode or write editing subtitles to file: \(error)", level: .error)
        }

        // Save selected target languages
        userDefaults.set(targetLanguage.rawValue, forKey: Self.selectedTargetLanguageKey)
        // Save selected source languages
        userDefaults.set(sourceLanguage.rawValue, forKey: Self.selectedSourceLanguageKey)
        // Save selected font size
        userDefaults.set(selectedFontSize.rawValue, forKey: Self.selectedFontSizeKey)
        // Save selected quality
        userDefaults.set(selectedQuality.rawValue, forKey: Self.selectedQualityKey)
        // Save player time
        playerTime = self.player?.currentTime().seconds ?? 0
        userDefaults.set(playerTime, forKey: Self.playerTimeKey)

    }

    public func onAppear() {
        logger.log("SubtitleViewModel appeared")

        // Add time observer when view appears
        addPeriodicTimeObserver()

        Task {
            do {
                Task { @MainActor() in
                    self.isInitialized = false
                    self.isProcessing = true
                }
                analytics.trackEvent(.appLaunched)

                // initial WhisperService
                Task { @MainActor() in
                    self.isProcessing = true
                }
                try await WhisperService.shared.initializeModel { downloadProgress in
                    Task { @MainActor in
                        self.progress = downloadProgress.progress
                        var message = "Downloading \(downloadProgress.modelName): \(String(format: "%.1f", downloadProgress.progress * 100))%, \(self.formatBytes(downloadProgress.bytesDownloaded))/\(self.formatBytes(downloadProgress.totalBytes))"
                        if let eta = downloadProgress.estimatedTimeRemaining, eta.isFinite, eta > 0 {
                            message += ", \(self.formatETA(eta)) left"
                        }
                        self.statusMessage = message
                    }
                }

            } catch {
                self.errorMessage = error.localizedDescription
            }

            Task { @MainActor() in
                self.isInitialized = true
                self.isProcessing = false
            }
        }
    }

    public func onDisappear() {
        persistState()

        // Remove time observer when view disappears
        removePeriodicTimeObserver()
    }

    // update subtitle statistics
    private func updateSubtitleStatistics() {
        subtitleStatistics.totalSubtitles = subtitles.count
        subtitleStatistics.translatedCount =
            subtitles.filter {
                !$0.translatedText.isEmpty && $0.translatedText != $0.sourceText
            }.count
        subtitleStatistics.sourceCharacterCount = subtitles.reduce(0) { $0 + $1.sourceText.count }
        subtitleStatistics.targetCharacterCount = subtitles.reduce(0) {
            $0 + $1.translatedText.count
        }
    }

    private func cleanupPlayer() {
        // Remove time observer before cleaning up player
        removePeriodicTimeObserver()

        if let existingPlayer = player {
            existingPlayer.pause()
            NotificationCenter.default.removeObserver(
                self, name: .AVPlayerItemDidPlayToEndTime, object: existingPlayer.currentItem)
            existingPlayer.replaceCurrentItem(with: nil)
            self.player = nil
        }
    }

    /// ASR-only: generate source subtitles. No translation is performed.
    /// User can edit source text first, then call `translateCurrentSubtitles()`.
    func generateSubtitles(_ url: URL) {
        logger.log("Starting video processing: \(url.lastPathComponent)")
        let startTime = Date()

        // Cancel any previous in-flight generation
        generationTask?.cancel()
        generationTask = Task { [weak self] in
            guard let self = self else { return }

            self.analytics.trackEvent(
                .generateSubtitleStarted,
                parameters: [
                    "filename": url.lastPathComponent,
                    "quality": self.selectedQuality.rawValue,
                    "language": self.targetLanguage.rawValue,
                ])

            do {
                self.isProcessing = true
                self.errorMessage = nil
                self.progress = 0
                self.statusMessage = "Processing video..."
                self.selectedModel = self.settings.llmService.chatModel

                try Task.checkCancellation()

                // Extract audio from video
                self.statusMessage = "Extracting audio..."
                let tempWavURL = url.deletingLastPathComponent().appendingPathComponent("audio.wav")
                try await self.whisperService.extractAudio(from: url, to: tempWavURL)

                try Task.checkCancellation()

                self.statusMessage = "Transcribing audio..."
                self.progress = 0.5
                self.subtitles = try await self.whisperService.transcribeOnly(
                    audioFile: tempWavURL, sourceLanguage: self.sourceLanguage
                ) { [weak self] output, sub_progress in
                    Task { @MainActor in
                        guard let self = self else { return }
                        self.statusMessage = output
                        self.progress = 0.5 + 0.5 * sub_progress
                    }
                }

                try Task.checkCancellation()

                self.editingSubtitles = self.subtitles
                self.updateSubtitleStatistics()
                self.persistState()

                try? self.saveSubtitles(videoURL: url, format: .srt)

                let outputVideoURL = self.getVideoOutputURL(videoURL: url)
                try? FileManager.default.removeItem(at: outputVideoURL)

                try? FileManager.default.removeItem(at: tempWavURL)

                let timeSpent = Date().timeIntervalSince(startTime)
                let timeString = String(format: "%.1f seconds", timeSpent)

                // Auto-translate after ASR if enabled
                if self.autoTranslateAfterAsr && self.targetLanguage != .None {
                    self.statusMessage = "Transcription done, starting translation..."
                    self.isProcessing = false
                    // Dispatch after a tick so the current Task unwinds before translate starts
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                        self?.translateCurrentSubtitles()
                    }
                    return
                }

                self.statusMessage = "Source subtitles generated (Time spent: \(timeString))"
                self.isProcessing = false

                self.analytics.trackEvent(
                    .generateSubtitleCompleted,
                    parameters: [
                        "video_name": url.lastPathComponent,
                        "quality": self.selectedQuality.presetName,
                        "processing_time": timeSpent,
                        "subtitle_count": self.subtitles.count,
                    ])

                let notification = NSUserNotification()
                notification.title = "Source Subtitles Generated."
                notification.subtitle = "Time spent: \(timeString)"
                notification.informativeText = "Edit source text, then tap Translate."
                notification.soundName = NSUserNotificationDefaultSoundName
                self.notificationCenter.deliver(notification)
            } catch is CancellationError {
                await MainActor.run {
                    self.isProcessing = false
                    self.statusMessage = "Generation cancelled"
                }
                logger.log("Subtitle generation cancelled by user", level: .info)

            } catch WhisperServiceError.modelNotFound {
                await MainActor.run {
                    self.errorMessage =
                        "Whisper model not found. Please ensure the model file is in the correct location."
                    let timeSpent = Date().timeIntervalSince(startTime)
                    self.statusMessage =
                        "Error: Model not found (Time: \(String(format: "%.1fs", timeSpent)))"
                    self.isProcessing = false
                }
                logger.log("Error: Whisper model not found", level: .error)
                self.analytics.trackError(
                    WhisperServiceError.modelNotFound("Model file not found"),
                    context: "model_not_found")

            } catch WhisperServiceError.audioExtractionFailed(let reason) {
                await MainActor.run {
                    self.errorMessage = "Failed to extract audio: \(reason)"
                    let timeSpent = Date().timeIntervalSince(startTime)
                    self.statusMessage =
                        "Error: Audio extraction failed (Time: \(String(format: "%.1fs", timeSpent)))"
                    self.isProcessing = false
                }
                logger.log("Error: Audio extraction failed - \(reason)", level: .error)
                self.analytics.trackError(
                    WhisperServiceError.audioExtractionFailed(reason),
                    context: "audio_extraction_failed")

            } catch WhisperServiceError.transcriptionFailed {
                await MainActor.run {
                    self.errorMessage = "Failed to transcribe audio. Please try again."
                    let timeSpent = Date().timeIntervalSince(startTime)
                    self.statusMessage =
                        "Error: Transcription failed (Time: \(String(format: "%.1fs", timeSpent)))"
                    self.isProcessing = false
                }
                logger.log("Error: Transcription failed", level: .error)
                self.analytics.trackError(
                    WhisperServiceError.transcriptionFailed("Transcription failed"),
                    context: "transcription_failed")

            } catch {
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                    let timeSpent = Date().timeIntervalSince(startTime)
                    self.statusMessage =
                        "Error: Unexpected error occurred (Time: \(String(format: "%.1fs", timeSpent)))"
                    self.isProcessing = false
                }
                logger.log("Unexpected error: \(error.localizedDescription)", level: .error)
                self.analytics.trackError(error, context: "unexpected_error")
            }
        }
    }

    /// Translate existing source subtitles into the target language.
    /// Call this after `generateSubtitles()` + user edits.
    func translateCurrentSubtitles() {
        guard !subtitles.isEmpty else { return }
        guard targetLanguage != .None else {
            statusMessage = "No target language selected — translation skipped."
            return
        }

        logger.log("Starting translation of \(subtitles.count) subtitles")
        let startTime = Date()

        generationTask?.cancel()
        generationTask = Task { [weak self] in
            guard let self = self else { return }

            do {
                self.isProcessing = true
                self.errorMessage = nil
                self.progress = 0
                self.statusMessage = "Translating subtitles..."

                let translated = try await self.translationService.translateSubtitles(
                    self.subtitles,
                    fromLanguage: self.sourceLanguage.target,
                    toLanguage: self.targetLanguage.target,
                    model: self.settings.llmService.chatModel,
                    progressCallback: { [weak self] progress, message in
                        Task { @MainActor in
                            self?.progress = progress
                            self?.statusMessage = message
                        }
                    }
                )

                for i in self.subtitles.indices {
                    if i < translated.count {
                        self.subtitles[i].translatedText = translated[i].translatedText
                        self.subtitles[i].needsRetranslation = false
                    }
                }
                self.editingSubtitles = self.subtitles
                self.updateSubtitleStatistics()
                self.persistState()
                if let videoURL = self.selectedVideoURL {
                    try? self.saveSubtitles(videoURL: videoURL, format: .srt)
                }

                let timeSpent = Date().timeIntervalSince(startTime)
                let timeString = String(format: "%.1f seconds", timeSpent)
                self.statusMessage = "Translation done (Time spent: \(timeString))"
                self.isProcessing = false

                self.analytics.trackEvent(
                    .generateSubtitleCompleted,
                    parameters: [
                        "translation_time": timeSpent,
                        "subtitle_count": self.subtitles.count,
                    ])

                let notification = NSUserNotification()
                notification.title = "Translation Complete."
                notification.subtitle = "Time spent: \(timeString)"
                notification.informativeText = "Bilingual subtitles ready."
                notification.soundName = NSUserNotificationDefaultSoundName
                self.notificationCenter.deliver(notification)
            } catch is CancellationError {
                await MainActor.run {
                    self.isProcessing = false
                    self.statusMessage = "Translation cancelled"
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                    self.statusMessage = "Translation failed: \(error.localizedDescription)"
                    self.isProcessing = false
                }
                self.logger.log("Translation error: \(error.localizedDescription)", level: .error)
                self.analytics.trackError(error, context: "translation_error")
            }
        }
    }

    /// Re-translate only subtitles whose source was edited after the initial translation.
    func reTranslateEditedSubtitles() {
        // Check editingSubtitles — that's where user edits happen during editing
        let needRetranslation = editingSubtitles.filter { $0.needsRetranslation }
        guard !needRetranslation.isEmpty else {
            statusMessage = "No subtitles need re-translation."
            return
        }
        guard targetLanguage != .None else {
            statusMessage = "No target language selected."
            return
        }

        logger.log("Re-translating \(needRetranslation.count) edited subtitles")
        let startTime = Date()

        generationTask?.cancel()
        generationTask = Task { [weak self] in
            guard let self = self else { return }

            do {
                self.isProcessing = true
                self.errorMessage = nil
                self.progress = 0
                self.statusMessage = "Re-translating \(needRetranslation.count) edited subtitles..."

                let translated = try await self.translationService.translateSubtitles(
                    needRetranslation,
                    fromLanguage: self.sourceLanguage.target,
                    toLanguage: self.targetLanguage.target,
                    model: self.settings.llmService.chatModel,
                    progressCallback: { [weak self] progress, message in
                        Task { @MainActor in
                            self?.progress = progress
                            self?.statusMessage = message
                        }
                    }
                )

                for i in needRetranslation.indices {
                    guard i < translated.count else { break }
                    let originalId = needRetranslation[i].id
                    if let idx = self.editingSubtitles.firstIndex(where: { $0.id == originalId }) {
                        self.editingSubtitles[idx].translatedText = translated[i].translatedText
                        self.editingSubtitles[idx].needsRetranslation = false
                    }
                    if let idx = self.subtitles.firstIndex(where: { $0.id == originalId }) {
                        self.subtitles[idx].translatedText = translated[i].translatedText
                        self.subtitles[idx].needsRetranslation = false
                    }
                }
                self.updateSubtitleStatistics()
                self.persistState()
                if let videoURL = self.selectedVideoURL {
                    try? self.saveSubtitles(videoURL: videoURL, format: .srt)
                }

                let timeSpent = Date().timeIntervalSince(startTime)
                let timeString = String(format: "%.1f seconds", timeSpent)
                self.statusMessage = "Re-translation done (Time spent: \(timeString))"
                self.isProcessing = false

                let notification = NSUserNotification()
                notification.title = "Re-translation Complete."
                notification.subtitle = "\(needRetranslation.count) subtitles updated."
                notification.informativeText = "Time spent: \(timeString)"
                notification.soundName = NSUserNotificationDefaultSoundName
                self.notificationCenter.deliver(notification)
            } catch is CancellationError {
                await MainActor.run {
                    self.isProcessing = false
                    self.statusMessage = "Re-translation cancelled"
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                    self.statusMessage = "Re-translation failed: \(error.localizedDescription)"
                    self.isProcessing = false
                }
                self.logger.log("Re-translation error: \(error.localizedDescription)", level: .error)
                self.analytics.trackError(error, context: "retranslation_error")
            }
        }
    }

    func renderVideoWithSubtitles(videoURL: URL, srtURL: URL) async {
        logger.log("Starting rendering video: \(videoURL.lastPathComponent)")
        let startTime = Date()

        do {
            videoRendered = false
            isProcessing = true
            errorMessage = nil
            progress = 0
            statusMessage = "Rendering video..."

            analytics.trackEvent(
                .videoRenderingStarted,
                parameters: [
                    "video_name": videoURL.lastPathComponent,
                    "quality": selectedQuality.presetName,
                ])

            // save subtitles to ass file
            try? saveSubtitles(videoURL: videoURL, format: .ass)

            let videoOuputURL = getVideoOutputURL(videoURL: videoURL)

            // Remove existing files if needed
            try? FileManager.default.removeItem(at: videoOuputURL)

            // Render video with subtitles
            try await videoService.renderSubtitledVideo(
                videoURL: videoURL,
                subtitlesURL: srtURL,
                outputURL: videoOuputURL,
                quality: selectedQuality,
                fontSize: getFontSize(videoURL: videoURL, size: selectedFontSize)
            ) { [weak self] renderProgress in
                Task { @MainActor in
                    self?.progress = renderProgress * 0.5
                    self?.statusMessage = "Rendering video: \(Int(renderProgress * 100))%"
                }
            }

            // Audio enhance
            if settings.videoService.enhanceVoice {
                // Move videoOuput to a tmp location
                let tempVideoOuputURL = videoOuputURL.deletingLastPathComponent()
                    .appendingPathComponent("temp.mp4")
                try? FileManager.default.removeItem(at: tempVideoOuputURL)
                try? FileManager.default.moveItem(at: videoOuputURL, to: tempVideoOuputURL)

                try await AudioEnhancementService.shared.enhanceAudio(
                    inputURL: tempVideoOuputURL,
                    outputURL: videoOuputURL
                ) { [weak self] progress in
                    Task { @MainActor in
                        self?.progress = progress * 0.5 + 0.5
                        self?.statusMessage = "Enhancing audio: \(Int(progress * 100))%"
                    }
                }

                // remove temp video output
                try? FileManager.default.removeItem(at: tempVideoOuputURL)
            }

            // Update completion status
            let timeSpent = Date().timeIntervalSince(startTime)
            let timeString = String(format: "%.1f seconds", timeSpent)

            statusMessage = "Render Video Done (Time spent: \(timeString))"
            progress = 1.0
            isProcessing = false
            videoRendered = true

            // Track successful completion
            analytics.trackEvent(
                .videoRenderingCompleted,
                parameters: [
                    "video_name": videoURL.lastPathComponent,
                    "quality": selectedQuality.presetName,
                    "processing_time": timeSpent,
                    "subtitle_count": subtitles.count,
                ])

            // Show completion notification
            let notification = NSUserNotification()
            notification.title = "Video Rendering Complete"
            notification.subtitle = "Time spent: \(timeString)"
            notification.informativeText = "Output: \(videoOuputURL.lastPathComponent)"
            notification.soundName = NSUserNotificationDefaultSoundName
            notificationCenter.deliver(notification)

            // Open output in Finder
            NSWorkspace.shared.selectFile(
                videoOuputURL.path,
                inFileViewerRootedAtPath: (videoOuputURL.deletingLastPathComponent() as NSURL).path!)
        } catch VideoError.compositionFailed(let reason) {
            await MainActor.run {
                errorMessage = "Failed to compose video: \(reason)"
                let timeSpent = Date().timeIntervalSince(startTime)
                statusMessage =
                    "Error: Video composition failed (Time: \(String(format: "%.1fs", timeSpent)))"
                isProcessing = false
            }
            logger.log("Error: Video composition failed - \(reason)", level: .error)
            analytics.trackEvent(
                .videoRenderingFailed,
                parameters: [
                    "error_type": "composition_failed",
                    "error_reason": reason,
                    "video_name": videoURL.lastPathComponent,
                ])

        } catch VideoError.exportFailed(let reason) {
            await MainActor.run {
                errorMessage = "Failed to export video: \(reason)"
                let timeSpent = Date().timeIntervalSince(startTime)
                statusMessage =
                    "Error: Video export failed (Time: \(String(format: "%.1fs", timeSpent)))"
                isProcessing = false
            }
            logger.log("Error: Video export failed - \(reason)", level: .error)
            analytics.trackEvent(
                .videoRenderingFailed,
                parameters: [
                    "error_type": "export_failed",
                    "error_reason": reason,
                    "video_name": videoURL.lastPathComponent,
                ])

        } catch {
            await MainActor.run {
                self.errorMessage = error.localizedDescription
                let timeSpent = Date().timeIntervalSince(startTime)
                statusMessage =
                    "Error: Unexpected error occurred (Time: \(String(format: "%.1fs", timeSpent)))"
                isProcessing = false
            }
            logger.log("Unexpected error: \(error.localizedDescription)", level: .error)
            analytics.trackEvent(
                .videoRenderingFailed,
                parameters: [
                    "error_type": "unexpected",
                    "error_message": error.localizedDescription,
                    "video_name": videoURL.lastPathComponent,
                ])
        }
    }

    public func formatTimecode(_ seconds: TimeInterval) -> String {
        let hours = Int(seconds) / 3600
        let minutes = Int(seconds) / 60 % 60
        let secs = Int(seconds) % 60
        let milliseconds = Int((seconds - floor(seconds)) * 1000)
        return String(format: "%02d:%02d:%02d,%03d", hours, minutes, secs, milliseconds)
    }

    private func formatASSTimecode(_ seconds: Double) -> String {
        let hours = Int(seconds) / 3600
        let minutes = Int((seconds.truncatingRemainder(dividingBy: 3600)) / 60)
        let secs = Int(seconds) % 60
        let centiseconds = Int((seconds - floor(seconds)) * 100)
        return String(format: "%01d:%02d:%02d.%02d", hours, minutes, secs, centiseconds)
    }

    func saveSubtitles(videoURL: URL, format: SubtitleFormat = .srt) throws -> URL? {
        let maxCharactersPerLine = Settings.shared.videoService.maxCharactersPerLine
        let fileURL = format == .srt ? getSRTURL(videoURL: videoURL) : getASSURL(videoURL: videoURL)
        let sourceLanguage = wordService.detectLanguage(from: subtitles[0].sourceText)
        let translatedLanguage = wordService.detectLanguage(from: subtitles[0].translatedText)

        let content: String
        switch format {
        case .srt:
            let (srtContent, _, _) = generateSRTContent(
                maxCharactersPerLine: maxCharactersPerLine,
                sourceLanguage: sourceLanguage,
                translatedLanguage: translatedLanguage)
            content = srtContent
        case .ass:
            content = generateASSContent(
                maxCharactersPerLine: maxCharactersPerLine,
                sourceLanguage: sourceLanguage,
                translatedLanguage: translatedLanguage)
        }

        // Remove existing file if it exists
        if FileManager.default.fileExists(atPath: fileURL.path) {
            try FileManager.default.removeItem(at: fileURL)
        }

        try content.write(to: fileURL, atomically: true, encoding: .utf8)
        logger.log("Successfully exported \(format.rawValue) file to: \(fileURL.path)")
        return fileURL
    }

    private func generateSRTContent(
        maxCharactersPerLine: Int, sourceLanguage: Language, translatedLanguage: Language
    ) -> (String, String, String) {
        var sourceSrtContent: String = ""
        var translationSrtContent: String = ""
        var srtContent: String = ""

        for (index, subtitle) in subtitles.enumerated() {
            let startTime = formatTimecode(subtitle.startTime)
            let endTime = formatTimecode(subtitle.endTime)
            var sourceText = subtitle.sourceText
            if sourceLanguage != .English {
                sourceText = translationService.splitText(
                    subtitle.sourceText, maxCharactersPerLine: maxCharactersPerLine)
            }
            var translatedText = subtitle.translatedText
            if translatedLanguage != .English {
                translatedText = translationService.splitText(
                    subtitle.translatedText, maxCharactersPerLine: maxCharactersPerLine)
            }

            // SRT format: index, timecode, text, blank line
            srtContent += "\(index + 1)\n"
            srtContent += "\(startTime) --> \(endTime)\n"
            srtContent += "\(sourceText)\n"
            if !subtitle.translatedText.isEmpty && subtitle.translatedText != subtitle.sourceText {
                srtContent += "\(translatedText)\n"
            }
            srtContent += "\n"
            // add source and translation content to sourceSrtContent and translationSrtContent
            sourceSrtContent += "\(index + 1)\n"
            sourceSrtContent += "\(startTime) --> \(endTime)\n"
            sourceSrtContent += "\(sourceText)\n"
            sourceSrtContent += "\n"
            translationSrtContent += "\(index + 1)\n"
            translationSrtContent += "\(startTime) --> \(endTime)\n"
            translationSrtContent += "\(translatedText)\n"
            translationSrtContent += "\n"
        }

        return (srtContent, sourceSrtContent, translationSrtContent)
    }

    private func generateASSContent(
        maxCharactersPerLine: Int, sourceLanguage: Language, translatedLanguage: Language
    ) -> String {
        // get video width and height from selected video
        var videoWidth = 1920
        var videoHeight = 1080
        var fontSize = 0
        if let videoURL = selectedVideoURL {
            fontSize = Int(getFontSize(videoURL: videoURL, size: selectedFontSize))
            let videoAsset = AVAsset(url: videoURL)
            if let videoTrack = videoAsset.tracks(withMediaType: .video).first {
                let videoSize = videoTrack.naturalSize
                videoWidth = Int(videoSize.width)
                videoHeight = Int(videoSize.height)
            }
        }
        // get font name
        let fontName = Settings.shared.videoService.fontName
        // get colors in ASS format
        let primaryColor = Settings.shared.videoService.primaryColor.toASSColor()
        let secondaryColor = Settings.shared.videoService.secondaryColor.toASSColor()
        let outlineColor = Settings.shared.videoService.outlineColor.toASSColor()
        let backColor = Settings.shared.videoService.backColor.toASSColor()
        // get outline width
        let outlineWidth = Settings.shared.videoService.outlineWidth
        // get shadow depth
        let shadowDepth = Settings.shared.videoService.shadowDepth
        // get margin horizontal
        let marginHorizontal = Settings.shared.videoService.marginHorizontal
        // get margin bottom
        let marginBottom = Settings.shared.videoService.marginBottom
        // get text scale
        let textScale = Settings.shared.videoService.textScale
        // get border style
        let borderStyle = Settings.shared.videoService.borderStyle

        var assContent = """
            [Script Info]
            ScriptType: v4.00+
            Collisions: Normal
            PlayResX: \(videoWidth)
            PlayResY: \(videoHeight)
            Timer: 100.0000

            [V4+ Styles]
            Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
            Style: Source,\(fontName),\(fontSize),\(primaryColor),\(secondaryColor),\(outlineColor),\(backColor),0,0,0,0,100,100,0,0,\(borderStyle),\(outlineWidth),\(shadowDepth),2,10,10,\(5 + marginBottom),1
            Style: Translation,\(fontName),\(fontSize),\(primaryColor),\(secondaryColor),\(outlineColor),\(backColor),0,0,0,0,100,100,0,0,\(borderStyle),\(outlineWidth),\(shadowDepth),2,10,10,\(0 + marginBottom),1

            [Events]
            Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
            """

        for subtitle in subtitles {
            let startTime = formatASSTimecode(subtitle.startTime)
            let endTime = formatASSTimecode(subtitle.endTime)
            var sourceText = subtitle.sourceText
            if sourceLanguage != .English {
                sourceText = translationService.splitText(
                    subtitle.sourceText, maxCharactersPerLine: maxCharactersPerLine)
            }

            // Add source text line
            assContent +=
                "\nDialogue: 0,\(startTime),\(endTime),Source,,0,0,0,,\(sourceText.replacingOccurrences(of: "\n", with: "\\N"))"

            // Add translation if available
            if !subtitle.translatedText.isEmpty && subtitle.translatedText != subtitle.sourceText {
                var translatedText = subtitle.translatedText
                if translatedLanguage != .English {
                    translatedText = translationService.splitText(
                        subtitle.translatedText, maxCharactersPerLine: maxCharactersPerLine)
                }
                assContent +=
                    "\nDialogue: 0,\(startTime),\(endTime),Translation,,0,0,0,,\(translatedText.replacingOccurrences(of: "\n", with: "\\N"))"
            }
        }

        return assContent
    }

    func showSubtitleEditor() {
        // Sync editingSubtitles from subtitles so the editor always shows the latest data.
        // Prevents stale persisted data from showing an incomplete list.
        editingSubtitles = subtitles
        showingSubtitleEditor = true
    }

    func updateSubtitles() {
        guard !editingSubtitles.isEmpty else { return }
        subtitles = editingSubtitles
        persistState()

        if let url = selectedVideoURL {
            try? saveSubtitles(videoURL: url)
        }
    }

    private func refreshPlayer(at time: Double) {
        // Refresh video player with new subtitles
        // This method should be implemented to refresh the video player
        // with the new subtitles at the specified time.
    }

    func getSRTURL(videoURL: URL) -> URL {
        let path = videoURL.deletingPathExtension()
            .appendingPathExtension("srt")
            .path
            .replacingOccurrences(of: "'", with: "_")
        return URL(fileURLWithPath: path)
    }

    func getVideoOutputURL(videoURL: URL) -> URL {
        let videoFileName =
            videoURL.deletingPathExtension().lastPathComponent
            .replacingOccurrences(of: " ", with: "_")
            .replacingOccurrences(of: "'", with: "_")
            .replacingOccurrences(of: ":", with: "_")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "：", with: "_")
        let cleanVideoFileName =
            "\(videoFileName)_\(selectedQuality.rawValue.lowercased())_\(targetLanguage.rawValue).mp4"

        let outputDirectory = videoURL.deletingLastPathComponent()
        let outputURL = outputDirectory.appendingPathComponent(cleanVideoFileName)

        return outputURL
    }

    private func getVideoHeight(videoURL: URL) -> Double {
        let asset = AVAsset(url: videoURL)
        guard let track = asset.tracks(withMediaType: .video).first else {
            return 720.0  // Default height if video track not found
        }
        return track.naturalSize.height
    }

    private func calculateFontSize(videoURL: URL, baseSize: Double) -> Double {
        let videoHeight = getVideoHeight(videoURL: videoURL)
        return baseSize * (videoHeight / 720.0)  // Scale relative to 720p
    }

    private func getFontSize(videoURL: URL, size: SubtitleFontSize) -> Double {
        return calculateFontSize(videoURL: videoURL, baseSize: size.pointSize)
    }

    func uploadDocument(_ url: URL, currentSubtitles: [Subtitle]) async throws -> [Subtitle] {
        isProcessing = true
        errorMessage = nil
        progress = 0
        statusMessage = "Processing document..."

        do {
            let processedSubtitles = try await wordService.processDocument(
                wordURL: url,
                subtitles: currentSubtitles
            ) { [weak self] message, progress in
                Task { @MainActor in
                    self?.statusMessage = message
                    self?.progress = progress
                }
            }

            isProcessing = false
            return processedSubtitles
        } catch {
            isProcessing = false
            statusMessage = error.localizedDescription
            self.errorMessage = error.localizedDescription
            throw error
        }
    }

    func importSubtitles(srtURL: URL) async throws -> [Subtitle] {
        isProcessing = true
        errorMessage = nil
        progress = 0
        statusMessage = "Importing SRT file..."

        do {
            let importedSubtitles = try await wordService.importSubtitles(
                srtURL: srtURL,
                language: targetLanguage,
                progressCallback: { message, progress in
                    Task { @MainActor in
                        self.statusMessage = message
                        self.progress = progress
                    }
                }
            )
            if importedSubtitles.isEmpty {
                isProcessing = false
                statusMessage = "No subtitles found in SRT file"
                return []
            } else {
                self.subtitles = importedSubtitles
                self.editingSubtitles = subtitles
                persistState()
            }
            isProcessing = false
            statusMessage = "Subtitles imported \(subtitles.count) successfully"
            return importedSubtitles
        } catch {
            isProcessing = false
            statusMessage = error.localizedDescription
            self.errorMessage = error.localizedDescription
            throw error
        }
    }

    /// Select a translation language
    public func selectTargetLanguage(_ language: Language) {
        targetLanguage = language
        persistState()

        logger.log("Selected target language: \(language.rawValue)")
        analytics.trackEvent(.targetLanguageSelected, parameters: ["language": language.rawValue])
    }

    public func selectSourceLanguage(_ language: Language) {
        sourceLanguage = language
        persistState()

        logger.log("Selected source language: \(language.rawValue)")
        analytics.trackEvent(.sourceLanguageSelected, parameters: ["language": language.rawValue])
    }

    public func selectVideo() async {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.movie, .video, .mpeg4Movie, .audio, .mp3, .wav]

        if panel.runModal() == .OK {
            if let url = panel.url {
                doSelectVideo(url)
            }
        }

        analytics.trackEvent(.videoSelected)
    }

    private func doSelectVideo(_ url: URL) {
        cleanupPlayer()

        do {
            // Create asset and player item
            let asset = AVAsset(url: url)
            let playerItem = AVPlayerItem(asset: asset)

            // Create player with default settings
            let newPlayer = AVPlayer()
            newPlayer.automaticallyWaitsToMinimizeStalling = false
            newPlayer.allowsExternalPlayback = false

            // Add the item after configuration
            newPlayer.replaceCurrentItem(with: playerItem)

            self.player = newPlayer
            self.selectedVideoURL = url
            self.tipsMessage = "Video selected: \(url.lastPathComponent)"

            addPeriodicTimeObserver()
        } catch {
            logger.log("Failed to initialize player: \(error.localizedDescription)", level: .error)
            self.errorMessage = "Error loading video: \(error.localizedDescription)"
            cleanupPlayer()
        }
    }

    public func getASSURL(videoURL: URL) -> URL {
        let path = videoURL.deletingPathExtension()
            .appendingPathExtension("ass")
            .path
            .replacingOccurrences(of: "'", with: "_")
        return URL(fileURLWithPath: path)
    }

    public func exportSRT() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "srt")!]
        if selectedVideoURL != nil {
            panel.nameFieldStringValue =
                selectedVideoURL!.deletingPathExtension().lastPathComponent + ".srt"
        } else {
            panel.nameFieldStringValue = "subtitles.srt"
        }

        if panel.runModal() == .OK {
            guard let url = panel.url else { return }
            do {
                let maxCharactersPerLine = Settings.shared.videoService.maxCharactersPerLine
                let (srtContent, sourceSrtContent, translationSrtContent) = generateSRTContent(
                    maxCharactersPerLine: maxCharactersPerLine,
                    sourceLanguage: sourceLanguage,
                    translatedLanguage: targetLanguage)

                // Create URLs for the three different SRT files
                let targetURL = url

                // Create URLs for source and translation files by adding suffixes
                let sourceFileName =
                    url.deletingPathExtension().lastPathComponent + "_\(sourceLanguage.displayName)"
                let translationFileName =
                    url.deletingPathExtension().lastPathComponent
                    + "_\(targetLanguage.displayName)"

                let sourceTargetURL = url.deletingLastPathComponent()
                    .appendingPathComponent(sourceFileName)
                    .appendingPathExtension(url.pathExtension)

                let translationTargetURL = url.deletingLastPathComponent()
                    .appendingPathComponent(translationFileName)
                    .appendingPathExtension(url.pathExtension)

                // Write files, overwriting if they exist
                try srtContent.write(to: targetURL, atomically: true, encoding: .utf8)
                try sourceSrtContent.write(to: sourceTargetURL, atomically: true, encoding: .utf8)
                try translationSrtContent.write(
                    to: translationTargetURL, atomically: true, encoding: .utf8)

                logger.log(
                    "Successfully exported SRT files:\n- Combined: \(targetURL.path)\n- Source: \(sourceTargetURL.path)\n- Translation: \(translationTargetURL.path)"
                )
            } catch {
                Task { @MainActor in
                    self.errorMessage = "Failed to export SRT: \(error.localizedDescription)"
                }
            }
        }
    }

    public func exportVideo() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType.mpeg4Movie]
        panel.nameFieldStringValue = "subtitled_video.mp4"

        if panel.runModal() == .OK {
            guard let url = panel.url else { return }
            do {
                guard let processedVideoURL = processedVideoURL else {
                    throw NSError(
                        domain: "com.autosrt", code: -1,
                        userInfo: [NSLocalizedDescriptionKey: "No processed video available"])
                }

                // Remove existing file if it exists
                if FileManager.default.fileExists(atPath: url.path) {
                    try FileManager.default.removeItem(at: url)
                }

                // Generate unique filename if needed
                var targetURL = url
                var counter = 1
                while FileManager.default.fileExists(atPath: targetURL.path) {
                    let newName = url.deletingPathExtension().lastPathComponent + " (\(counter))"
                    targetURL = url.deletingLastPathComponent()
                        .appendingPathComponent(newName)
                        .appendingPathExtension(url.pathExtension)
                    counter += 1
                }

                try FileManager.default.copyItem(at: processedVideoURL, to: targetURL)
                logger.log("Video exported successfully to: \(targetURL.path)")
            } catch {
                Task { @MainActor in
                    self.errorMessage = "Failed to export video: \(error.localizedDescription)"
                }
            }
        }
    }

    // Export audio
    public func exportAudio() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType.wav]
        if selectedVideoURL != nil {
            panel.nameFieldStringValue =
                selectedVideoURL!.deletingPathExtension().lastPathComponent + ".wav"
        } else {
            panel.nameFieldStringValue = "audio.wav"
        }

        if panel.runModal() == .OK {
            guard let url = panel.url else { return }
            Task {
                do {
                    Task { @MainActor in
                        isProcessing = true
                        statusMessage = "Starting audio export to \(url.path)..."
                    }
                    
                    // Remove existing file if it exists
                    if FileManager.default.fileExists(atPath: url.path) {
                        try FileManager.default.removeItem(at: url)
                    }
                    
                    try await WhisperService.shared.extractAudio(from: selectedVideoURL!, to: url)
                    Task { @MainActor in
                        isProcessing = false
                        statusMessage = ""
                    }
                    
                    logger.log("Audio exported successfully to: \(url.path)")
                } catch {
                    Task { @MainActor in
                        self.errorMessage = "Failed to export audio: \(error.localizedDescription)"
                    }
                }
            }
            
        }
    }

    private func addPeriodicTimeObserver() {
        // Remove any existing observer first
        removePeriodicTimeObserver()

        // Observe time changes every 0.1 seconds
        let interval = CMTime(seconds: 5, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
        timeObserverToken = player?.addPeriodicTimeObserver(forInterval: interval, queue: .main) {
            [weak self] time in
            guard let self = self else { return }

            // Update playerTime with current time
            Task { @MainActor in
                self.playerTime = time.seconds
                self.updateCurrentSubtitleIndex()
            }

            // Log time changes at a reasonable interval (every second) to avoid excessive logging
            if Int(time.seconds) % 60 == 0 {
                // save it
                Task { @MainActor in
                    self.userDefaults.set(self.playerTime, forKey: Self.playerTimeKey)
                    self.logger.log(
                        "Player time: \(self.formatTimecode(time.seconds))", level: .debug)
                }
            }
        }
    }

    // Find which subtitle corresponds to the current playback time
    private func updateCurrentSubtitleIndex() {
        let time = self.playerTime

        // Find the subtitle that contains the current time
        for (index, subtitle) in subtitles.enumerated() {
            if time >= subtitle.startTime && time <= subtitle.endTime {
                if currentSubtitleIndex != subtitle.index {
                    currentSubtitleIndex = subtitle.index
                }
                return
            }
        }

        // If no subtitle contains the current time, find the nearest upcoming subtitle
        if !subtitles.isEmpty {
            let futureSubtitles = subtitles.filter { $0.startTime > time }
            if let nextSubtitle = futureSubtitles.min(by: { $0.startTime < $1.startTime }) {
                if let index = subtitles.firstIndex(where: { $0.index == nextSubtitle.index }) {
                    if currentSubtitleIndex != index {
                        currentSubtitleIndex = nextSubtitle.index
                    }
                    return
                }
            }

            // If we're past all subtitles, set to the last one
            if time > subtitles.last?.endTime ?? 0 {
                currentSubtitleIndex = subtitles.last!.index
            }
        } else {
            currentSubtitleIndex = -1
        }
    }

    // Remove periodic time observer
    private func removePeriodicTimeObserver() {
        if let token = timeObserverToken {
            player?.removeTimeObserver(token)
            timeObserverToken = nil
        }
    }

    // Helper function to format bytes into human-readable format
    private func formatBytes(_ bytes: Int64) -> String {
        let kb = Double(bytes) / 1024.0
        let mb = kb / 1024.0
        let gb = mb / 1024.0

        if gb >= 1.0 {
            return String(format: "%.2f GB", gb)
        } else if mb >= 1.0 {
            return String(format: "%.2f MB", mb)
        } else if kb >= 1.0 {
            return String(format: "%.2f KB", kb)
        } else {
            return "\(bytes) bytes"
        }
    }

    // Helper function to format ETA into human-readable format
    private func formatETA(_ seconds: Double) -> String {
        if seconds < 60 {
            return String(format: "%.0fs", seconds)
        } else if seconds < 3600 {
            let minutes = Int(seconds / 60)
            let remainingSeconds = Int(seconds.truncatingRemainder(dividingBy: 60))
            return String(format: "%dm %ds", minutes, remainingSeconds)
        } else {
            let hours = Int(seconds / 3600)
            let minutes = Int((seconds.truncatingRemainder(dividingBy: 3600)) / 60)
            return String(format: "%dh %dm", hours, minutes)
        }
    }
}
