import SwiftUI
import FirebaseCore

@main
struct VemuniApp: App {
    @StateObject private var auth = AuthViewModel()

    init() {
        FirebaseApp.configure()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(auth)
                .tint(VemuniTheme.copper)
        }
    }
}

private struct RootView: View {
    @EnvironmentObject private var auth: AuthViewModel

    var body: some View {
        Group {
            if auth.isCheckingSession {
                ZStack {
                    VemuniTheme.cream.ignoresSafeArea()
                    ProgressView().tint(VemuniTheme.copper)
                }
            } else if auth.user == nil {
                AuthView()
            } else {
                HomeView()
            }
        }
    }
}
