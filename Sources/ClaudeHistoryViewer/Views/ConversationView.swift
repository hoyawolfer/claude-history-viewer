import SwiftUI

struct ConversationView: View {
    let messages: [Message]
    let isLoading: Bool
    @Binding var pendingScrollMessageId: String?

    var body: some View {
        Group {
            if isLoading {
                ProgressView { T("conversation.loading") }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if messages.isEmpty {
                ContentUnavailableView {
                    Label { T("conversation.empty.title") } icon: { Image(systemName: "bubble.left.and.bubble.right") }
                } description: {
                    T("conversation.empty.message")
                }
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            ForEach(messages) { msg in
                                MessageView(message: msg)
                                    .id(msg.id)
                                    .background(
                                        // 跳转目标短暂高亮
                                        highlightBackground(for: msg.id)
                                    )
                            }
                        }
                        .padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .background(Color(NSColor.windowBackgroundColor))
                    .onChange(of: pendingScrollMessageId) { _, newValue in
                        guard let target = newValue else { return }
                        withAnimation { proxy.scrollTo(target, anchor: .top) }
                        // 1.2s 后清掉高亮标记
                        Task { @MainActor in
                            try? await Task.sleep(for: .milliseconds(1200))
                            if pendingScrollMessageId == target {
                                pendingScrollMessageId = nil
                            }
                        }
                    }
                    .onChange(of: messages.count) { _, _ in
                        // 新加载完一个会话时，如果有 pending 跳转 id，scrollTo 一下
                        if let target = pendingScrollMessageId,
                           messages.contains(where: { $0.id == target }) {
                            withAnimation { proxy.scrollTo(target, anchor: .top) }
                        }
                    }
                }
            }
        }
        .navigationTitle(T("nav.conversation"))
    }

    @ViewBuilder
    private func highlightBackground(for id: String) -> some View {
        if pendingScrollMessageId == id {
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.yellow.opacity(0.18))
                .padding(-4)
        } else {
            EmptyView()
        }
    }
}
