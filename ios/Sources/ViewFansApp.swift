import SwiftUI

@main
struct ViewFansApp: App {
    @Environment(\.scenePhase) private var phase
    @State private var lock = AppLock.shared
    @State private var configured = API.shared.isConfigured

    var body: some Scene {
        WindowGroup {
            ZStack {
                if configured {
                    RootView()
                } else {
                    NavigationStack {
                        ConnectionSettingsView(isFirstRun: true) {
                            configured = API.shared.isConfigured
                        }
                    }
                }
                if configured && lock.locked {
                    LockScreen()
                }
                // アプリスイッチャーや通知センター表示中は中身を隠す
                if phase != .active {
                    Color.black.ignoresSafeArea()
                        .overlay(Text("View Fans").font(.title2).foregroundStyle(.secondary))
                }
            }
            .preferredColorScheme(.dark)
            .task { await ImageStore.shared.trim() }
            .onChange(of: phase) { _, p in
                if p == .background { lock.didEnterBackground() }
                if p == .active { lock.didBecomeActive() }
            }
        }
    }
}

struct RootView: View {
    @State private var path = NavigationPath()

    var body: some View {
        NavigationStack(path: $path) {
            FolderScreen(folder: nil)
                .navigationDestination(for: Folder.self) { FolderScreen(folder: $0) }
                .navigationDestination(for: TrashRoute.self) { _ in TrashScreen() }
        }
    }
}
