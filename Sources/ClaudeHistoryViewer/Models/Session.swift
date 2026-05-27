import Foundation

struct Session: Identifiable, Hashable {
    let id: String          // jsonl 文件名（uuid）
    let url: URL
    let projectId: String
    let title: String       // 首条用户消息
    let messageCount: Int   // 用户消息数（粗略代表会话规模）
    let startTime: Date?
    let lastModified: Date
    let cwd: String?        // 来自 JSONL 的 cwd 字段；DB 缓存命中时填上
    var isFavorite: Bool    // 用户标星
    var tags: [String]      // 用户标签
}
