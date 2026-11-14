import SwiftUI

struct FeedView: View {
    @Environment(Store.self) private var store

    var body: some View {
        List {
            if store.feed.isEmpty {
                Text("还没有动态").foregroundStyle(.secondary)
            }
            ForEach(store.feed) { item in
                NavigationLink {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(item.title).font(.headline)
                            Text("\(item.project) · \(item.ts.formatted(date: .omitted, time: .shortened))")
                                .font(.caption2).foregroundStyle(.secondary)
                            Text(item.body).font(.caption)
                        }
                    }
                } label: {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: Self.icon(item.kind)).foregroundStyle(Self.color(item.kind))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.title).font(.footnote.weight(.semibold))
                            Text(item.body).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                            Text(item.ts, style: .relative).font(.caption2).foregroundStyle(.tertiary)
                        }
                    }
                }
            }
        }
        .navigationTitle("动态")
    }

    static func icon(_ kind: String) -> String {
        ["done": "checkmark.circle.fill", "idle": "ellipsis.bubble.fill", "approval": "hand.raised.fill",
         "resolved": "checkmark.shield", "info": "bell.fill"][kind] ?? "circle"
    }

    static func color(_ kind: String) -> Color {
        ["done": .green, "idle": .yellow, "approval": .orange, "resolved": .gray, "info": .blue][kind] ?? .gray
    }
}
