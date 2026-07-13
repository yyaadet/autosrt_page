import Combine
import Foundation

public enum SettingsError: LocalizedError {
    case fileAccessError
    case invalidData
    case saveFailed(Error)

    public var errorDescription: String? {
        switch self {
        case .fileAccessError:
            return "Could not access settings file"
        case .invalidData:
            return "Settings file contains invalid data"
        case .saveFailed(let error):
            return "Failed to save settings: \(error.localizedDescription)"
        }
    }
}

public class Settings: ObservableObject {
    // MARK: - Singleton
    public static let shared = Settings()
    private let logger: LoggerService = LoggerService.shared

    // MARK: - Word Service Settings
    public struct WordService: Codable {
        public static let maxTokenLength: Int = 128
        public static let seperators: String = ",.!?;，。？！、；"

        public var minSimilarity: Double = 0.5
        public var contextLength: Int = 100

        public enum Alignment: String, Codable, CaseIterable {
            case source
            case translation
            case all

            var description: String {
                switch self {
                case .source:
                    return "Source"
                case .translation:
                    return "Translation"
                case .all:
                    return "All"
                }
            }
        }

        public var alignment: Alignment = .translation
    }

    // MARK: - Video Service Settings
    public struct VideoService: Codable {
        public static let noneColor = "&H000000"

        public enum BorderStyle: Int, Codable, CaseIterable {
            case none = 1
            case outline = 3
            case opaqueBg = 4

            var description: String {
                switch self {
                case .none:
                    return "None"
                case .outline:
                    return "Outline"
                case .opaqueBg:
                    return "Opaque Background"
                }
            }
        }
        public var fontName: String = "PingFang SC"
        public var fontPath: String = ""
        public var fontSize: Double = 30.0

        // Color settings
        public var primaryColor: String = "&HFFFFFF"
        public var secondaryColor: String = "&HFF0000"
        public var outlineColor: String = "&H000000"
        public var backColor: String = "&H000000"

        // Subtitle style settings
        public var outlineWidth: Double = 0.8
        public var shadowDepth: Double = 0.5
        public var marginHorizontal: Int = 10
        public var marginBottom: Int = 2
        public var textScale: Double = 0.8
        public var borderStyle: BorderStyle = .opaqueBg
        public var maxCharactersPerLine: Int = 30
        public var enhanceVoice: Bool = true
    }

    // MARK: - LLM Service Settings
    public struct LLMService: Codable {
        private static let providersKey = "com.autosrt.settings.providers"

        public enum APIType: String, Codable, Sendable {
            case ollama
            case openai
        }

        public struct Provider: Codable, Identifiable, Sendable {
            public let id: UUID
            public var apiType: APIType
            public var url: String
            public var apiKey: String
            public var chatModel: String
            public var toolModel: String
            public var visionModel: String

            public static let defaultOllama = Provider(
                id: UUID(),
                apiType: .ollama,
                url: "http://localhost:11434",
                apiKey: "",
                chatModel: "ministral-3:8b",
                toolModel: "ministral-3:8b",
                visionModel: "ministral-3:8b"
            )

            public static let defaultOpenAI = Provider(
                id: UUID(),
                apiType: .openai,
                url: "https://api.openai.com/",
                apiKey: "",
                chatModel: "gpt-4-turbo-preview",
                toolModel: "gpt-4",
                visionModel: "gpt-4-vision-preview"
            )
        }

        public static let maxTokenLength: Int = 512  // for sentence bert
        public static let sentenceModelUrl: String = """
            https://github.com/yyaadet/llmsurf/releases/download/v1.0.0/SentenceBERT.mlmodelc.zip
            """

        public static let rerankModelUrl: String = """
            https://github.com/yyaadet/llmsurf/releases/download/v1.0.0/BGEReranker.mlmodelc.zip
            """
        public static let rerankModelUrlLarge: String = """
            https://github.com/yyaadet/llmsurf/releases/download/v1.1.0/BGERerankerLarge.mlmodelc.zip
            """

        // Request parameters
        public var numCtx = 4096 * 8
        public var temperature: Double = 0.4
        public var topP: Double = 0.85
        public var maxChatHistoryCount: Int = 30
        /// Number of subtitles sent per translation request. Larger = fewer API calls.
        public var translationBatchSize: Int = 60
        public var timeout: TimeInterval = 600  // request timeout in seconds

