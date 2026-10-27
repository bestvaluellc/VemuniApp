import SwiftUI
import FirebaseCore

@main
struct VemuniApp: App {
    @StateObject private var auth = AuthViewModel()
    @StateObject private var subscriptionStore = SubscriptionStore()

    init() {
        FirebaseApp.configure()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(auth)
                .environmentObject(subscriptionStore)
                .tint(VemuniTheme.copper)
        }
    }
}

private struct RootView: View {
    @EnvironmentObject private var auth: AuthViewModel
    @EnvironmentObject private var subscriptionStore: SubscriptionStore

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
        .task(id: auth.user?.uid) {
            if let userID = auth.user?.uid {
                await subscriptionStore.identify(firebaseUserID: userID)
            } else {
                await subscriptionStore.clearIdentity()
            }
        }
    }
}
