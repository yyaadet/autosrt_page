import Foundation

// Protocol defining what a Model should be
public protocol ModelProtocol: Sendable {
    var name: String { get }
    var owner: String { get }
}

// Protocol defining the common interface for LLM services
public protocol LLMService: Sendable {
    func checkAvailability() async -> Bool
    func chatStream(messages: [ChatMessage], model: String, formatter: ChatMessage.OutputFormatter?)
        -> AsyncThrowingStream<ChatMessage, Error>
    func chat(
        messages: [ChatMessage], model: String, tools: [ChatMessage.Tool]?,
        formatter: ChatMessage.OutputFormatter?
    ) async throws -> ChatMessage
    func listModels() async throws -> [any ModelProtocol]
}

// Factory class to create the appropriate LLM service based on settings
@MainActor
public final class LLMServiceFactory: @unchecked Sendable {
    private static let settings = Settings.shared
    private static let logger = LoggerService.shared

    @MainActor
    public static func createService() -> any LLMService {
        switch settings.llmService.apiType {
        case .ollama:
            logger.log("Using Ollama service", level: .info)
            return OllamaService.shared
        case .openai:
            logger.log("Using OpenAI service", level: .info)
            return OpenaiService.shared
        }
    }

    public static func toolsToDict(_ myTools: [ChatMessage.Tool]) -> [[String: Any]] {
        myTools.map { tool in
            [
                "type": "function",
                "function": [
                    "name": tool.name,
                    "description": tool.description,
                    "parameters": [
                        "type": "object",
                        "properties": tool.parameters.reduce(into: [String: [String: String]]()) {
                            dict, parameter in
                            dict[parameter.name] = [
                                "type": parameter.type,
                                "description": parameter.description,
                            ]
                        },
                        "required": tool.parameters.map { $0.name },
                    ],
                ],
            ]
        }
    }

    /// Extract JSON objects from LLM response text.
    /// Tries markdown code blocks first, then falls back to parsing the full response.
    /// Also attempts to repair malformed JSON (e.g. unquoted keys, trailing commas).
    public static func extractJSONs(from text: String) -> [[String: Any]] {
        var results: [[String: Any]] = []

        // Strategy 1: look for JSON inside ```code blocks``` using cmark
        if let cText = text.cString(using: .utf8),
           let root = cmark_parse_document(cText, text.utf8.count, CMARK_OPT_DEFAULT) {
            defer { cmark_node_free(root) }

            let iter = cmark_iter_new(root)
            var eventType = cmark_iter_next(iter)

            while eventType != CMARK_EVENT_DONE {
                if let node = cmark_iter_get_node(iter),
                   cmark_node_get_type(node) == CMARK_NODE_CODE_BLOCK,
                   let literal = cmark_node_get_literal(node) {
                    let literalString = String(cString: literal)
                    if let json = tryParseJSON(literalString) {
                        results.append(json)
                    }
                }
                eventType = cmark_iter_next(iter)
            }
            cmark_iter_free(iter)
        }

        if results.isEmpty {
            if let json = tryParseJSON(text) {
                results.append(json)
            }
        }

        return results
    }

    /// Attempt to parse a string as JSON with multiple fallback strategies.
    private static func tryParseJSON(_ string: String) -> [String: Any]? {
        // Attempt 1: standard JSON parsing
        if let data = string.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) as? [String: Any] {
            return json
        }

        // Attempt 2: JSON5 (unquoted keys, trailing commas, etc.) — may require macOS 14+
        if let data = string.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed, .json5Allowed]) as? [String: Any] {
            return json
        }

        // Attempt 3: try to extract a { ... } region from within the text
        if let braceStart = string.firstIndex(of: "{"),
           let braceEnd = string.lastIndex(of: "}"),
           braceEnd > braceStart {
            let substring = string[braceStart...braceEnd]
            if let data = String(substring).data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) as? [String: Any] {
                return json
            }
            if let data = String(substring).data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed, .json5Allowed]) as? [String: Any] {
                return json
            }
        }

        return nil
    }
}