        // Provider configurations
        public var providers: [Provider] {
            get {
                if let data = UserDefaults.standard.data(forKey: LLMService.providersKey),
                    let providers = try? JSONDecoder().decode([Provider].self, from: data)
                {
                    return providers
                }
                // Return default providers if nothing is saved
                return [.defaultOllama, .defaultOpenAI]
            }
            set {
                if let data = try? JSONEncoder().encode(newValue) {
                    UserDefaults.standard.set(data, forKey: LLMService.providersKey)
                }
            }
        }
        public var selectedProviderId: UUID = Provider.defaultOllama.id

        // Current provider
        public var provider: Provider {
            get {
                providers.first { $0.id == selectedProviderId } ?? .defaultOllama
            }
            set {
                if let index = providers.firstIndex(where: { $0.id == newValue.id }) {
                    providers[index] = newValue
                } else {
                    providers.append(newValue)
                }
                selectedProviderId = newValue.id
            }
        }

        // Convenience accessors
        public var chatModel: String { provider.chatModel }
        public var toolModel: String { provider.toolModel }
        public var visionModel: String { provider.visionModel }
        public var apiKey: String { provider.apiKey }
        public var url: String { provider.url }
        public var apiType: APIType { provider.apiType }
    }

    // MARK: - Whisper Service Settings
    public struct WhisperService: Codable {
        public enum WhisperModel: String, Codable, CaseIterable, Identifiable {
            case base = "base"
            case small = "small"
            case medium = "medium"
            case largeV3Turbo = "large-v3-turbo"

            public var id: String { rawValue }

            var displayName: String {
                switch self {
                case .base: return "Base (fastest, ~140MB)"
                case .small: return "Small (fast, ~460MB)"
                case .medium: return "Medium (balanced, ~1.4GB)"
                case .largeV3Turbo: return "Large V3 Turbo (best accuracy, ~1.5GB)"
                }
            }

            var fileName: String {
                "ggml-\(rawValue).bin"
            }

            var downloadUrl: String {
                "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/\(fileName)"
            }
        }

        public static let defaultModel = WhisperModel.largeV3Turbo

        public var temperature: Double = 0
        public var contextLength: Int = 512
        public var maxCJKSegmentLength: Int = 9
        public var maxDefaultSegmentLength: Int = 20
        public var selectedModel: WhisperModel = .largeV3Turbo
    }

    // MARK: - UI Settings
    public struct UI: Codable {
        // Window settings
        public var videoPlayerMinWidth: Double = 480
        public var videoPlayerMinHeight: Double = 320
        public var editorMinWidth: Double = 320
        public var editorMinHeight: Double = 480
    }

    // MARK: - Properties
    @Published public var wordService: WordService
    @Published public var videoService: VideoService
    @Published public var whisperService: WhisperService
    @Published public var ui: UI
    @Published public var llmService: LLMService

    // MARK: - Private Properties
    private let fileManager = FileManager.default
    private let queue = DispatchQueue(label: "com.autosrt.settings")

    // MARK: - Codable
    enum CodingKeys: String, CodingKey {
        case wordService
        case videoService
        case whisperService
        case ui
        case llmService
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(wordService, forKey: .wordService)
        try container.encode(videoService, forKey: .videoService)
        try container.encode(whisperService, forKey: .whisperService)
        try container.encode(ui, forKey: .ui)
        try container.encode(llmService, forKey: .llmService)
    }

    // MARK: - Initialization
    init() {
        // Initialize with default values
        self.wordService = WordService()
        self.videoService = VideoService()
        self.whisperService = WhisperService()
        self.ui = UI()
        self.llmService = LLMService()

        // Try to load from disk
        loadFromDisk()
    }

