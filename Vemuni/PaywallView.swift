import SwiftUI
import RevenueCat

struct PaywallView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var subscriptionStore: SubscriptionStore
    @State private var selectedPackageID: String?

    private var selectedPackage: Package? {
        subscriptionStore.packages.first { $0.identifier == selectedPackageID }
            ?? subscriptionStore.packages.first
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    hero
                    benefits
                    if subscriptionStore.isLoading && subscriptionStore.packages.isEmpty {
                        ProgressView("Loading plans…")
                            .tint(VemuniTheme.copper)
                            .frame(minHeight: 150)
                    } else if subscriptionStore.packages.isEmpty {
                        unavailablePlans
                    } else {
                        plans
                        subscribeButton
                        purchaseDetails
                    }
                    footer
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 28)
            }
            .background(VemuniTheme.cream.ignoresSafeArea())
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(VemuniTheme.espresso)
                            .frame(width: 34, height: 34)
                            .background(VemuniTheme.paper)
                            .clipShape(Circle())
                    }
                    .accessibilityLabel("Close")
                }
            }
            .task {
                await subscriptionStore.refresh()
                selectPreferredPackage()
            }
            .onChange(of: subscriptionStore.packages.map(\.identifier)) { _, _ in
                selectPreferredPackage()
            }
            .alert("Unable to Complete Purchase", isPresented: errorIsPresented) {
                Button("OK", role: .cancel) { subscriptionStore.errorMessage = nil }
            } message: {
                Text(subscriptionStore.errorMessage ?? "Please try again.")
            }
        }
    }

    private var errorIsPresented: Binding<Bool> {
        Binding(
            get: { subscriptionStore.errorMessage != nil },
            set: { if !$0 { subscriptionStore.errorMessage = nil } }
        )
    }

    private var hero: some View {
        VStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(VemuniTheme.copper.opacity(0.14))
                    .frame(width: 76, height: 76)
                Image(systemName: "sparkles")
                    .font(.system(size: 32, weight: .semibold))
                    .foregroundStyle(VemuniTheme.copper)
            }
            Text("Dine with confidence")
                .font(.system(.largeTitle, design: .serif, weight: .bold))
                .foregroundStyle(VemuniTheme.espresso)
                .multilineTextAlignment(.center)
            Text("Upgrade to Vemuni Plus for more menu and bill scans.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
    }

    private var benefits: some View {
        VStack(spacing: 0) {
            benefit("doc.on.doc.fill", "Read up to 6 menu pages at once")
            Divider().padding(.leading, 48)
            benefit("character.book.closed.fill", "Translate and explain food, wine, and drinks")
            Divider().padding(.leading, 48)
            benefit("receipt.fill", "Check bills for fees and possible double tipping")
            Divider().padding(.leading, 48)
            benefit("clock.arrow.circlepath", "Keep your scans and menu picks together")
        }
        .padding(.horizontal, 16)
        .background(VemuniTheme.paper)
        .clipShape(RoundedRectangle(cornerRadius: 22))
    }

    private func benefit(_ symbol: String, _ title: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: symbol)
                .foregroundStyle(VemuniTheme.copper)
                .frame(width: 28)
            Text(title)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(VemuniTheme.espresso)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 14)
    }

    private var plans: some View {
        VStack(spacing: 12) {
            ForEach(subscriptionStore.packages, id: \.identifier) { package in
                planCard(package)
            }
        }
    }

    private func planCard(_ package: Package) -> some View {
        let isSelected = selectedPackage?.identifier == package.identifier
        return Button {
            withAnimation(.easeInOut(duration: 0.15)) { selectedPackageID = package.identifier }
        } label: {
            HStack(spacing: 14) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title2)
                    .foregroundStyle(isSelected ? VemuniTheme.copper : Color.secondary)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(title(for: package))
                            .font(.headline)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                            .layoutPriority(1)
                        if package.packageType == .annual {
                            Text("BEST VALUE")
                                .font(.caption2.bold())
                                .lineLimit(1)
                                .fixedSize(horizontal: true, vertical: false)
                                .foregroundStyle(VemuniTheme.onCopper)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(VemuniTheme.copper)
                                .clipShape(Capsule())
                        }
                    }
                    Text(periodDescription(for: package))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(package.storeProduct.localizedPriceString)
                    .font(.headline)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .padding(16)
            .foregroundStyle(VemuniTheme.espresso)
            .background(VemuniTheme.paper)
            .overlay {
                RoundedRectangle(cornerRadius: 18)
                    .stroke(isSelected ? VemuniTheme.copper : Color.secondary.opacity(0.2), lineWidth: isSelected ? 2 : 1)
            }
            .clipShape(RoundedRectangle(cornerRadius: 18))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var subscribeButton: some View {
        Button {
            guard let selectedPackage else { return }
            Task {
                if await subscriptionStore.purchase(selectedPackage) == .purchased { dismiss() }
            }
        } label: {
            Group {
                if subscriptionStore.isLoading {
                    ProgressView().tint(VemuniTheme.onCopper)
                } else if let selectedPackage {
                    Text("Continue for \(selectedPackage.storeProduct.localizedPriceString)")
                }
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(VemuniPrimaryButtonStyle())
        .disabled(selectedPackage == nil || subscriptionStore.isLoading)
    }

    private var purchaseDetails: some View {
        Text("Includes up to 30 scans per month. Each scan can contain up to 6 pages. Payment is charged to your Apple Account. Subscription renews automatically unless canceled at least 24 hours before the end of the current period.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var unavailablePlans: some View {
        VStack(spacing: 10) {
            Text("Plans are temporarily unavailable.").font(.headline)
            Text("Check your connection and try again.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Button("Try Again") { Task { await subscriptionStore.refresh() } }
                .font(.subheadline.weight(.semibold))
        }
        .frame(maxWidth: .infinity)
        .padding(20)
        .background(VemuniTheme.paper)
        .clipShape(RoundedRectangle(cornerRadius: 18))
    }

    private var footer: some View {
        VStack(spacing: 14) {
            Button("Restore Purchases") {
                Task { if await subscriptionStore.restore() { dismiss() } }
            }
            .font(.subheadline.weight(.semibold))
            .disabled(subscriptionStore.isLoading)
            HStack(spacing: 18) {
                Link("Privacy Policy", destination: URL(string: "https://vemuni.bestvaluellc.com/privacy/")!)
                Link("Terms of Use", destination: URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!)
            }
            .font(.caption)
        }
        .foregroundStyle(VemuniTheme.copper)
    }

    private func selectPreferredPackage() {
        guard selectedPackageID == nil || selectedPackage == nil else { return }
        selectedPackageID = subscriptionStore.packages.first(where: { $0.packageType == .annual })?.identifier
            ?? subscriptionStore.packages.first?.identifier
    }

    private func title(for package: Package) -> String {
        switch package.packageType {
        case .annual: return "Annual"
        case .monthly: return "Monthly"
        default: return package.storeProduct.localizedTitle
        }
    }

    private func periodDescription(for package: Package) -> String {
        switch package.packageType {
        case .annual: return "Billed yearly"
        case .monthly: return "Billed monthly"
        default: return package.storeProduct.localizedDescription
        }
    }
}

#Preview {
    PaywallView()
        .environmentObject(SubscriptionStore())
}
