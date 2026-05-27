import Foundation
import SwiftUI

/// 静态 key 的本地化 Text（在 SwiftUI 视图层用）
func T(_ key: LocalizedStringKey) -> Text {
    Text(key, bundle: .module)
}

/// 取 raw 本地化字符串（NSSavePanel.title 等非 SwiftUI 场景）
func L(_ key: String) -> String {
    NSLocalizedString(key, bundle: .module, comment: "")
}

/// 带 printf-style 变量的本地化字符串
func Lf(_ key: String, _ args: CVarArg...) -> String {
    String(format: NSLocalizedString(key, bundle: .module, comment: ""), arguments: args)
}
