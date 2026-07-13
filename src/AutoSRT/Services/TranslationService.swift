import Combine
import Foundation

public class TranslationService: ObservableObject {
    public static let shared = TranslationService()
    private let logger = LoggerService.shared

    private init() {}

    private func doTranslate(
        batch: [Subtitle],
        fromLanguage: String, toLanguage: String,
        model: String,
        progressCallback: @escaping (Double, String) -> Void,
    ) async throws -> [String: String] {
        if batch.isEmpty {
            throw NSError(domain: "No subtitles provided", code: 0, userInfo: nil)
        }

        let systemPrompt = """
            You are a professional video subtitle translator specializing in \(fromLanguage) to \(toLanguage) translation.
              1. Translate the following subtitles into natural, fluent \(toLanguage). Each translation should be concise, accurate, and contextually appropriate.
              2. Preserve the original meaning and subtitle structure as much as possible.
              3. Output ONLY a valid JSON object, no other text, no markdown.

            Response format:
            {"data": {"source text": "translated text", ...}}

            Example:
            {"data": {"Hello ": "您好 ", "let's start. ": "让我们开始吧。"}}
            """
        let systemMessage = ChatMessage(role: .system, content: systemPrompt)

        // convert batch to json string
        let sourceTextList = batch.map { $0.sourceText }
        let batchJson = try JSONEncoder().encode(sourceTextList)
        let batchJsonString = String(data: batchJson, encoding: .utf8) ?? ""

        let userPrompt = """
            Translate the following text list:

            ```json
            \(batchJsonString)
            ```
            """
        let userMessage = ChatMessage(role: .user, content: userPrompt)

        let messages: [ChatMessage] = [systemMessage, userMessage]

        let assistMessage = try await LLMServiceFactory.createService().chat(
            messages: messages, model: model, tools: nil, formatter: nil)

        // extract json, convert to array
        let jsonResults = await LLMServiceFactory.extractJSONs(from: assistMessage.content)
        guard let firstJson = jsonResults.first else {
            let snippet = String(assistMessage.content.prefix(200))
            logger.log(
                "Failed to parse any JSON from response. Snippet: \(snippet)", level: .warning)
            progressCallback(1.0, "JSON parse failed — retrying individually...")
            throw NSError(
                domain: "TranslationError", code: 0,
                userInfo: [NSLocalizedDescriptionKey: "Failed to parse JSON from LLM response."])
        }

        // Support both {"data": {...}} and flat {...} response formats
        let items: [String: String]
        if let dataDict = firstJson["data"] as? [String: String] {
            items = dataDict
        } else if let flat = firstJson as? [String: String] {
            items = flat
        } else {
            logger.log("JSON response has unexpected shape: \(firstJson)", level: .warning)
            progressCallback(1.0, "Unexpected JSON shape — retrying individually...")
            throw NSError(
                domain: "TranslationError", code: 0,
                userInfo: [NSLocalizedDescriptionKey: "Unexpected JSON response structure."])
        }
        // convert items to dict
        var translatedTexts: [String: String] = [:]
        for (source, translated) in items {
            let cleanSource = source.trimmingCharacters(in: .whitespacesAndNewlines)
            let cleanTranslated = translated.trimmingCharacters(in: .whitespacesAndNewlines)
            translatedTexts[cleanSource] = cleanTranslated
            progressCallback(
                1.0,
                "\(source) -> \(translated)"
            )
        }
        
        return translatedTexts
    }

    private func doTranslateOne(
        subtitle: Subtitle,
        batch: [Subtitle],
        fromLanguage: String, toLanguage: String,
        model: String
    ) async throws -> String {
        if batch.isEmpty {
            return ""
        }

        let systemPrompt = """
            You are a professional video subtitle translator specializing in \(fromLanguage) to \(toLanguage) translation.
              1. Translate the following subtitle into natural, fluent \(toLanguage). Each translation should be concise, accurate, and contextually appropriate.
              2. The subtitle is in the context.
              3. Preserve the original meaning and subtitle structure as much as possible.
              4. Output ONLY a valid JSON object, no other text, no markdown.

            Response format:
            {"translation": "translated text"}
            """
        let systemMessage = ChatMessage(role: .system, content: systemPrompt)

        // convert batch to json string
        let sourceTextList = batch.map { $0.sourceText }
        let batchJson = try JSONEncoder().encode(sourceTextList)
        let batchJsonString = String(data: batchJson, encoding: .utf8) ?? ""

        let userPrompt = """
            The subtitle of context is in the following json:
            ```json
            \(batchJsonString)
            ```
            
            Translate the following subtitle:
            \(subtitle.sourceText)

            """
        let userMessage = ChatMessage(role: .user, content: userPrompt)

        let messages: [ChatMessage] = [systemMessage, userMessage]

        let assistMessage = try await LLMServiceFactory.createService().chat(
            messages: messages, model: model, tools: nil, formatter: nil)

        // extract json, convert to array
        guard let jsonDict = await LLMServiceFactory.extractJSONs(from: assistMessage.content).first
        else {
            logger.log(
                "Failed to parse JSON response from: \(assistMessage.content)", level: .warning)
            return ""
        }
        guard let translation = jsonDict["translation"] as? String else {
            logger.log("Failed to extract translation from: \(jsonDict)", level: .warning)
            return ""
        }
        logger.log("Translate one subtitle: \(subtitle.sourceText) -> \(translation)")
        return translation
    }

