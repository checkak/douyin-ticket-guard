import SwiftUI

@main
struct DouyinTicketGuardApp: App {
    @StateObject private var store = Store()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .onChange(of: scenePhase) { phase in
                    switch phase {
                    case .active:
                        store.engineEnterForeground()
                    case .background:
                        store.engineEnterBackground()
                    default:
                        break
                    }
                }
        }
    }
}

struct RootView: View {
    var body: some View {
        TabView {
            MonitorView()
                .tabItem { Label("监控", systemImage: "waveform.path.ecg") }
            ImportView()
                .tabItem { Label("导入", systemImage: "square.and.arrow.down") }
            SettingsView()
                .tabItem { Label("设置", systemImage: "gearshape") }
        }
    }
}
