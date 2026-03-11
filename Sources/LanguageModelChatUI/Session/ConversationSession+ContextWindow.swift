//
//  ConversationSession+ContextWindow.swift
//  LanguageModelChatUI
//
//  Sliding context window helpers.
//

import Foundation

extension ConversationSession {
    static let contextWindowMarkerKey = "context_window_start"

    func contextWindowMessages() -> [ConversationMessage] {
        guard let startIndex = messages.lastIndex(where: { message in
            message.metadata[Self.contextWindowMarkerKey] == "true"
        }) else {
            return messages
        }
        let nextIndex = messages.index(after: startIndex)
        return nextIndex < messages.endIndex ? Array(messages[nextIndex...]) : []
    }

    func insertContextWindowMarker() {
        _ = appendNewMessage(role: .system) { msg in
            msg.metadata[Self.contextWindowMarkerKey] = "true"
        }
    }

    func startContextWindow() {
        insertContextWindowMarker()
        persistMessages()
    }
}
