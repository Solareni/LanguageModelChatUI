//
//  ConversationSession+ContextCompression.swift
//  LanguageModelChatUI
//
//  Sliding context window compression into memory.
//

import ChatClientKit
import Foundation
import OSLog

private let compressionLogger = Logger(subsystem: "LanguageModelChatUI", category: "ContextCompression")

extension ConversationSession {
    func maybeCompressContextIfNeeded(
        model: ConversationSession.Model,
        tools: [ChatRequestBody.Tool]?,
        capabilities: Set<ModelCapability>
    ) async {
        guard let compression = contextCompression else { return }
        guard model.contextLength > 0 else { return }
        guard !isCompressingContext else { return }

        let windowMessages = contextWindowMessages()
        guard !windowMessages.isEmpty else { return }

        var requestMessages = windowMessages.flatMap { buildRequestMessages(from: $0, capabilities: capabilities) }
        await injectSystemPrompt(&requestMessages, capabilities: capabilities)

        let estimatedTokens = await estimatedTokenCountForRequest(messages: requestMessages, tools: tools)
        let threshold = Int(Double(model.contextLength) * compression.triggerRatio)
        guard estimatedTokens > threshold else { return }

        isCompressingContext = true
        defer { isCompressingContext = false }

        let summary = await summarizeContext(
            messages: windowMessages,
            model: model,
            maxFacts: compression.maxSummaryFacts
        )
        let facts = parseSummaryFacts(summary, maxFacts: compression.maxSummaryFacts)

        if facts.isEmpty {
            compressionLogger.warning("context compression produced no facts")
        } else {
            for fact in facts {
                await compression.onFact(fact)
            }
        }

        insertContextWindowMarker()
        persistMessages()
        notifyMessagesDidChange(scrolling: false)
    }

    private func summarizeContext(
        messages: [ConversationMessage],
        model: ConversationSession.Model,
        maxFacts: Int
    ) async -> String {
        let transcript = buildSummaryTranscript(messages)
        guard !transcript.isEmpty else { return "" }

        let prompt = """
你是对话记忆压缩器。请从对话中提取值得长期记忆的事实（用户偏好、身份信息、长期目标、进行中的长期任务）。
不要记录情绪、临时状态、工具调用细节或短期安排。
输出不超过 \(maxFacts) 条，每行以 \"- \" 开头的简短事实陈述。
只输出列表，不要解释。
"""

        do {
            let response = try await model.client.chat(body: .init(messages: [
                .system(content: .text(prompt)),
                .user(content: .text(transcript)),
            ]))
            return response.text.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            compressionLogger.error("context compression failed: \(error.localizedDescription)")
            return ""
        }
    }

    private func buildSummaryTranscript(_ messages: [ConversationMessage]) -> String {
        let lines = messages.compactMap { message -> String? in
            let text = message.textContent.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            switch message.role {
            case .user:
                return "用户: \(text)"
            case .assistant:
                return "助手: \(text)"
            case .system:
                return nil
            default:
                return "\(message.role.rawValue): \(text)"
            }
        }
        return lines.joined(separator: "\n")
    }

    private func parseSummaryFacts(_ summary: String, maxFacts: Int) -> [String] {
        let lines = summary.split(whereSeparator: \.isNewline).compactMap { rawLine -> String? in
            var line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { return nil }
            if line.hasPrefix("-") {
                line.removeFirst()
            } else if line.hasPrefix("•") {
                line.removeFirst()
            }
            line = line.trimmingCharacters(in: .whitespacesAndNewlines)
            return line.isEmpty ? nil : line
        }

        if lines.isEmpty {
            let trimmed = summary.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? [] : [trimmed]
        }

        return Array(lines.prefix(maxFacts))
    }
}
