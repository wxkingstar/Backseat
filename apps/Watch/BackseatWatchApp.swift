import SwiftUI

@main
struct BackseatWatchApp: App {
    @Environment(\.scenePhase) private var phase
    @State private var store = Store.shared

    init() {
        // 手机配对好 Mac 后把配对信息传过来，手表直接用
        DeviceSync.shared.onAdopted = {
            MainActor.assumeIsolated {
                Pairing.shared.refresh()
                Store.shared.refreshNow()
            }
        }
        DeviceSync.shared.start()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(store)
        }
        .onChange(of: phase) { _, p in
            switch p {
            case .active: store.refreshNow()
            case .background:
                // 遥控模式下继续收消息；否则放下手腕就停，省电
                if !store.isKeepAliveRunning { store.stopPolling() }
            default: break
            }
        }
    }
}

struct RootView: View {
    @Environment(Store.self) private var store
    @State private var tab = 0

    var body: some View {
        if Pairing.shared.isPaired { main } else { PairView() }
    }

    private var main: some View {
        NavigationStack {
            TabView(selection: $tab) {
                TalkView().tag(0)
                QuickView().tag(1)
                ScrollPadView(isActive: tab == 2).tag(2)
                KeysView().tag(3)
            }
            .tabViewStyle(.verticalPage)
            // Action Button 触发说话时切回主页
            .onChange(of: store.talkToggle) { _, _ in tab = 0 }
        }
        .fullScreenCover(item: Binding(get: { store.pending.first }, set: { _ in })) { a in
            ApprovalView(approval: a)
        }
        .overlay(alignment: .bottom) {
            if let t = store.toast {
                Text(t)
                    .font(.footnote.weight(.medium))
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(.ultraThinMaterial, in: Capsule())
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .padding(.bottom, 4)
            }
        }
        .animation(.spring(duration: 0.3), value: store.toast)
        .onAppear { store.startPolling() }
    }
}
