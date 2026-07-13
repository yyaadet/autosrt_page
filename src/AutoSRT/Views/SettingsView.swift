import AppKit
import CoreText
import SwiftUI

enum SettingsSection: String, CaseIterable {
    case whisperService = "Audio Recognition"
    case llmService = "LLM"
    case wordService = "Subtitle Alignment"
    case videoService = "Video Render"

    var icon: String {
        switch self {
        case .whisperService: return "waveform"
        case .llmService: return "brain"
        case .wordService: return "doc.plaintext"
        case .videoService: return "film"
        }
    }

    static func fromString(_ string: String) -> SettingsSection {
        return SettingsSection.allCases.first { $0.rawValue == string } ?? .whisperService
    }
}

struct SettingsView: View {
    @ObservedObject var settings = Settings.shared
    @Environment(\.dismiss) private var dismiss
    @State private var showingError = false
    @State private var error: Error?
    @State private var selectedSection: SettingsSection = .whisperService

    init() {
        _selectedSection = State(
            initialValue: SettingsSection.fromString(
                UserDefaults.standard.string(forKey: "selectedSettingsSection")
                ?? SettingsSection.whisperService.rawValue))
    }

    var body: some View {
        HStack(spacing: 0) {
            List {
                ForEach(SettingsSection.allCases, id: \.self) { section in
                    Button(action: {
                        selectedSection = section
                        UserDefaults.standard.set(section.rawValue, forKey: "selectedSettingsSection")
                    }) {
                        VStack(spacing: 4) {
                            Image(systemName: section.icon)
                                .font(.system(size: 18))

                            Text(section.rawValue)
                                .font(.caption)
                                .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(
                            selectedSection == section
                                ? Color(NSColor.selectedControlColor)
                                : Color.clear
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(PlainButtonStyle())
                }
            }
            .frame(width: 100)
            .listStyle(.plain)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    switch selectedSection {
                    case .whisperService:
                        WhisperServiceSettingsView(settings: settings)
                    case .wordService:
                        WordServiceSettingsView(settings: settings)
                    case .videoService:
                        VideoServiceSettingsView(settings: settings)
                    case .llmService:
                        LLMServiceSettingsView(settings: settings)
                    }
                }
                .padding()
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        do {
                            try settings.save()
                            AnalyticsService.shared.trackEvent(.settingsSaved)

                            dismiss()
                        } catch {
                            self.error = error
                            showingError = true
                        }
                    }
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) {
                        dismiss()
                    }
                }
            }
            .alert("Error", isPresented: $showingError, presenting: error) { _ in
                Button("OK", role: .cancel) {}
            } message: { error in
                Text(error.localizedDescription)
            }
        }
        .onAppear {
            // send analytics event
            AnalyticsService.shared.trackEvent(.settingsViewOpened)
        }
    }
}

struct WordServiceSettingsView: View {
    @ObservedObject var settings: Settings

    var body: some View {
        Form {
            Section("Alignment Settings") {
                Slider(value: $settings.wordService.minSimilarity, in: 0...1, step: 0.05) {
                    Text(
                        "Minimum Similarity: \(settings.wordService.minSimilarity, specifier: "%.2f")"
                    )
                }

                HStack {
                    Text("Context Length:")
                    TextField(
                        "", value: $settings.wordService.contextLength, formatter: NumberFormatter()
                    )
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                    .frame(width: 100)
                    .onChange(of: settings.wordService.contextLength) { newValue in
                        settings.wordService.contextLength = newValue
                    }
                }

                Picker("Alignment Mode", selection: $settings.wordService.alignment) {
                    ForEach(Settings.WordService.Alignment.allCases, id: \.self) { mode in
                        Text(mode.rawValue.capitalized).tag(mode)
                    }
                }
            }
        }
    }
}

struct VideoServiceSettingsView: View {
    @ObservedObject var settings: Settings
    @State private var showingFontPicker = false
    @State private var selectedPrimaryColor = Color.white
    @State private var selectedSecondaryColor = Color.red
    @State private var selectedOutlineColor = Color.black
    @State private var selectedBackColor = Color.black
    @State private var isPrimaryColorEnabled = true
    @State private var isSecondaryColorEnabled = true
    @State private var isOutlineColorEnabled = true
    @State private var isBackColorEnabled = true
    @State private var systemFonts: [FontInfo] = []
    @State private var isLoadingFonts = false

    private struct FontInfo: Identifiable, Hashable {
        let id: String
        let englishName: String
        let localizedName: String?

        static func == (lhs: FontInfo, rhs: FontInfo) -> Bool {
            return lhs.id == rhs.id
        }

