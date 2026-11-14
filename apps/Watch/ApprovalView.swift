import SwiftUI

struct ApprovalView: View {
    @Environment(Store.self) private var store
    let approval: Approval

    private var icon: String {
        switch approval.tool {
        case "Bash": return "terminal.fill"
        case "Edit", "MultiEdit", "Write", "NotebookEdit": return "pencil"
        case "WebFetch", "WebSearch": return "globe"
        default: return "wrench.and.screwdriver.fill"
        }
    }

    private var tint: Color { approval.isRisky ? Theme.danger : Theme.accent }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                header

                Text(approval.detail)
                    .font(.system(.caption, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.surface))

                if approval.isRisky {
                    Label("高风险，请点按确认", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Theme.danger)
                }

                HStack(spacing: 8) {
                    Button { store.decide(approval, "deny") } label: { Image(systemName: "xmark") }
                        .buttonStyle(KeyStyle(fill: Theme.danger.opacity(0.25), foreground: Theme.danger, height: 44))
                        .frame(width: 56)
                        .accessibilityLabel("拒绝")
                    allowButton
                }

                Button { store.decide(approval, "terminal") } label: {
                    Text("在电脑上处理")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 6)
        }
        .toolbar(.hidden, for: .navigationBar)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(Circle().fill(tint))
            VStack(alignment: .leading, spacing: 1) {
                Text(approval.title).font(.headline).lineLimit(1)
                Text(approval.project).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if store.pending.count > 1 {
                Text("+\(store.pending.count - 1)")
                    .font(.caption2.weight(.bold))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(Theme.surface))
            }
        }
    }

    @ViewBuilder private var allowButton: some View {
        let b = Button { store.decide(approval, "allow") } label: {
            Label("允许", systemImage: "checkmark")
        }
        .buttonStyle(KeyStyle(fill: approval.isRisky ? Theme.danger : Theme.ok, height: 44))

        if approval.isRisky {
            b
        } else {
            b.handGestureShortcut(.primaryAction)
        }
    }
}
