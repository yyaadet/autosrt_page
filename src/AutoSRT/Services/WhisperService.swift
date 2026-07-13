import AVFoundation
import Foundation
import ffmpegkit

// Global variable to store the current progress callback
private var currentProgressCallback: ((String, Double) -> Void)? = nil

// C-compatible callback function that doesn't capture context
private func whisperProgressCallback(
    ctx: OpaquePointer?, state: OpaquePointer?, progress: Int32, user_data: UnsafeMutableRawPointer?
) {
    currentProgressCallback?(
        "Transcribing \(progress)%...", (Double(progress) / 100.0).clamped(to: 0.0...1.0))
}

extension NSObject {
    func apply(_ closure: (Self) -> Void) -> Self {
        closure(self)
        return self
    }
}

enum WhisperServiceError: Error {
    case modelNotFound(String)
    case contextCreationFailed(String)
    case transcriptionFailed(String)
    case audioExtractionFailed(String)
    case invalidSRTFormat(String)
    case invalidLanguage(String)
}

class WhisperService {
    static let shared = WhisperService()
    private let logger = LoggerService.shared
    private var modelPath: String = ""
    private var whisperPath: String = ""

    private init() {
        whisperPath = Bundle.main.path(forResource: "whisper", ofType: "") ?? ""
    }

    /// Get the current model path (empty if not yet initialized/downloaded)
    public var currentModelPath: String {
        modelPath
    }

    /// Initialize the model, downloading it if it doesn't exist
    public func initializeModel(
        progressHandler: ((@Sendable (DownloadService.DownloadProgress) -> Void))? = nil
    ) async throws {
        let selectedModel = Settings.shared.whisperService.selectedModel
        let modelName = selectedModel.rawValue
        let fileName = selectedModel.fileName

        // Check bundle for model
        let bundledModelPath = Bundle.main.path(forResource: modelName, ofType: "bin") ?? ""
        if !bundledModelPath.isEmpty {
            modelPath = bundledModelPath
            logger.log("Whisper model (\(selectedModel.displayName)) found in bundle.", level: .info)
            return
        }

        // Model doesn't exist, download it
        logger.log("Whisper model (\(selectedModel.displayName)) not found, downloading...", level: .info)

        // Get application support directory
        let appSupportDir = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )

        // Create models directory
        let modelsDir = appSupportDir.appendingPathComponent("AutoSRT/Models", isDirectory: true)
        try FileManager.default.createDirectory(
            at: modelsDir, withIntermediateDirectories: true, attributes: nil)

        // Check if model already exists in application support directory
        // Also check for a temp file from a previous failed download
        let modelPathAtAppSupportDir = modelsDir.appendingPathComponent(fileName, isDirectory: false)
        let tempModelPath = modelPathAtAppSupportDir.path + ".tmp"
        if FileManager.default.fileExists(atPath: modelPathAtAppSupportDir.path) {
            modelPath = modelPathAtAppSupportDir.path
            logger.log("Successfully loaded whisper model (\(selectedModel.displayName)) from application support directory")
            return
        } else if FileManager.default.fileExists(atPath: tempModelPath) {
            // A temp file from a previous failed download exists, we'll resume it
            logger.log("Found leftover temp file for model, will resume download")
        }

        // Download with reconnection support
        guard let modelURL = URL(string: selectedModel.downloadUrl) else {
            throw WhisperServiceError.modelNotFound(selectedModel.downloadUrl)
        }

        let maxRetries = 10
        let baseDelay: TimeInterval = 2

