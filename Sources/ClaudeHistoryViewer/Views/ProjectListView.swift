import SwiftUI

struct ProjectListView: View {
    let projects: [Project]
    @Binding var selection: String?

    var body: some View {
        List(projects, selection: $selection) { p in
            VStack(alignment: .leading, spacing: 2) {
                Text(leafName(p.displayName))
                    .font(.body)
                    .lineLimit(1)
                Text(p.displayName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            .padding(.vertical, 2)
            .tag(p.id)
        }
        .navigationTitle(T("nav.projects"))
        .overlay {
            if projects.isEmpty {
                ContentUnavailableView {
                    Label { T("project.empty.title") } icon: { Image(systemName: "folder") }
                } description: {
                    T("project.empty.message")
                }
            }
        }
    }

    private func leafName(_ path: String) -> String {
        path.split(separator: "/").last.map(String.init) ?? path
    }
}
