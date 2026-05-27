import Foundation

enum ProjectScanner {
    static let projectsDir = URL(
        fileURLWithPath: NSString(string: "~/.claude/projects").expandingTildeInPath,
        isDirectory: true
    )

    static func scan() -> [Project] {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(
            at: projectsDir,
            includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        return contents.compactMap { url -> Project? in
            guard let vals = try? url.resourceValues(forKeys: [.isDirectoryKey, .contentModificationDateKey]),
                  vals.isDirectory == true else { return nil }
            let encoded = url.lastPathComponent
            return Project(
                id: encoded,
                displayName: decode(encoded),
                url: url,
                lastModified: vals.contentModificationDate ?? .distantPast
            )
        }
        .sorted { $0.lastModified > $1.lastModified }
    }

    // 编码是不可逆的（无法区分原路径里的 "/" 和 "-"），这里只做最直接的还原供展示。
    static func decode(_ encoded: String) -> String {
        guard encoded.hasPrefix("-") else { return encoded }
        return "/" + encoded.dropFirst().replacingOccurrences(of: "-", with: "/")
    }
}
