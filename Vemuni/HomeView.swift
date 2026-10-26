import SwiftUI

struct HomeView: View {
    @EnvironmentObject private var auth: AuthViewModel
    @State private var activeMode: ScanMode?
    @AppStorage("vemuni.scanCount") private var scanCount = 0
    @AppStorage("vemuni.lastFreeScanDay") private var lastFreeScanDay = ""

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
        }
    }

    private func actionCard(for mode: ScanMode, prominent: Bool) -> some View {
        Button {
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
        if scanCount < 10 { return "\(10 - scanCount) free introductory scans remaining" }
        return canUseDailyScan ? "Your free daily scan is ready" : "Come back tomorrow for another free scan"
    }

    private var canUseDailyScan: Bool {
        lastFreeScanDay != Self.dayKey(Date())
    }

    private func markScanUsed() {
        if scanCount < 10 { scanCount += 1 }
        else { lastFreeScanDay = Self.dayKey(Date()) }
    }

    private static func dayKey(_ date: Date) -> String {
        date.formatted(.iso8601.year().month().day())
    }
}