        func hash(into hasher: inout Hasher) {
            hasher.combine(id)
        }
    }

    private func loadSystemFonts() {
        guard systemFonts.isEmpty else { return }
        isLoadingFonts = true

        Task {
            let fonts = await Task.detached(priority: .userInitiated) { () -> [FontInfo] in
                NSFontManager.shared.availableFontFamilies.compactMap { familyName in
                    guard let fontPath = getFontPath(for: familyName),
                        FileManager.default.fileExists(atPath: fontPath)
                    else { return nil }

                    let localizedName = NSFontManager.shared.localizedName(
                        forFamily: familyName, face: nil)
                    return FontInfo(
                        id: familyName,
                        englishName: familyName,
                        localizedName: localizedName != familyName ? localizedName : nil
                    )
                }.sorted { $0.englishName < $1.englishName }
            }.value

            await MainActor.run {
                self.systemFonts = fonts
                self.isLoadingFonts = false
            }
        }
    }

    private func getFontPath(for familyName: String) -> String? {
        guard let font = NSFont(name: familyName, size: 12) else { return nil }
        guard let fontURL = CTFontCopyAttribute(font, kCTFontURLAttribute) as? NSURL,
            let fontPath = fontURL.path
        else { return nil }
        if familyName == "PingFang SC" {
            LoggerService.shared.log("Find font PingFang SC")
        }
        return fontPath
    }

    private func colorToHex(_ color: Color) -> String {
        let components = NSColor(color).cgColor.components ?? [1, 1, 1, 1]
        let r = Int(components[0] * 255)
        let g = Int(components[1] * 255)
        let b = Int(components[2] * 255)
        return String(format: "&H%02X%02X%02X", b, g, r)  // ASS format uses BGR
    }

    private func hexToColor(_ hex: String) -> Color {
        if hex == Settings.VideoService.noneColor {
            return .clear
        }
        if hex.hasPrefix("&H") {
            let hex = String(hex.dropFirst(2))
            var int = UInt32()
            Scanner(string: hex).scanHexInt32(&int)
            let b = Double((int >> 16) & 0xFF) / 255.0
            let g = Double((int >> 8) & 0xFF) / 255.0
            let r = Double(int & 0xFF) / 255.0
            return Color(red: r, green: g, blue: b)
        }
        return .white
    }

    private func isColorEnabled(_ hex: String) -> Bool {
        return hex != Settings.VideoService.noneColor
    }