    // MARK: - File Operations
    private func loadFromDisk() {
        do {
            let url = try FileManager.default
                .url(
                    for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil,
                    create: true
                )
                .appendingPathComponent("AutoSRT")
                .appendingPathComponent("settings.ini")

            let content = try String(contentsOf: url, encoding: .utf8)
            let sections = try IniParser.parse(content)

            for section in sections {
                switch section.name {
                case "VideoService":

                    if let fontName = section.values["fontName"] {
                        self.videoService.fontName = fontName
                    }
                    if let fontPath = section.values["fontPath"] {
                        self.videoService.fontPath = fontPath
                    }
                    if let fontSize = Double(section.values["fontSize"] ?? "") {
                        self.videoService.fontSize = fontSize
                    }
                    if let primaryColor = section.values["primaryColor"] {
                        self.videoService.primaryColor = primaryColor
                    }
                    if let secondaryColor = section.values["secondaryColor"] {
                        self.videoService.secondaryColor = secondaryColor
                    }
                    if let outlineColor = section.values["outlineColor"] {
                        self.videoService.outlineColor = outlineColor
                    }
                    if let backColor = section.values["backColor"] {
                        self.videoService.backColor = backColor
                    }
                    if let outlineWidth = Double(section.values["outlineWidth"] ?? "") {
                        self.videoService.outlineWidth = outlineWidth
                    }
                    if let shadowDepth = Double(section.values["shadowDepth"] ?? "") {
                        self.videoService.shadowDepth = shadowDepth
                    }
                    if let marginHorizontal = Int(section.values["marginHorizontal"] ?? "") {
                        self.videoService.marginHorizontal = marginHorizontal
                    }
                    if let marginBottom = Int(section.values["marginBottom"] ?? "") {
                        self.videoService.marginBottom = marginBottom
                    }
                    if let textScale = Double(section.values["textScale"] ?? "") {
                        self.videoService.textScale = textScale
                    }
                    if let borderStyleRaw = Int(section.values["borderStyle"] ?? ""),
                        let borderStyle = VideoService.BorderStyle(rawValue: borderStyleRaw)
                    {
                        self.videoService.borderStyle = borderStyle
                    }
                    if let maxCharactersPerLine = Int(section.values["maxCharactersPerLine"] ?? "")
                    {
                        self.videoService.maxCharactersPerLine = maxCharactersPerLine
                    }
                    if let enhanceVoice = Bool(section.values["enhanceVoice"] ?? "") {
                        self.videoService.enhanceVoice = enhanceVoice
                    }

                case "WhisperService":
                    if let temperature = Double(section.values["temperature"] ?? "") {
                        self.whisperService.temperature = temperature
                    }
                    if let contextLength = Int(section.values["contextLength"] ?? "") {
                        self.whisperService.contextLength = contextLength
                    }
                    if let maxCJKSegmentLength = Int(section.values["maxCJKSegmentLength"] ?? "") {
                        self.whisperService.maxCJKSegmentLength = maxCJKSegmentLength
                    }
                    if let maxDefaultSegmentLength = Int(
                        section.values["maxDefaultSegmentLength"] ?? "")
                    {
                        self.whisperService.maxDefaultSegmentLength = maxDefaultSegmentLength
                    }
                    if let modelStr = section.values["selectedModel"],
                        let model = WhisperService.WhisperModel(rawValue: modelStr)
                    {
                        self.whisperService.selectedModel = model
                    }

                case "WordService":
                    if let minSimilarity = Double(section.values["minSimilarity"] ?? "") {
                        self.wordService.minSimilarity = minSimilarity
                    }
                    if let contextLength = Int(section.values["contextLength"] ?? "") {
                        self.wordService.contextLength = contextLength
                    }
                    if let alignmentStr = section.values["alignment"],
                        let alignment = WordService.Alignment(rawValue: alignmentStr)
                    {
                        self.wordService.alignment = alignment
                    }

                case "LLMService":
                    if let num_ctx = Int(section.values["num_ctx"] ?? "") {
                        self.llmService.numCtx = num_ctx
                    }
                    if let temperature = Double(section.values["temperature"] ?? "") {
                        self.llmService.temperature = temperature
                    }
                    if let topP = Double(section.values["topP"] ?? "") {
                        self.llmService.topP = topP
                    }
                    if let maxChatHistoryCount = Int(section.values["maxChatHistoryCount"] ?? "") {
                        self.llmService.maxChatHistoryCount = maxChatHistoryCount
                    }
                    if let translationBatchSize = Int(section.values["translationBatchSize"] ?? "") {
                        self.llmService.translationBatchSize = translationBatchSize
                    }
                    if let provider = section.values["provider"] {
                        self.llmService.selectedProviderId =
                            UUID(uuidString: provider) ?? LLMService.Provider.defaultOllama.id
                    }
                    if let timeout = TimeInterval(section.values["timeout"] ?? "") {
                        self.llmService.timeout = timeout
                    }

                default:
                    break
                }
            }

            logger.log("Load settings from disk \(url)")
        } catch {
            logger.log("Failed to load settings: \(error). Using defaults.", level: .warning)
        }
    }

