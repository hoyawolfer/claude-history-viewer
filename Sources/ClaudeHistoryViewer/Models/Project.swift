import Foundation

struct Project: Identifiable, Hashable {
    let id: String          // 目录名（编码后的）
    let displayName: String // 尽力还原的真实路径
    let url: URL
    let lastModified: Date
}
