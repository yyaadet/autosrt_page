import AVKit
import Combine
import Metal
import SwiftUI

struct VideoPlayerContainer: NSViewRepresentable {
    let player: AVPlayer?
    let fontSize: SubtitleViewModel.SubtitleFontSize

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .inline
        view.showsFullScreenToggleButton = true
        return view
    }

    func updateNSView(_ playerView: AVPlayerView, context: Context) {
        if playerView.player !== player {
            playerView.player = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                playerView.player = player
            }
        }
    }
}

struct ContentView: View {
    @StateObject private var viewModel = SubtitleViewModel()
    @StateObject private var translationService = TranslationService.shared
    @State private var showingDonateSheet = false
    @State private var showingSettingsSheet = false
    @State private var subtitleEditorController: NSWindowController?
    @State private var isSummaryViewPresented = false
    private let analytics = AnalyticsService.shared

    private var videoPlayerSection: some View {
        VStack {
            if let player = viewModel.player {
                VideoPlayerContainer(player: player, fontSize: viewModel.selectedFontSize)
                    .frame(maxWidth: .infinity, minHeight: 350)
            } else {
                Color.black
                    .frame(maxWidth: .infinity, minHeight: 350)
            }

            if !viewModel.tipsMessage.isEmpty {
                Text(viewModel.tipsMessage)
                    .foregroundColor(.primary)
                    .font(.caption)
                    .padding(.bottom, 8)
            }
        }
    }

