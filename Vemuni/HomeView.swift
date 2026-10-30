import SwiftUI

struct HomeView: View {
    @EnvironmentObject private var auth: AuthViewModel
    @EnvironmentObject private var subscriptionStore: SubscriptionStore
    @State private var activeMode: ScanMode?
    @State private var showingPaywall = false
    @AppStorage("vemuni.scanCount") private var scanCount = 0

    var body: some View {
        NavigationStack {
            ZStack {
                VemuniTheme.cream.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 26) {
                        HStack {
                            Spacer()
                            VemuniWordmark()
                            Spacer()
                            Menu {
                                if auth.user?.isAnonymous == true {
                                    Text("Guest")
                                } else if let email = auth.user?.email {
                                    Text(email)
                                }
                                Button("Vemuni Plus") { showingPaywall = true }
                                Button("Sign Out", role: .destructive) { auth.signOut() }
                            } label: {
                                Image(systemName: "person.crop.circle")
                                    .font(.title2)
                                    .foregroundStyle(VemuniTheme.espresso)
                            }
                        }
                        .padding(.top, 22)

                        VStack(spacing: 6) {
                            Text("Scan the menu. Check the bill.")
                                .font(.title2.weight(.semibold))
                                .foregroundStyle(VemuniTheme.espresso)
                            Text("Make dining easier to read and understand.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)

                        actionCard(for: .menu, prominent: true)
                        actionCard(for: .receipt, prominent: false)

                        NavigationLink {
                            SavedScansView()
                        } label: {
                            HStack(spacing: 14) {
                                Image(systemName: "clock.arrow.circlepath")
                                    .font(.title3.weight(.semibold))
                                    .frame(width: 42, height: 42)
                                    .background(VemuniTheme.cream)
                                    .clipShape(RoundedRectangle(cornerRadius: 12))
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("Saved Scans")
                                        .font(.headline)
                                    Text("View your menus and bills")
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .foregroundStyle(.tertiary)
                            }
                            .padding(16)
                            .foregroundStyle(VemuniTheme.espresso)
                            .background(VemuniTheme.paper)
                            .clipShape(RoundedRectangle(cornerRadius: 20))
                        }
                        .buttonStyle(.plain)

                        HStack(spacing: 9) {
                            Image(systemName: "globe.americas.fill")
                                .foregroundStyle(VemuniTheme.copper)
                            Text("Automatically detects food, wine, drinks, and supported languages")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 6)

                        Text(freeScanMessage)
                            .font(.footnote.weight(.medium))
                            .foregroundStyle(VemuniTheme.sage)
                            .frame(maxWidth: .infinity)
                    }
                    .padding(20)
                }
            }
            .navigationBarHidden(true)
            .sheet(item: $activeMode) { mode in
                ScanView(mode: mode) {
                    markScanUsed()
                }
            }
            .sheet(isPresented: $showingPaywall) {
                PaywallView()
            }
            .task {
                await subscriptionStore.refresh()
            }
            .onChange(of: subscriptionStore.isPlus) { _, isPlus in
                if isPlus { showingPaywall = false }
            }
        }
    }

    private func actionCard(for mode: ScanMode, prominent: Bool) -> some View {
        Button {
            guard scanCount < 5 || subscriptionStore.isPlus else {
                showingPaywall = true
                return
            }
            VemuniAnalytics.scanOpened(mode: mode)
            activeMode = mode
        } label: {
            HStack(spacing: 18) {
                Image(systemName: mode.symbol)
                    .font(.system(size: 28, weight: .semibold))
                    .frame(width: 52, height: 52)
                    .background(prominent ? Color.white.opacity(0.16) : VemuniTheme.cream)
                    .clipShape(RoundedRectangle(cornerRadius: 15))
                VStack(alignment: .leading, spacing: 4) {
                    Text(mode.title).font(.title3.weight(.bold))
                    Text(mode.subtitle).font(.subheadline).opacity(0.78)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.headline)
            }
            .padding(20)
            .foregroundStyle(prominent ? Color.white : VemuniTheme.espresso)
            .background(prominent ? VemuniTheme.primaryAction : VemuniTheme.paper)
            .clipShape(RoundedRectangle(cornerRadius: 24))
            .shadow(color: .black.opacity(0.07), radius: 14, y: 6)
        }
        .buttonStyle(.plain)
    }

    private var freeScanMessage: String {
        if subscriptionStore.isPlus { return "Vemuni Plus · 30 scans per month" }
        if scanCount < 5 {
            let remaining = 5 - scanCount
            return "\(remaining) free \(remaining == 1 ? "scan" : "scans") remaining"
        }
        return "Upgrade to Vemuni Plus for more scans"
    }

    private func markScanUsed() {
        if scanCount < 5 { scanCount += 1 }
    }
}