    var body: some View {
        Form {
            Section("Font Settings") {
                Picker("Font Name", selection: $settings.videoService.fontName) {
                    if isLoadingFonts {
                        Text("Loading fonts...").tag("")
                    }
                    ForEach(systemFonts) { font in
                        if let localizedName = font.localizedName {
                            Text("\(localizedName) (\(font.englishName))").tag(font.id)
                        } else {
                            Text(font.englishName).tag(font.id)
                        }
                    }
                }

                HStack {
                    Text("Custom Font File")
                    Spacer()
                    Button(
                        settings.videoService.fontPath.isEmpty
                            ? "Select Font"
                            : (settings.videoService.fontPath as NSString).lastPathComponent
                    ) {
                        showingFontPicker = true
                    }
                }
                .fileImporter(
                    isPresented: $showingFontPicker,
                    allowedContentTypes: [.font],
                    allowsMultipleSelection: false
                ) { result in
                    switch result {
                    case .success(let urls):
                        if let url = urls.first {
                            settings.videoService.fontPath = url.path
                        }
                    case .failure(let error):
                        print("Font selection failed: \(error.localizedDescription)")
                    }
                }
            }

            Section("Color Settings") {
                Toggle(isOn: $isPrimaryColorEnabled) {
                    Text("Primary Color")
                }
                .onChange(of: isPrimaryColorEnabled) { isEnabled in
                    settings.videoService.primaryColor =
                        isEnabled
                        ? colorToHex(selectedPrimaryColor) : Settings.VideoService.noneColor
                }

                if isPrimaryColorEnabled {
                    HStack {
                        ColorPicker("", selection: $selectedPrimaryColor)
                            .onChange(of: selectedPrimaryColor) { newColor in
                                settings.videoService.primaryColor = colorToHex(newColor)
                            }
                        Text(colorToHex(selectedPrimaryColor))
                            .foregroundColor(.secondary)
                            .font(.caption)
                            .onTapGesture {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(
                                    colorToHex(selectedPrimaryColor), forType: .string)
                            }
                            .contextMenu {
                                Button(action: {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(
                                        colorToHex(selectedPrimaryColor), forType: .string)
                                }) {
                                    Label("Copy", systemImage: "doc.on.doc")
                                }
                            }
                    }
                }

                Toggle(isOn: $isSecondaryColorEnabled) {
                    Text("Secondary Color")
                }
                .onChange(of: isSecondaryColorEnabled) { isEnabled in
                    settings.videoService.secondaryColor =
                        isEnabled
                        ? colorToHex(selectedSecondaryColor) : Settings.VideoService.noneColor
                }

                if isSecondaryColorEnabled {
                    HStack {
                        ColorPicker("", selection: $selectedSecondaryColor)
                            .onChange(of: selectedSecondaryColor) { newColor in
                                settings.videoService.secondaryColor = colorToHex(newColor)
                            }
                        Text(colorToHex(selectedSecondaryColor))
                            .foregroundColor(.secondary)
                            .font(.caption)
                    }
                }

                Toggle(isOn: $isOutlineColorEnabled) {
                    Text("Outline Color")
                }
                .onChange(of: isOutlineColorEnabled) { isEnabled in
                    settings.videoService.outlineColor =
                        isEnabled
                        ? colorToHex(selectedOutlineColor) : Settings.VideoService.noneColor
                }

                if isOutlineColorEnabled {
                    HStack {
                        ColorPicker("", selection: $selectedOutlineColor)
                            .onChange(of: selectedOutlineColor) { newColor in
                                settings.videoService.outlineColor = colorToHex(newColor)
                            }
                        Text(colorToHex(selectedOutlineColor))
                            .foregroundColor(.secondary)
                            .font(.caption)
                    }
                }

                Toggle(isOn: $isBackColorEnabled) {
                    Text("Background Color")
                }
                .onChange(of: isBackColorEnabled) { isEnabled in
                    settings.videoService.backColor =
                        isEnabled ? colorToHex(selectedBackColor) : Settings.VideoService.noneColor
                }

                if isBackColorEnabled {
                    HStack {
                        ColorPicker("", selection: $selectedBackColor)
                            .onChange(of: selectedBackColor) { newColor in
                                settings.videoService.backColor = colorToHex(newColor)
                            }
                        Text(colorToHex(selectedBackColor))
                            .foregroundColor(.secondary)
                            .font(.caption)
                    }
                }
            }
            .onAppear {
                if systemFonts.isEmpty {
                    loadSystemFonts()
                }
                isPrimaryColorEnabled =
                    settings.videoService.primaryColor != Settings.VideoService.noneColor
                isSecondaryColorEnabled =
                    settings.videoService.secondaryColor != Settings.VideoService.noneColor
                isOutlineColorEnabled =
                    settings.videoService.outlineColor != Settings.VideoService.noneColor
                isBackColorEnabled =
                    settings.videoService.backColor != Settings.VideoService.noneColor

                if isPrimaryColorEnabled {
                    selectedPrimaryColor = hexToColor(settings.videoService.primaryColor)
                }
                if isSecondaryColorEnabled {
                    selectedSecondaryColor = hexToColor(settings.videoService.secondaryColor)
                }
                if isOutlineColorEnabled {
                    selectedOutlineColor = hexToColor(settings.videoService.outlineColor)
                }
                if isBackColorEnabled {
                    selectedBackColor = hexToColor(settings.videoService.backColor)
                }
            }

            Section("Subtitle Style") {
                HStack {
                    Text("Font Size")
                    TextField(
                        "", value: $settings.videoService.fontSize, formatter: NumberFormatter()
                    )
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 100)
                }

                HStack {
                    Text("Text Scale: \(Int(settings.videoService.textScale * 100))%")
                    Slider(
                        value: $settings.videoService.textScale,
                        in: 0.5...2.0,
                        step: 0.1
                    )
                    .frame(width: 200)
                }

                HStack {
                    Text("Max Characters Per Line: \(settings.videoService.maxCharactersPerLine)")
                    Slider(
                        value: Binding(
                            get: { Double(settings.videoService.maxCharactersPerLine) },
                            set: { settings.videoService.maxCharactersPerLine = Int($0) }
                        ),
                        in: 20...100,
                        step: 1
                    )
                    .frame(width: 200)
                }

                HStack {
                    Text("Margin Horizontal: \(settings.videoService.marginHorizontal)")
                    Slider(
                        value: Binding(
                            get: { Double(settings.videoService.marginHorizontal) },
                            set: { settings.videoService.marginHorizontal = Int($0) }
                        ),
                        in: 0...100,
                        step: 1
                    )
                    .frame(width: 200)
                }

                HStack {
                    Text("Margin Bottom: \(settings.videoService.marginBottom)")
                    Slider(
                        value: Binding(
                            get: { Double(settings.videoService.marginBottom) },
                            set: { settings.videoService.marginBottom = Int($0) }
                        ),
                        in: 0...100,
                        step: 1
                    )
                    .frame(width: 200)
                }

                HStack {
                    Text(
                        "Shadow Depth: \(String(format: "%.1f", settings.videoService.shadowDepth))"
                    )
                    Slider(
                        value: $settings.videoService.shadowDepth,
                        in: 0...5,
                        step: 0.1
                    )
                    .frame(width: 200)
                }

                HStack {
                    Text(
                        "Outline Width: \(String(format: "%.1f", settings.videoService.outlineWidth))"
                    )
                    Slider(
                        value: $settings.videoService.outlineWidth,
                        in: 0...5,
                        step: 0.1
                    )
                    .frame(width: 200)
                }

                HStack {
                    Text(
                        "Shadow Depth: \(String(format: "%.1f", settings.videoService.shadowDepth))"
                    )
                    Slider(
                        value: $settings.videoService.shadowDepth,
                        in: 0...5,
                        step: 0.1
                    )
                    .frame(width: 200)
                }

                Picker("Border Style", selection: $settings.videoService.borderStyle) {
                    ForEach(Settings.VideoService.BorderStyle.allCases, id: \.self) { style in
                        Text(style.description).tag(style)
                    }
                }
            }

            Section("Audio Settings") {
                Toggle("Enhance Voice", isOn: $settings.videoService.enhanceVoice)
                    .help("Reduce background noise and enhance human voice in the video")
            }
        }
    }
}