    public func save() throws {
        do {
            let url = try FileManager.default
                .url(
                    for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil,
                    create: true
                )
                .appendingPathComponent("AutoSRT")

            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)

            let settingsUrl = url.appendingPathComponent("settings.ini")
            let content = IniParser.serialize(self)
            try content.write(to: settingsUrl, atomically: true, encoding: .utf8)

            logger.log("Settings saved to \(settingsUrl)")
        } catch {
            logger.log("Failed to save settings: \(error)", level: .error)
        }
    }

    public func reset() throws {
        queue.sync {
            // Reset to default values
            self.wordService = WordService()
            self.videoService = VideoService()
            self.whisperService = WhisperService()
            self.ui = UI()
            self.llmService = LLMService()

            try? save()
        }
    }
}

extension Settings: IniSerializable {
    func serialize() -> String {
        var content = ""

        content += "[VideoService]\n"
        content += "fontName=\(videoService.fontName)\n"
        content += "fontPath=\(videoService.fontPath)\n"
        content += "fontSize=\(videoService.fontSize)\n"
        content += "primaryColor=\(videoService.primaryColor)\n"
        content += "secondaryColor=\(videoService.secondaryColor)\n"
        content += "outlineColor=\(videoService.outlineColor)\n"
        content += "backColor=\(videoService.backColor)\n"
        content += "outlineWidth=\(videoService.outlineWidth)\n"
        content += "shadowDepth=\(videoService.shadowDepth)\n"
        content += "marginHorizontal=\(videoService.marginHorizontal)\n"
        content += "marginBottom=\(videoService.marginBottom)\n"
        content += "textScale=\(videoService.textScale)\n"
        content += "borderStyle=\(videoService.borderStyle.rawValue)\n"
        content += "maxCharactersPerLine=\(videoService.maxCharactersPerLine)\n"
        content += "enhanceVoice=\(videoService.enhanceVoice)\n"

        content += "\n[WhisperService]\n"
        content += "temperature=\(whisperService.temperature)\n"
        content += "contextLength=\(whisperService.contextLength)\n"
        content += "maxCJKSegmentLength=\(whisperService.maxCJKSegmentLength)\n"
        content += "maxDefaultSegmentLength=\(whisperService.maxDefaultSegmentLength)\n"
        content += "selectedModel=\(whisperService.selectedModel.rawValue)\n"

        content += "\n[WordService]\n"
        content += "minSimilarity=\(wordService.minSimilarity)\n"
        content += "contextLength=\(wordService.contextLength)\n"
        content += "alignment=\(wordService.alignment.rawValue)\n"

        // LLM Service
        content += "[LLMService]\n"
        content += "num_ctx=\(llmService.numCtx)\n"
        content += "temperature=\(llmService.temperature)\n"
        content += "topP=\(llmService.topP)\n"
        content += "maxChatHistoryCount=\(llmService.maxChatHistoryCount)\n"
        content += "translationBatchSize=\(llmService.translationBatchSize)\n"
        content += "provider=\(llmService.selectedProviderId.uuidString)\n"
        content += "timeout=\(llmService.timeout)\n"
        content += "\n"

        return content
    }
}

protocol IniSerializable {
    func serialize() -> String
}

class IniParser {
    static func parse(_ content: String) throws -> [IniSection] {
        var sections: [IniSection] = []
        var currentSection: IniSection?

        for line in content.components(separatedBy: "\n") {
            let trimmedLine = line.trimmingCharacters(in: .whitespaces)
            if trimmedLine.isEmpty {
                continue
            }

            if trimmedLine.hasPrefix("[") && trimmedLine.hasSuffix("]") {
                let sectionName = String(trimmedLine.dropFirst().dropLast())
                currentSection = IniSection(name: sectionName, values: [:])
                sections.append(currentSection!)
            } else if var section = sections.last {
                let keyValue = trimmedLine.components(separatedBy: "=")
                if keyValue.count == 2 {
                    let key = keyValue[0].trimmingCharacters(in: .whitespaces)
                    let value = keyValue[1].trimmingCharacters(in: .whitespaces)
                    section.values[key] = value
                    sections[sections.count - 1] = section
                }
            }
        }

        return sections
    }

    static func serialize(_ object: IniSerializable) -> String {
        return object.serialize()
    }
}

struct IniSection {
    let name: String
    var values: [String: String]

    init(name: String, values: [String: String] = [:]) {
        self.name = name
        self.values = values
    }
}