        for attempt in 0..<maxRetries {
            do {
                let downloadedURL = try await DownloadService.shared.downloadModel(
                    from: modelURL,
                    modelName: "ggml-\(modelName)",
                    destinationDirectory: modelsDir
                ) { @Sendable progress in
                    progressHandler?(progress)
                }
                modelPath = downloadedURL.path
                logger.log("Successfully downloaded model (\(selectedModel.displayName)) at \(modelPath)")
                return
            } catch {
                let isLastAttempt = attempt == maxRetries - 1
                if isLastAttempt {
                    logger.log("Download failed after \(maxRetries) attempts: \(error.localizedDescription)", level: .error)
                    throw error
                }

                let delay = baseDelay * pow(2, Double(attempt))
                logger.log("Download failed (attempt \(attempt + 1)/\(maxRetries)), retrying in \(Int(delay))s...")
                progressHandler?(DownloadService.DownloadProgress(
                    modelName: modelName,
                    bytesDownloaded: 0,
                    totalBytes: 0,
                    progress: 0,
                    status: .downloading,
                    downloadSpeed: 0,
                    estimatedTimeRemaining: nil
                ))

                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }
    }

    private func transcribeAudio(
        audioFile: URL, language: Language,
        progressCallback: @escaping (String, Double) -> Void
    ) async throws -> [Subtitle] {
        if modelPath.isEmpty {
            throw NSError(
                domain: "WhisperService", code: 1001,
                userInfo: [NSLocalizedDescriptionKey: "Whisper model not found"])
        }
        // Create unique output file for this transcription
        let outputSrtPath = audioFile.deletingPathExtension()
            .appendingPathExtension(language.rawValue)
            .appendingPathExtension("srt")

        // Remove existing output file if it exists
        if FileManager.default.fileExists(atPath: outputSrtPath.path) {
            try FileManager.default.removeItem(at: outputSrtPath)
        }

        var prompt =
            "transcribe to \(language.displayName), segment naturally, suitable for reading"
        var languageCode = language.whisperCode

        if language == .SimplifiedChinese || language == .TraditionalChinese {
            languageCode = "zh"  // Use standard 'zh' code
            prompt = "使用简体中文转录，如果出现繁体字请转换为简体字, 断句自然，符合阅读习惯"  // "Transcribe using Simplified Chinese, convert Traditional characters to Simplified"
        }

        // get process number of system
        #if os(macOS)
            let maxThread = max(ProcessInfo.processInfo.activeProcessorCount / 3, 5)
        #else
            let maxThread = 5
        #endif
        // Use ProcessInfo to get system memory information
        let physicalMemory = ProcessInfo.processInfo.physicalMemory

        var maxProcess = 3
        if physicalMemory < 1024 * 1024 * 1024 * 16 {
            maxProcess = 1
        }

        var arguments = [
            "-t", "\(maxThread)",
            "-p", "\(maxProcess)",
            "-m", modelPath,
            "-f", audioFile.path,
            "-l", languageCode,
            "-np",
            "-osrt",
            "-mc", "\(Settings.shared.whisperService.contextLength)",
            "-tp", "\(Settings.shared.whisperService.temperature)",
            "-bs", "8",
            "-bo", "8",
            "-ac", "1500",
            "-fa",
            "-sow",
            "--prompt", "'\(prompt)'",
            "-of", outputSrtPath.deletingPathExtension().path,
        ]

        // Add any additional language-specific arguments here if needed
        switch language {
        case .Japanese, .Korean, .SimplifiedChinese, .TraditionalChinese:
            arguments.append(contentsOf: [
                "--max-len", "\(Settings.shared.whisperService.maxCJKSegmentLength)",
            ])  // Shorter segments for CJK languages
        default:
            arguments.append(contentsOf: [
                "--max-len", "\(Settings.shared.whisperService.maxDefaultSegmentLength)",
            ])
        }
        logger.log("Whisper transcription arguments: \(arguments.joined(separator: " "))")

        // Execute whisper command
        let process = Process()
        process.executableURL = URL(fileURLWithPath: whisperPath)
        process.arguments = arguments

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        logger.log("Starting whisper transcription with language: \(language)")
        try process.run()

        // Get audio duration for progress calculation
        let asset = AVAsset(url: audioFile)
        let totalDuration = CMTimeGetSeconds(asset.duration)

        // Read output in real-time
        let handle = pipe.fileHandleForReading
        //collect output
        for try await line in handle.bytes.lines {
            // logger.log(line)
            // parse line and update progress, line format: [00:20:36.240 --> 00:20:43.240]   Questions?
            let timecodeLine = line.trimmingCharacters(in: .whitespaces)
            // extract string in []
            guard
                let timecodeRange = timecodeLine.range(of: "\\[.*?\\]", options: .regularExpression)
            else { continue }
            let timecodeString = String(timecodeLine[timecodeRange].dropFirst().dropLast())

            let timecodes = timecodeString.components(separatedBy: " --> ")
            guard timecodes.count == 2,
                let startTime = parseTimecode(
                    timecodes[0].replacingOccurrences(of: ".", with: ":")),
                let endTime = parseTimecode(timecodes[1].replacingOccurrences(of: ".", with: ":"))
            else {
                continue
            }
            let progress = Double(endTime) / totalDuration
            let percent = String.init(format: "%.2f", progress * 100)
            progressCallback(
                "Transcribing \(percent)%:: \(timecodes[0]) - \(timecodes[1])...", progress * 0.8)
        }

        // Wait for process to complete
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw WhisperServiceError.transcriptionFailed(
                "Whisper process failed with status \(process.terminationStatus)")
        }

