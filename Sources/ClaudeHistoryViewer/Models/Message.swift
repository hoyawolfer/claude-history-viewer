import Foundation

enum MessageKind: Hashable {
    case userText(String)
    case assistantText(String)
    case assistantThinking(String)
    case toolUse(name: String, input: String, id: String?)
    case toolResult(toolUseId: String?, content: String, isError: Bool)
}

struct Message: Identifiable, Hashable {
    let id: String          // 在 session 内唯一
    let kind: MessageKind
    let timestamp: Date?
}