    /// Translate subtitles using LLM.
    /// Batches are processed concurrently (up to 3 in parallel) for speed.
    /// Failed items are retried as a smaller batch instead of one-by-one.
    public func translateSubtitles(
        _ subtitles: [Subtitle], fromLanguage: String, toLanguage: String,
        model: String,
        progressCallback: @escaping (Double, String) -> Void
    ) async throws -> [Subtitle] {
        let total = subtitles.count
        var translatedTexts: [String: String] = [:]
        let start = Date().timeIntervalSince1970

        let batchSize = Settings.shared.llmService.translationBatchSize
        let batches = stride(from: 0, to: subtitles.count, by: batchSize).map {
            Array(subtitles[$0..<min($0 + batchSize, subtitles.count)])
        }
        let totalBatches = batches.count
        var completedCount = 0

        func reportProgress(_ message: String) {
            let elapsed = Date().timeIntervalSince1970 - start
            let speed = elapsed > 0 ? Double(completedCount) / elapsed : 0
            let left = speed > 0 ? Int(Double(total - completedCount) / speed) : 0
            progressCallback(
                Double(completedCount) / Double(total),
                "\(message) | \(completedCount)/\(total) subs, \(String(format: "%.1f", speed))/s, ETA \(left)s"
            )
        }

        // Phase 1: translate all batches concurrently (up to 3 at a time)
        try await withThrowingTaskGroup(of: (Int, [String: String]).self) { group in
            for (index, batch) in batches.enumerated() {
                group.addTask { [logger] in
                    do {
                        let result = try await self.doTranslate(
                            batch: batch,
                            fromLanguage: fromLanguage,
                            toLanguage: toLanguage,
                            model: model,
                            progressCallback: { _, _ in }
                        )
                        return (index, result)
                    } catch {
                        logger.log("Batch \(index + 1)/\(totalBatches) failed: \(error.localizedDescription)", level: .warning)
                        return (index, [:])
                    }
                }
            }

            for try await (batchIndex, result) in group {
                translatedTexts.merge(result) { (current, _) in current }
                let batchSize = batches[batchIndex].count
                completedCount += batchSize
                reportProgress("Batch \(batchIndex + 1)/\(totalBatches) done")
            }
        }

        // Phase 2: collect any subtitles still missing translations
        var missing: [Subtitle] = []
        var found: [Subtitle] = []
        for sub in subtitles {
            let key = sub.sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
            if let t = translatedTexts[key], !t.isEmpty {
                found.append(sub)
            } else {
                missing.append(sub)
            }
        }

        // Phase 3: retry missing items as a single batch (not one-by-one)
        if !missing.isEmpty {
            logger.log("Retrying \(missing.count) untranslated subtitles as a batch", level: .info)
            reportProgress("Retrying \(missing.count) missing...")
            do {
                let retryResult = try await self.doTranslate(
                    batch: missing,
                    fromLanguage: fromLanguage,
                    toLanguage: toLanguage,
                    model: model,
                    progressCallback: { _, _ in }
                )
                translatedTexts.merge(retryResult) { (current, _) in current }

                // Check which ones resolved
                var stillMissing: [Subtitle] = []
                for sub in missing {
                    let key = sub.sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
                    if let t = translatedTexts[key], !t.isEmpty {
                        found.append(sub)
                    } else {
                        stillMissing.append(sub)
                    }
                }
                missing = stillMissing
            } catch {
                logger.log("Retry batch also failed, will use source text as fallback", level: .warning)
            }
        }

        // Phase 4: any truly remaining subtitles get their source text as fallback
        for sub in missing {
            let key = sub.sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
            translatedTexts[key] = sub.sourceText
            found.append(sub)
        }

        // Build result preserving input order
        var result: [Subtitle] = []
        for sub in subtitles {
            let key = sub.sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
            let translation = translatedTexts[key] ?? sub.sourceText
            result.append(Subtitle(
                startTime: sub.startTime,
                endTime: sub.endTime,
                sourceText: sub.sourceText,
                translatedText: translation,
                index: sub.index
            ))
            completedCount += 1  // only used for progress display below
        }

        progressCallback(1.0, "Translation completed: \(result.count) subtitles")
        return result
    }

    /// Split text into multiple lines if characters exceed maxLength
    public func splitText(_ text: String, maxCharactersPerLine: Int = 40) -> String {
        if text.count <= maxCharactersPerLine {
            return text
        }

        // Split text into words/characters
        let components = text.map { String($0) }
        var lines: [String] = []
        var currentLine = ""

        for component in components {
            let newLine = currentLine + component
            if newLine.count > maxCharactersPerLine {
                lines.append(currentLine)
                currentLine = component
            } else {
                currentLine = newLine
            }
        }

        if !currentLine.isEmpty {
            lines.append(currentLine)
        }

        return lines.joined(separator: "\n")
    }
}