struct WhisperServiceSettingsView: View {
    @ObservedObject var settings: Settings
    @State private var isDownloading = false
    @State private var downloadProgress: Double = 0
    @State private var downloadStatus: String = ""
    @State private var estimatedTimeRemaining: String = ""
    @State private var currentModelPath: String = ""
    @State private var downloadedModelName: String = ""
    private let formatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter
    }()

    var body: some View {
        Form {
            Section("Model") {
                Picker("Model", selection: $settings.whisperService.selectedModel) {
                    ForEach(Settings.WhisperService.WhisperModel.allCases) { model in
                        Text(model.displayName).tag(model)
                    }
                }

                HStack {
                    Text("Model Path:")
                    Spacer()
                    Text(downloadedModelName == settings.whisperService.selectedModel.fileName
                        ? (currentModelPath.isEmpty ? "Not downloaded" : currentModelPath)
                        : "Switch model to download")
                        .font(.caption)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundColor(downloadedModelName == settings.whisperService.selectedModel.fileName
                            ? (currentModelPath.isEmpty ? .secondary : .primary)
                            : .accentColor)
                }

                if isDownloading {
                    VStack(alignment: .leading, spacing: 4) {
                        ProgressView(value: downloadProgress)
                            .frame(maxWidth: .infinity)
                        HStack {
                            Text(downloadStatus)
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Spacer()
                            Group {
                                if !estimatedTimeRemaining.isEmpty {
                                    Text(estimatedTimeRemaining)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                Text(String(format: "%.0f%%", downloadProgress * 100))
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                } else {
                    Button(action: downloadModel) {
                        HStack {
                            Image(systemName: "arrow.down.circle")
                            Text("Download Model")
                        }
                    }
                    .disabled(isDownloading || (downloadedModelName == settings.whisperService.selectedModel.fileName && !currentModelPath.isEmpty))
                }
            }

            Section("Audio Recognition Settings") {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Temperature: \(settings.whisperService.temperature, specifier: "%.2f")")
                    Slider(value: $settings.whisperService.temperature, in: 0...1, step: 0.05)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Context Length")
                    TextField(
                        "", value: $settings.whisperService.contextLength, formatter: formatter
                    )
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: .infinity)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Max CJK Segment Length")
                    TextField(
                        "", value: $settings.whisperService.maxCJKSegmentLength,
                        formatter: formatter
                    )
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: .infinity)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Max Default Segment Length")
                    TextField(
                        "", value: $settings.whisperService.maxDefaultSegmentLength,
                        formatter: formatter
                    )
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .onAppear {
            self.currentModelPath = WhisperService.shared.currentModelPath
            if !self.currentModelPath.isEmpty {
                self.downloadedModelName = (self.currentModelPath as NSString).lastPathComponent
            }
        }
    }

    private func downloadModel() {
        isDownloading = true
        downloadProgress = 0
        downloadStatus = "Downloading model..."

        Task {
            do {
                try await WhisperService.shared.initializeModel { progress in
                    Task { @MainActor in
                        downloadProgress = progress.progress
                        switch progress.status {
                        case .downloading:
                            let downloaded = formatBytes(progress.bytesDownloaded)
                            let total = formatBytes(progress.totalBytes)
                            downloadStatus = "Downloading: \(downloaded)/\(total)"
                            if let eta = progress.estimatedTimeRemaining,
                                eta.isFinite, eta > 0
                            {
                                estimatedTimeRemaining = "(\(formatETA(eta)) left)"
                            } else {
                                estimatedTimeRemaining = ""
                            }
                        case .completed:
                            downloadStatus = "Download complete!"
                            estimatedTimeRemaining = ""
                        default:
                            break
                        }
                    }
                }
                currentModelPath = WhisperService.shared.currentModelPath
                isDownloading = false
            } catch {
                downloadStatus = "Download failed: \(error.localizedDescription)"
                estimatedTimeRemaining = ""
                isDownloading = false
            }
        }
    }

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

struct LLMServiceSettingsView: View {
    @ObservedObject var settings: Settings
    @State private var showingAddProvider = false

    var body: some View {
        Form {
            Section("LLM Settings for translation") {
                Slider(
                    value: $settings.llmService.temperature,
                    in: 0.0...1.0,
                    step: 0.05
                ) {
                    Text("Temperature: \(settings.llmService.temperature, specifier: "%.2f")")
                } minimumValueLabel: {
                    Text("0.0")
                } maximumValueLabel: {
                    Text("1.0")
                }
                .help(
                    "Controls randomness in responses (0.0 = more deterministic, 1.0 = more creative)"
                )

                Slider(
                    value: $settings.llmService.topP,
                    in: 0.0...1.0,
                    step: 0.05
                ) {
                    Text("Top P: \(settings.llmService.topP, specifier: "%.2f")")
                } minimumValueLabel: {
                    Text("0.0")
                } maximumValueLabel: {
                    Text("1.0")
                }
                .help("Controls diversity of responses")

                Slider(
                    value: Binding(
                        get: { Double(settings.llmService.maxChatHistoryCount) },
                        set: { settings.llmService.maxChatHistoryCount = Int($0.rounded()) }
                    ),
                    in: 1...100,
                    step: 5
                ) {
                    Text("Max Chat History: \(settings.llmService.maxChatHistoryCount)")
                } minimumValueLabel: {
                    Text("1")
                } maximumValueLabel: {
                    Text("100")
                }
                .help("Maximum number of messages to keep in chat history")

                Slider(
                    value: Binding(
                        get: { Double(settings.llmService.translationBatchSize) },
                        set: { settings.llmService.translationBatchSize = Int($0.rounded()) }
                    ),
                    in: 10...200,
                    step: 10
                ) {
                    Text("Translation Batch Size: \(settings.llmService.translationBatchSize)")
                } minimumValueLabel: {
                    Text("10")
                } maximumValueLabel: {
                    Text("200")
                }
                .help("Number of subtitles per translation request. Larger = fewer API calls but more context.")

                HStack {
                    Text("Timeout")
                    TextField("", value: $settings.llmService.timeout, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)
                    Text("seconds")
                }
                .help("Request timeout duration in seconds")

                // set num_ctx
                HStack {
                    Text("Context size")
                    TextField("", value: $settings.llmService.numCtx, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)
                }
                .help("Context window size for ollama")
            }

            Section("Providers") {
                ForEach(settings.llmService.providers) { provider in
                    ProviderRowView(settings: settings, provider: provider)
                }

                Button(action: {
                    showingAddProvider = true
                }) {
                    Label("Add Provider", systemImage: "plus")
                }
            }
        }
        .sheet(isPresented: $showingAddProvider) {
            AddProviderView(settings: settings)
        }
    }
}

struct ProviderRowView: View {
    @ObservedObject var settings: Settings
    let provider: Settings.LLMService.Provider
    @State private var isEditing = false

    var body: some View {
        VStack(alignment: .leading) {
            HStack {
                VStack(alignment: .leading) {
                    Text(provider.apiType.rawValue.capitalized)
                        .font(.headline)
                    Text(provider.url)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()

                if provider.id == settings.llmService.selectedProviderId {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.accentColor)
                }

                Button(action: {
                    isEditing = true
                }) {
                    Image(systemName: "pencil")
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                settings.llmService.selectedProviderId = provider.id
            }
        }
        .sheet(isPresented: $isEditing) {
            EditProviderView(settings: settings, provider: provider)
        }
    }
}

struct AddProviderView: View {
    @ObservedObject var settings: Settings
    @Environment(\.dismiss) private var dismiss
    @State private var apiType: Settings.LLMService.APIType = .ollama
    @State private var url = ""
    @State private var apiKey = ""
    @State private var chatModel = ""
    @State private var toolModel = ""
    @State private var visionModel = ""
    @State private var availableModels: [String] = []
    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        Form {
            Section {
                Picker("Type", selection: $apiType) {
                    Text("Ollama").tag(Settings.LLMService.APIType.ollama)
                    Text("OpenAI").tag(Settings.LLMService.APIType.openai)
                }
                .pickerStyle(.menu)
                .padding(.vertical, 4)
            }

            Section {
                VStack(spacing: 12) {
                    TextField("URL", text: $url)
                        .textFieldStyle(.roundedBorder)
                    SecureField("API Key", text: $apiKey)
                        .textFieldStyle(.roundedBorder)

                    if apiType == .ollama {
                        if isLoading {
                            ProgressView()
                                .padding(.vertical, 8)
                        } else {
                            VStack(alignment: .leading, spacing: 12) {
                                Picker("Chat Model", selection: $chatModel) {
                                    if availableModels.isEmpty {
                                        Text("No models found").tag("")
                                    } else {
                                        ForEach(availableModels, id: \.self) { model in
                                            Text(model).tag(model)
                                        }
                                    }
                                }
                                .pickerStyle(.menu)

                                Picker("Tool Model", selection: $toolModel) {
                                    if availableModels.isEmpty {
                                        Text("No models found").tag("")
                                    } else {
                                        ForEach(availableModels, id: \.self) { model in
                                            Text(model).tag(model)
                                        }
                                    }
                                }
                                .pickerStyle(.menu)

                                Picker("Vision Model", selection: $visionModel) {
                                    if availableModels.isEmpty {
                                        Text("No models found").tag("")
                                    } else {
                                        ForEach(availableModels, id: \.self) { model in
                                            Text(model).tag(model)
                                        }
                                    }
                                }
                                .pickerStyle(.menu)

                                if let error = errorMessage {
                                    Text(error)
                                        .foregroundColor(.red)
                                        .font(.caption)
                                        .padding(.top, 4)
                                }
                            }
                        }
                    } else if apiType == .openai {
                        if isLoading {
                            ProgressView()
                                .padding(.vertical, 8)
                        } else {
                            VStack(alignment: .leading, spacing: 12) {
                                Picker("Chat Model", selection: $chatModel) {
                                    if availableModels.isEmpty {
                                        Text("No models found").tag("")
                                    } else {
                                        ForEach(availableModels, id: \.self) { model in
                                            Text(model).tag(model)
                                        }
                                    }
                                }
                                .pickerStyle(.menu)

                                Picker("Tool Model", selection: $toolModel) {
                                    if availableModels.isEmpty {
                                        Text("No models found").tag("")
                                    } else {
                                        ForEach(availableModels, id: \.self) { model in
                                            Text(model).tag(model)
                                        }
                                    }
                                }
                                .pickerStyle(.menu)

                                Picker("Vision Model", selection: $visionModel) {
                                    if availableModels.isEmpty {
                                        Text("No models found").tag("")
                                    } else {
                                        ForEach(availableModels, id: \.self) { model in
                                            Text(model).tag(model)
                                        }
                                    }
                                }
                                .pickerStyle(.menu)

                                if let error = errorMessage {
                                    Text(error)
                                        .foregroundColor(.red)
                                        .font(.caption)
                                        .padding(.top, 4)
                                }
                            }
                        }
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .frame(width: 400)
        .padding(4)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") {
                    dismiss()
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Add") {
                    let newProvider = Settings.LLMService.Provider(
                        id: UUID(),
                        apiType: apiType,
                        url: url,
                        apiKey: apiKey,
                        chatModel: chatModel,
                        toolModel: toolModel,
                        visionModel: visionModel
                    )
                    settings.llmService.providers.append(newProvider)
                    dismiss()
                }
            }
        }
        .task {
            if apiType == .ollama {
                await loadOllamaModels()
            } else if apiType == .openai {
                await loadOpenAIModels()
            }
        }
        .onChange(of: url) { _ in
            if apiType == .ollama {
                Task {
                    await loadOllamaModels()
                }
            } else if apiType == .openai {
                Task {
                    await loadOpenAIModels()
                }
            }
        }
        .onChange(of: apiKey) { _ in
            if apiType == .openai {
                Task {
                    await loadOpenAIModels()
                }
            }
        }
        .onChange(of: apiType) { _ in
            availableModels = []
            if apiType == .ollama {
                Task {
                    await loadOllamaModels()
                }
            } else if apiType == .openai {
                Task {
                    await loadOpenAIModels()
                }
            }
        }
    }

    private func loadOllamaModels() async {
        isLoading = true
        errorMessage = nil

        do {
            guard let url = URL(string: "\(url)/api/tags") else {
                errorMessage = "Invalid URL"
                isLoading = false
                return
            }

            let (data, _) = try await URLSession.shared.data(from: url)
            let response = try JSONDecoder().decode(OllamaModelsResponse.self, from: data)
            availableModels = response.models.map { $0.name }
        } catch {
            errorMessage = "Failed to load models: \(error.localizedDescription)"
            LoggerService.shared.log("Failed to load Ollama models: \(error)", level: .warning)
        }

        isLoading = false
    }

    private func loadOpenAIModels() async {
        isLoading = true
        errorMessage = nil
        availableModels = []

        do {
            guard var components = URLComponents(string: url) else {
                errorMessage = "Invalid URL"
                isLoading = false
                return
            }
            components.path = (components.path.hasSuffix("/") ? components.path : components.path + "/") + "v1/models"
            guard let apiUrl = components.url else {
                errorMessage = "Invalid URL"
                isLoading = false
                return
            }

            var request = URLRequest(url: apiUrl)
            if !apiKey.isEmpty {
                request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            }

            let (data, _) = try await URLSession.shared.data(for: request)
            let response = try JSONDecoder().decode(OpenAIModelsResponse.self, from: data)
            availableModels = response.data.map { $0.id }
        } catch {
            errorMessage = "Failed to load models: \(error.localizedDescription)"
            LoggerService.shared.log("Failed to load OpenAI models: \(error)", level: .warning)
        }

        isLoading = false
    }
}

struct EditProviderView: View {
    @ObservedObject var settings: Settings
    let provider: Settings.LLMService.Provider
    @Environment(\.dismiss) private var dismiss
    @State private var url: String
    @State private var apiKey: String
    @State private var chatModel: String
    @State private var toolModel: String
    @State private var visionModel: String
    @State private var availableModels: [String] = []
    @State private var isLoading = false
    @State private var errorMessage: String?

    init(settings: Settings, provider: Settings.LLMService.Provider) {
        self.settings = settings
        self.provider = provider
        _url = State(initialValue: provider.url)
        _apiKey = State(initialValue: provider.apiKey)
        _chatModel = State(initialValue: provider.chatModel)
        _toolModel = State(initialValue: provider.toolModel)
        _visionModel = State(initialValue: provider.visionModel)
    }

    var body: some View {
        Form {
            Section {
                Text(provider.apiType.rawValue.capitalized)
                    .foregroundColor(.secondary)
                    .padding(.vertical, 4)
            }

            Section {
                VStack(spacing: 12) {
                    TextField("URL", text: $url)
                        .textFieldStyle(.roundedBorder)
                    TextField("API Key", text: $apiKey)
                        .textFieldStyle(.roundedBorder)

                    if provider.apiType == .ollama {
                        if isLoading {
                            ProgressView()
                                .padding(.vertical, 8)
                        } else {
                            VStack(alignment: .leading, spacing: 12) {
                                Picker("Chat Model", selection: $chatModel) {
                                    if availableModels.isEmpty {
                                        Text("No models found").tag("")
                                    } else {
                                        ForEach(availableModels, id: \.self) { model in
                                            Text(model).tag(model)
                                        }
                                    }
                                }
                                .pickerStyle(.menu)

                                Picker("Tool Model", selection: $toolModel) {
                                    if availableModels.isEmpty {
                                        Text("No models found").tag("")
                                    } else {
                                        ForEach(availableModels, id: \.self) { model in
                                            Text(model).tag(model)
                                        }
                                    }
                                }
                                .pickerStyle(.menu)

                                Picker("Vision Model", selection: $visionModel) {
                                    if availableModels.isEmpty {
                                        Text("No models found").tag("")
                                    } else {
                                        ForEach(availableModels, id: \.self) { model in
                                            Text(model).tag(model)
                                        }
                                    }
                                }
                                .pickerStyle(.menu)

                                if let error = errorMessage {
                                    Text(error)
                                        .foregroundColor(.red)
                                        .font(.caption)
                                        .padding(.top, 4)
                                }
                            }
                        }
                    } else if provider.apiType == .openai {
                        if isLoading {
                            ProgressView()
                                .padding(.vertical, 8)
                        } else {
                            VStack(alignment: .leading, spacing: 12) {
                                Picker("Chat Model", selection: $chatModel) {
                                    if availableModels.isEmpty {
                                        Text("No models found").tag("")
                                    } else {
                                        ForEach(availableModels, id: \.self) { model in
                                            Text(model).tag(model)
                                        }
                                    }
                                }
                                .pickerStyle(.menu)

                                Picker("Tool Model", selection: $toolModel) {
                                    if availableModels.isEmpty {
                                        Text("No models found").tag("")
                                    } else {
                                        ForEach(availableModels, id: \.self) { model in
                                            Text(model).tag(model)
                                        }
                                    }
                                }
                                .pickerStyle(.menu)

                                Picker("Vision Model", selection: $visionModel) {
                                    if availableModels.isEmpty {
                                        Text("No models found").tag("")
                                    } else {
                                        ForEach(availableModels, id: \.self) { model in
                                            Text(model).tag(model)
                                        }
                                    }
                                }
                                .pickerStyle(.menu)

                                if let error = errorMessage {
                                    Text(error)
                                        .foregroundColor(.red)
                                        .font(.caption)
                                        .padding(.top, 4)
                                }
                            }
                        }
                    }
                }
                .padding(.vertical, 4)
            }

            Section {
                Button("Delete", role: .destructive) {
                    if let index = settings.llmService.providers.firstIndex(where: {
                        $0.id == provider.id
                    }) {
                        settings.llmService.providers.remove(at: index)
                        if settings.llmService.selectedProviderId == provider.id {
                            settings.llmService.selectedProviderId =
                                settings.llmService.providers.first?.id
                                ?? Settings.LLMService.Provider.defaultOllama.id
                        }
                    }
                    dismiss()
                }
                .padding(.vertical, 4)
            }
        }
        .frame(width: 400)
        .padding(4)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") {
                    dismiss()
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    let updatedProvider = Settings.LLMService.Provider(
                        id: provider.id,
                        apiType: provider.apiType,
                        url: url,
                        apiKey: apiKey,
                        chatModel: chatModel,
                        toolModel: toolModel,
                        visionModel: visionModel
                    )
                    if let index = settings.llmService.providers.firstIndex(where: {
                        $0.id == provider.id
                    }) {
                        settings.llmService.providers[index] = updatedProvider
                    }
                    dismiss()
                }
            }
        }
        .task {
            if provider.apiType == .ollama {
                await loadOllamaModels()
            } else if provider.apiType == .openai {
                await loadOpenAIModels()
            }
        }
        .onChange(of: url) { _ in
            if provider.apiType == .ollama {
                Task {
                    await loadOllamaModels()
                }
            } else if provider.apiType == .openai {
                Task {
                    await loadOpenAIModels()
                }
            }
        }
        .onChange(of: apiKey) { _ in
            if provider.apiType == .openai {
                Task {
                    await loadOpenAIModels()
                }
            }
        }
    }

    private func loadOllamaModels() async {
        isLoading = true
        errorMessage = nil

        do {
            guard let url = URL(string: "\(url)/api/tags") else {
                errorMessage = "Invalid URL"
                isLoading = false
                return
            }

            let (data, _) = try await URLSession.shared.data(from: url)
            let response = try JSONDecoder().decode(OllamaModelsResponse.self, from: data)
            availableModels = response.models.map { $0.name }
        } catch {
            errorMessage = "Failed to load models: \(error.localizedDescription)"
            LoggerService.shared.log("Failed to load Ollama models: \(error)", level: .warning)
        }

        isLoading = false
    }

    private func loadOpenAIModels() async {
        isLoading = true
        errorMessage = nil
        availableModels = []

        do {
            guard var components = URLComponents(string: url) else {
                errorMessage = "Invalid URL"
                isLoading = false
                return
            }
            components.path = (components.path.hasSuffix("/") ? components.path : components.path + "/") + "v1/models"
            guard let apiUrl = components.url else {
                errorMessage = "Invalid URL"
                isLoading = false
                return
            }

            var request = URLRequest(url: apiUrl)
            if !apiKey.isEmpty {
                request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            }

            let (data, _) = try await URLSession.shared.data(for: request)
            let response = try JSONDecoder().decode(OpenAIModelsResponse.self, from: data)
            availableModels = response.data.map { $0.id }
        } catch {
            errorMessage = "Failed to load models: \(error.localizedDescription)"
            LoggerService.shared.log("Failed to load OpenAI models: \(error)", level: .warning)
        }

        isLoading = false
    }
}

private struct OllamaModelsResponse: Codable {
    struct Model: Codable {
        let name: String
    }
    let models: [Model]
}

private struct OpenAIModelsResponse: Codable {
    struct Model: Codable {
        let id: String
    }
    let data: [Model]
}