        // Parse the generated SRT file
        let subtitles = try await parseSRT(from: outputSrtPath) { message, progress in
            progressCallback(message, 0.8 + 0.2 * progress)
        }

        try FileManager.default.removeItem(at: outputSrtPath)

        return subtitles
    }

    // Helper: load audio samples from file as Float32 mono 16kHz
    private func loadAudioSamples(from audioFile: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: audioFile)

        guard
            let outputFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: 16_000.0,
                channels: 1,
                interleaved: false)
        else {
            throw WhisperServiceError.audioExtractionFailed("Failed to create output format")
        }

        guard let converter = AVAudioConverter(from: file.processingFormat, to: outputFormat) else {
            throw WhisperServiceError.audioExtractionFailed("Failed to create audio converter")
        }

        let capacity = AVAudioFrameCount(file.length)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
            throw WhisperServiceError.audioExtractionFailed("Failed to create PCM buffer")
        }

        var error: NSError?
        let inputBlock: AVAudioConverterInputBlock = { inNumPackets, outStatus in
            do {
                guard
                    let temp = AVAudioPCMBuffer(
                        pcmFormat: file.processingFormat, frameCapacity: inNumPackets)
                else {
                    outStatus.pointee = .noDataNow
                    return nil
                }
                try file.read(into: temp)
                outStatus.pointee = .haveData
                return temp
            } catch {
                outStatus.pointee = .noDataNow
                return nil
            }
        }

        converter.convert(to: buffer, error: &error, withInputFrom: inputBlock)
        if let err = error {
            throw WhisperServiceError.audioExtractionFailed(
                "Audio conversion error: \(err.localizedDescription)")
        }

        let count = Int(buffer.frameLength)
        guard let channelData = buffer.floatChannelData, buffer.frameLength > 0 else {
            throw WhisperServiceError.audioExtractionFailed("Failed to get float channel data")
        }

        // Get the first channel (mono)
        let data = channelData[0]

        logger.log("Extracted audio samples: \(count) samples")
        return Array(UnsafeBufferPointer(start: data, count: count))
    }

    private func parseSRT(from url: URL, progressCallback: @escaping (String, Double) -> Void)
        async throws -> [Subtitle]
    {
        guard let srtContent = try? String(contentsOf: url, encoding: .utf8) else {
            throw WhisperServiceError.transcriptionFailed("Failed to read SRT output file")
        }

        // Parse the SRT content into subtitles
        var subtitles: [Subtitle] = []
        let lines = srtContent.components(separatedBy: .newlines)
        var index = 0

        while index < lines.count {
            // Skip empty lines
            while index < lines.count && lines[index].trimmingCharacters(in: .whitespaces).isEmpty {
                index += 1
            }
            if index >= lines.count { break }

            // Skip subtitle number
            index += 1
            if index >= lines.count { break }

            // Parse time codes
            let timecodeLine = lines[index].trimmingCharacters(in: .whitespaces)
            let timecodes = timecodeLine.components(separatedBy: " --> ")
            guard timecodes.count == 2,
                let startTime = parseTimecode(timecodes[0]),
                let endTime = parseTimecode(timecodes[1])
            else {
                throw WhisperServiceError.invalidSRTFormat(
                    "Invalid timecode format: \(timecodeLine)")
            }
            index += 1

            // Parse subtitle text
            var text = ""
            while index < lines.count && !lines[index].trimmingCharacters(in: .whitespaces).isEmpty
            {
                if !text.isEmpty {
                    text += "\n"
                }
                text += lines[index].replacingOccurrences(of: "BLANK_AUDIO", with: "AutoSRT")
                index += 1
            }

            // Create subtitle with appropriate language
            let subtitle = Subtitle(
                startTime: startTime,
                endTime: endTime,
                sourceText: text,
                translatedText: ""
            )
            subtitles.append(subtitle)

            progressCallback(
                "Parsed subtitle \(index + 1)/\(lines.count)",
                Double(index + 1) / Double(lines.count))
        }

        return subtitles
    }

    private func parseTimecode(_ timecode: String) -> TimeInterval? {
        let components = timecode.trimmingCharacters(in: .whitespaces)
            .components(separatedBy: CharacterSet(charactersIn: ":,"))

        guard components.count == 4,
            let hours = Double(components[0]),
            let minutes = Double(components[1]),
            let seconds = Double(components[2]),
            let milliseconds = Double(components[3])
        else {
            return nil
        }

        return hours * 3600 + minutes * 60 + seconds + milliseconds / 1000
    }

    /// ASR-only: transcribe audio to source-language subtitles. No translation is performed.
    public func transcribeOnly(
        audioFile: URL,
        sourceLanguage: Language,
        progressCallback: @escaping (String, Double) -> Void
    ) async throws -> [Subtitle] {
        logger.log("Starting transcription (ASR only)...")

        guard sourceLanguage != .None else {
            throw WhisperServiceError.invalidLanguage(
                "Source language must be specified. Automatic language detection is not available.")
        }

        progressCallback(
            "Generating subtitles in source language (\(sourceLanguage.displayName))...", 0.3)
        let sourceSubtitles = try await transcribeAudio(
            audioFile: audioFile, language: sourceLanguage
        ) { message, sub_progress in
            progressCallback(message, 0.1 + 0.8 * sub_progress)
        }

        let result = sourceSubtitles.enumerated().map { (i, sub) in
            Subtitle(
                startTime: sub.startTime,
                endTime: sub.endTime,
                sourceText: sub.sourceText.trimmingCharacters(in: .whitespacesAndNewlines),
                translatedText: "",
                index: i
            )
        }

        progressCallback("Transcription complete: \(result.count) subtitles.", 1.0)
        return result
    }

    /// Full pipeline: ASR + optional translation.
    /// When `targetLanguage == .None` translation is skipped (source-only).
    public func transcribe(
        audioFile: URL,
        sourceLanguage: Language,
        targetLanguage: Language,
        progressCallback: @escaping (String, Double) -> Void
    ) async throws -> [Subtitle] {
        logger.log("Starting transcription process...")

        guard sourceLanguage != .None else {
            throw WhisperServiceError.invalidLanguage(
                "Source language must be specified. Automatic language detection is not available.")
        }
        let realSourceLanguage = sourceLanguage

        // Step 1: ASR
        progressCallback(
            "Generating subtitles in source language (\(realSourceLanguage.displayName))...", 0.3)
        let sourceSubtitles = try await transcribeAudio(
            audioFile: audioFile, language: realSourceLanguage
        ) { message, sub_progress in
            progressCallback(message, 0.1 + 0.5 * sub_progress)
        }

        // Step 2: translate only when a target language is selected
        guard targetLanguage != .None else {
            let result = sourceSubtitles.enumerated().map { (i, sub) in
                Subtitle(
                    startTime: sub.startTime,
                    endTime: sub.endTime,
                    sourceText: sub.sourceText.trimmingCharacters(in: .whitespacesAndNewlines),
                    translatedText: "",
                    index: i
                )
            }
            progressCallback("Transcription complete (source only): \(result.count) subtitles.", 1.0)
            return result
        }

        progressCallback(
            "Preparing to translate \(realSourceLanguage.displayName) to \(targetLanguage.displayName)...",
            0.6)

        let translatedSubtitles = try await TranslationService.shared.translateSubtitles(
            sourceSubtitles,
            fromLanguage: realSourceLanguage.target,
            toLanguage: targetLanguage.target,
            model: Settings.shared.llmService.chatModel,
            progressCallback: { subProgress, message in
                progressCallback(message, 0.6 + 0.4 * subProgress)
            })

        progressCallback("Transcription \(translatedSubtitles.count) complete!", 1.0)

        // Check if arrays have matching lengths
        guard sourceSubtitles.count == translatedSubtitles.count else {
            logger.log(
                "Warning: Mismatch in subtitle counts - source: \(sourceSubtitles.count), translated: \(translatedSubtitles.count)",
                level: .warning)
            throw NSError(
                domain: "WhisperService",
                code: -1,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Mismatch in subtitle counts - source: \(sourceSubtitles.count), translated: \(translatedSubtitles.count)"
                ]
            )
        }

        return zip(sourceSubtitles, translatedSubtitles).enumerated().map {
            (index, tuple) -> Subtitle in
            let (en, src) = tuple
            return Subtitle(
                startTime: src.startTime,
                endTime: src.endTime,
                sourceText: en.sourceText.trimmingCharacters(in: .whitespacesAndNewlines),
                translatedText: src.translatedText.trimmingCharacters(in: .whitespacesAndNewlines),
                index: index
            )
        }
    }

    public func extractAudio(from videoURL: URL, to audioURL: URL) async throws {
        do {
            try await extractAudioFfmpeg(from: videoURL, to: audioURL)
        } catch {
            logger.log(
                "Extracting audio with FFmpeg failed, using native method instead", level: .warning)
            try await extractAudioNative(from: videoURL, to: audioURL)
        }
    }

    private func extractAudioNative(from videoURL: URL, to audioURL: URL) async throws {
        logger.log("Extracting audio natively from video: \(videoURL.lastPathComponent)")

        if FileManager.default.fileExists(atPath: audioURL.path) {
            try FileManager.default.removeItem(at: audioURL)
        }

        let asset = AVAsset(url: videoURL)

        // Create asset reader
        guard let assetReader = try? AVAssetReader(asset: asset) else {
            throw WhisperServiceError.audioExtractionFailed("Failed to create asset reader")
        }

        // Setup audio output settings
        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16000.0,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]

        // Create asset writer
        guard let assetWriter = try? AVAssetWriter(outputURL: audioURL, fileType: .wav) else {
            throw WhisperServiceError.audioExtractionFailed("Failed to create asset writer")
        }

        // Setup audio input
        guard let audioTrack = try? await asset.loadTracks(withMediaType: .audio).first else {
            throw WhisperServiceError.audioExtractionFailed("No audio track found")
        }

        let readerOutput = AVAssetReaderTrackOutput(
            track: audioTrack,
            outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 16000.0,
            ]
        )

        let writerInput = AVAssetWriterInput(
            mediaType: .audio,
            outputSettings: outputSettings
        )
        writerInput.expectsMediaDataInRealTime = false

        // Add outputs and inputs
        assetReader.add(readerOutput)
        assetWriter.add(writerInput)

        // Start reading/writing
        guard assetReader.startReading(), assetWriter.startWriting() else {
            throw WhisperServiceError.audioExtractionFailed("Failed to start reading/writing")
        }

        assetWriter.startSession(atSourceTime: .zero)

        return try await withCheckedThrowingContinuation { continuation in
            writerInput.requestMediaDataWhenReady(on: .global()) {
                while writerInput.isReadyForMoreMediaData {
                    if let buffer = readerOutput.copyNextSampleBuffer() {
                        if !writerInput.append(buffer) {
                            assetReader.cancelReading()
                            continuation.resume(
                                throwing: WhisperServiceError.audioExtractionFailed(
                                    "Failed to write audio buffer"))
                            return
                        }
                    } else {
                        writerInput.markAsFinished()
                        assetWriter.finishWriting {
                            if let error = assetWriter.error {
                                continuation.resume(
                                    throwing: WhisperServiceError.audioExtractionFailed(
                                        error.localizedDescription))
                                return
                            }

                            // Verify the output file
                            guard FileManager.default.fileExists(atPath: audioURL.path),
                                let attributes = try? FileManager.default.attributesOfItem(
                                    atPath: audioURL.path),
                                let fileSize = (attributes[.size] as? NSNumber)?.int64Value,
                                fileSize > 0
                            else {
                                continuation.resume(
                                    throwing: WhisperServiceError.audioExtractionFailed(
                                        "Exported audio file is empty or missing"))
                                return
                            }

                            self.logger.log(
                                "Audio extraction completed successfully: \(audioURL.lastPathComponent)"
                            )
                            self.logger.log(
                                "Output file size: \(Double(fileSize) / 1024.0 / 1024.0) MB")
                            continuation.resume()
                        }
                        break
                    }
                }
            }
        }
    }

    private func extractAudioFfmpeg(from videoURL: URL, to audioURL: URL) async throws {
        logger.log("Extracting audio from video: \(videoURL.lastPathComponent)")

        if FileManager.default.fileExists(atPath: audioURL.path) {
            try FileManager.default.removeItem(at: audioURL)
        }

        // let escapedVideoPath = videoURL.path.replacingOccurrences(of: "'", with: "\\'")
        let escapedVideoPath = videoURL.path

        // FFmpeg arguments for audio extraction
        let arguments = [
            "-i", "\"\(escapedVideoPath)\"",
            "-ar", "16000",
            "-ac", "1",
            "-af", "volume=5dB",
            "-c:a", "pcm_s16le",
            "'\(audioURL.path)'",
        ]

        logger.log("Executing FFmpeg with arguments: \(arguments)")

        return try await withCheckedThrowingContinuation { continuation in
            FFmpegKit.executeAsync(arguments.joined(separator: " ")) { session in
                guard let returnCode = session?.getReturnCode() else {
                    let error = session?.getFailStackTrace() ?? "Unknown error"
                    let output = session?.getOutput() ?? ""
                    self.logger.log(
                        "FFmpeg failed with error: \(error)\nOutput: \(output)", level: .error)
                    continuation.resume(
                        throwing: WhisperServiceError.audioExtractionFailed(output)
                    )
                    return
                }

                if ReturnCode.isSuccess(returnCode) {
                    guard FileManager.default.fileExists(atPath: audioURL.path),
                        let attributes = try? FileManager.default.attributesOfItem(
                            atPath: audioURL.path),
                        let fileSize = (attributes[.size] as? NSNumber)?.int64Value,
                        fileSize > 0
                    else {
                        continuation.resume(
                            throwing: WhisperServiceError.audioExtractionFailed(
                                "Exported audio file is empty or missing"))
                        return
                    }

                    self.logger.log(
                        "Audio extraction completed successfully: \(audioURL.lastPathComponent)")
                    self.logger.log("Output file size: \(Double(fileSize) / 1024.0 / 1024.0) MB")
                    continuation.resume()
                } else {
                    let error = session?.getFailStackTrace() ?? "Unknown error"
                    let outputLines = (session?.getOutput() ?? "").split(separator: "\n").suffix(3)
                        .joined(separator: "\n")

                    self.logger.log(
                        "FFmpeg failed with error: \(error) \nOutput: \(outputLines)", level: .error
                    )
                    continuation.resume(
                        throwing: WhisperServiceError.audioExtractionFailed(
                            "\(outputLines)")
                    )
                }
            }
        }
    }
}

extension Array where Element == Subtitle {
    static func mergeBilingual(english: [Subtitle], chinese: [Subtitle]) -> [Subtitle] {
        // Implement merging logic here
        // For now, just return the English subtitles
        return english
    }
}