    private var keyButtons: some View {
        VStack {
            Button(action: {
                Task {
                    await viewModel.selectVideo()
                }
            }) {
                HStack {
                    Label("Select", systemImage: "video.badge.plus")
                        .frame(width: 100, alignment: .leading)
                    Spacer()
                }
                .frame(width: 100)
            }
            .disabled(viewModel.isProcessing)

            Button(action: {
                showingSettingsSheet = true
            }) {
                HStack {
                    Label("Settings", systemImage: "gear")
                        .frame(width: 100, alignment: .leading)
                    Spacer()
                }
                .frame(width: 100)
            }

            Button(action: { showingDonateSheet = true }) {
                HStack(spacing: 4) {
                    Label("Support", systemImage: "heart.fill")
                        .frame(width: 100, alignment: .leading)
                    Spacer()
                }
                .frame(width: 100)
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(.vertical, 4)
        .padding(.horizontal)
    }

    private var controlButtons: some View {
        HStack {
            HStack {
                Text("Source Language:")
                    .foregroundColor(.secondary)

                Picker("", selection: $viewModel.sourceLanguage) {
                    ForEach(Language.allCases, id: \.self) { language in
                        Text(language.displayName).tag(language)
                    }
                }
                .onChange(of: viewModel.sourceLanguage) { language in
                    viewModel.selectSourceLanguage(language)
                }
                .frame(minWidth: 100)
            }

            HStack {
                Text("Target Language:")
                    .foregroundColor(.secondary)

                Picker("", selection: $viewModel.targetLanguage) {
                    ForEach(Language.allCases, id: \.self) { language in
                        Text(language.displayName).tag(language)
                    }
                }
                .onChange(of: viewModel.targetLanguage) { language in
                    viewModel.selectTargetLanguage(language)
                }
                .frame(minWidth: 100)
            }

            HStack {
                Text("Quality:")
                    .foregroundColor(.secondary)
                    .frame(width: 60)

                let qualityBinding = Binding(
                    get: { viewModel.selectedQuality },
                    set: { newQuality in
                        viewModel.selectedQuality = newQuality
                        viewModel.persistState()
                        analytics.trackEvent(
                            .qualitySelected, parameters: ["quality": newQuality.rawValue])
                    }
                )

                Picker("", selection: qualityBinding) {
                    ForEach(VideoQuality.allCases, id: \.self) { quality in
                        Text(quality.rawValue).tag(quality)
                    }
                }
                .frame(minWidth: 100)
            }

            HStack {
                Text("Font Size:")
                    .foregroundColor(.secondary).frame(width: 60)

                let fontSizeBinding = Binding(
                    get: { viewModel.selectedFontSize },
                    set: { newSize in
                        viewModel.selectedFontSize = newSize
                        viewModel.persistState()
                        analytics.trackEvent(
                            .fontSizeSelected, parameters: ["size": newSize.rawValue])
                    }
                )

                Picker("", selection: fontSizeBinding) {
                    ForEach(SubtitleViewModel.SubtitleFontSize.allCases, id: \.self) { size in
                        Text(size.rawValue).tag(size)
                    }
                }
                .frame(minWidth: 100)
            }

        }
        .padding(.horizontal)
    }

    private var actionButtons: some View {
        HStack(spacing: 8) {
            Button(action: {
                if let url = viewModel.selectedVideoURL {
                    Task {
                        await viewModel.generateSubtitles(url)
                    }
                }
            }) {
                Label("Generate Subtitles", systemImage: "wand.and.stars")
            }
            .disabled(viewModel.selectedVideoURL == nil || viewModel.isProcessing)

            HStack(spacing: 4) {
                Toggle(isOn: $viewModel.autoTranslateAfterAsr) {
                    EmptyView()
                }
                .toggleStyle(.switch)
                .disabled(viewModel.isProcessing)
                .help("When on: Generate does ASR + Translate in one go. When off: ASR only, Translate separately.")
                Text("Auto Translate")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }

            // Translate button: appears after ASR is done
            Button(action: {
                viewModel.translateCurrentSubtitles()
            }) {
                Label(
                    viewModel.hasNeedsRetranslation
                        ? "Re-translate Edited"
                        : "Translate",
                    systemImage: "globe")
            }
            .disabled(!viewModel.canTranslate)
            .help(
                viewModel.targetLanguage == .None
                    ? "Select a target language first" : "Translate source subtitles"
            )

            if viewModel.isProcessing {
                Button(action: {
                    viewModel.stopGeneration()
                }) {
                    Label("Stop", systemImage: "stop.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
            }

            Button(action: {
                let panel = NSOpenPanel()
                panel.allowsMultipleSelection = false
                panel.canChooseDirectories = false
                panel.canChooseFiles = true
                panel.allowedContentTypes = [.init(filenameExtension: "srt")].compactMap { $0 }

                panel.begin { response in
                    if response == .OK, let url = panel.url {
                        Task {
                            do {
                                let newSubtitles = try await viewModel.importSubtitles(srtURL: url)
                                await MainActor.run {
                                    viewModel.subtitles = newSubtitles
                                }
                            } catch {
                                print(
                                    "Error importing subtitles: \(error.localizedDescription)")
                            }
                        }
                    }
                }
            }) {
                Label("Import SRT", systemImage: "doc.badge.plus")
            }
            .disabled(viewModel.selectedVideoURL == nil || viewModel.isProcessing)

            Button(action: {
                Task {
                    if let videoURL = viewModel.selectedVideoURL {
                        await viewModel.renderVideoWithSubtitles(
                            videoURL: videoURL, srtURL: viewModel.getASSURL(videoURL: videoURL))
                    }
                }
            }) {
                Label("Render Video", systemImage: "film")
            }
            .disabled(viewModel.isProcessing || viewModel.subtitles.isEmpty)

            Button(action: {
                viewModel.showSubtitleEditor()
            }) {
                Label("Edit Subtitles", systemImage: "text.quote")
            }
            .disabled(
                viewModel.player == nil || viewModel.isProcessing || viewModel.subtitles.isEmpty)

            Button(action: { viewModel.exportVideo() }) {
                Label("Export Video", systemImage: "square.and.arrow.up")
            }
            .disabled(viewModel.isProcessing || !viewModel.videoRendered)

            //Export audio
            Button(action: {
                viewModel.exportAudio()
            }) {
                Label("Export Audio", systemImage: "square.and.arrow.up")
            }
            .disabled(viewModel.isProcessing)

            if !viewModel.subtitles.isEmpty {
                Button(action: { viewModel.exportSRT() }) {
                    Label("Export SRT", systemImage: "square.and.arrow.up")
                }
                .disabled(viewModel.isProcessing)
            }

            Button {
                isSummaryViewPresented = true
            } label: {
                Label("Summary", systemImage: "list.bullet")
            }
            .help("Summary")
            .disabled(viewModel.subtitles.isEmpty || viewModel.isProcessing)
        }
        .padding(.horizontal)
    }

    private var progressSection: some View {
        VStack {
            if viewModel.isProcessing {
                ProgressView(viewModel.statusMessage, value: viewModel.progress, total: 1.0)
                    .progressViewStyle(LinearProgressViewStyle())
                    .padding()

            }

            if let errorMsg = viewModel.errorMessage {
                Text(errorMsg)
                    .foregroundColor(.red)
                    .padding()
            }
        }
    }

    private var subtitleList: some View {
        HStack(spacing: 16) {
            ScrollViewReader { scrollProxy in
                List(viewModel.subtitles) { subtitle in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(
                            "#\(subtitle.index + 1) \(viewModel.formatTimecode(subtitle.startTime)) --> \(viewModel.formatTimecode(subtitle.endTime))"
                        )
                        .font(.caption)
                        .foregroundColor(.secondary)

                        if !subtitle.sourceText.isEmpty {
                            Text(subtitle.sourceText)
                                .font(.body)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        if !subtitle.translatedText.isEmpty {
                            Text(subtitle.translatedText)
                                .font(.body)
                                .foregroundColor(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(.vertical, 2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .id(subtitle.index)  // Use subtitle index as the ID for scrolling
                    .background(
                        viewModel.currentSubtitleIndex == subtitle.index
                            ? Color.accentColor.opacity(0.2) : Color.clear
                    )
                }
                .onChange(of: viewModel.currentSubtitleIndex) { newIndex in
                    if newIndex >= 0 && newIndex < viewModel.subtitles.count {
                        withAnimation {
                            scrollProxy.scrollTo(
                                viewModel.subtitles[newIndex].index, anchor: .center)
                        }
                    }
                }
            }

            VStack(alignment: .leading) {
                Text(
                    "Translated Ratio: \(String(format: "%.2f", viewModel.subtitleStatistics.translatedRatio * 100))%"
                )
                .font(.headline)
                .foregroundColor(.secondary)

                Divider()

                Text("Total Subtitles: \(viewModel.subtitleStatistics.totalSubtitles)")
                    .font(.body)
                    .foregroundColor(.secondary)
                Text("Translated Subtitles: \(viewModel.subtitleStatistics.translatedCount)")
                    .font(.body)
                    .foregroundColor(.secondary)
                Text("Source Character Count: \(viewModel.subtitleStatistics.sourceCharacterCount)")
                    .font(.body)
                    .foregroundColor(.secondary)
                Text("Target Character Count: \(viewModel.subtitleStatistics.targetCharacterCount)")
                    .font(.body)
                    .foregroundColor(.secondary)
                Divider()
                // show selected model
                Text("Model: \(viewModel.selectedModel)")
                    .font(.body)
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: 240, maxHeight: .infinity, alignment: .topLeading)
        }
        .padding(.horizontal, 8)
    }

    var body: some View {
        VStack(spacing: 2) {
            videoPlayerSection

            HStack(spacing: 8) {
                keyButtons

                VStack(alignment: .leading, spacing: 16) {
                    controlButtons
                    actionButtons
                    progressSection
                }
            }
            .padding(.bottom)

            subtitleList

        }
        .frame(minWidth: 800, minHeight: 600)
        .onAppear {
            viewModel.onAppear()
        }
        .onDisappear {
            viewModel.onDisappear()
            destroySubtitleEditor()
        }
        .onChange(of: viewModel.editingSubtitles) { _ in
            if viewModel.editingSubtitles.count != viewModel.subtitles.count {
                destroySubtitleEditor()
            }
        }
        .sheet(isPresented: $showingDonateSheet) {
            DonateView()
                .frame(minWidth: 800, minHeight: 600)
        }
        .sheet(isPresented: $showingSettingsSheet) {
            SettingsView()
                .frame(minWidth: 800, minHeight: 600)
        }
        .sheet(isPresented: $isSummaryViewPresented) {
            SummaryView(viewModel: SummaryViewModel(subtitles: viewModel.subtitles))
                .frame(minWidth: 800, minHeight: 600)
        }
        .onChange(of: viewModel.showingSubtitleEditor) { isShowing in
            if isShowing {
                if let existingWindow = subtitleEditorController?.window {
                    existingWindow.makeKeyAndOrderFront(nil)
                } else {
                    let controller = NSWindowController(
                        window: NSWindow(
                            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
                            styleMask: [.titled, .closable, .miniaturizable, .resizable],
                            backing: .buffered,
                            defer: false
                        )
                    )
                    controller.window?.title = "Edit Subtitles"
                    controller.window?.contentView = NSHostingView(
                        rootView: SubtitleEditView(
                            viewModel: viewModel, onDismiss: destroySubtitleEditor
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    )

                    // Store the controller reference
                    subtitleEditorController = controller

                    controller.showWindow(nil)

                    // Center the window
                    if let window = controller.window {
                        window.center()
                        window.makeKeyAndOrderFront(nil)
                    }
                }

                // Reset the flag after window is shown
                viewModel.showingSubtitleEditor = false
            }
        }
    }

    private func destroySubtitleEditor() {
        subtitleEditorController?.close()
        subtitleEditorController = nil
    }

}
