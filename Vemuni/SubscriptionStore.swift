import Foundation
import Combine
import RevenueCat

enum SubscriptionPurchaseOutcome {
    case purchased
    case cancelled
    case failed
}

@MainActor
final class SubscriptionStore: NSObject, ObservableObject, PurchasesDelegate {
    static let entitlementID = "vemuni_plus"

    @Published private(set) var isPlus = false
    @Published private(set) var packages: [Package] = []
    @Published private(set) var isLoading = false
    @Published var errorMessage: String?

    private var isConfigured = false
    private var identifiedUserID: String?

    override init() {
        super.init()

        #if DEBUG
        let apiKey = "test_HTtrZULpXCEMbKjLyovZEfhOEeI"
        Purchases.logLevel = .debug
        #else
        let apiKey = Bundle.main.object(forInfoDictionaryKey: "REVENUECAT_API_KEY") as? String ?? ""
        Purchases.logLevel = .warn
        #endif

        guard !apiKey.isEmpty, !apiKey.contains("YOUR_") else {
            errorMessage = "RevenueCat’s public Apple SDK key has not been configured."
            return
        }

        Purchases.configure(withAPIKey: apiKey)
        Purchases.shared.delegate = self
        isConfigured = true
    }

    func refresh() async {
        guard isConfigured else { return }
        isLoading = true
        defer { isLoading = false }

        do {
            async let customerInfo = Purchases.shared.customerInfo()
            async let offerings = Purchases.shared.offerings()
            let (info, availableOfferings) = try await (customerInfo, offerings)
            apply(info)
            packages = availableOfferings.current?.availablePackages
                .filter { $0.packageType == .annual || $0.packageType == .monthly }
                .sorted { packageOrder($0) < packageOrder($1) } ?? []
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func purchase(_ package: Package) async -> SubscriptionPurchaseOutcome {
        guard isConfigured else { return .failed }
        isLoading = true
        defer { isLoading = false }

        do {
            let result = try await Purchases.shared.purchase(package: package)
            apply(result.customerInfo)
            return isPlus ? .purchased : .failed
        } catch {
            let error = error as NSError
            if error.code == ErrorCode.purchaseCancelledError.rawValue { return .cancelled }
            errorMessage = error.localizedDescription
            return .failed
        }
    }

    func restore() async -> Bool {
        guard isConfigured else { return false }
        isLoading = true
        defer { isLoading = false }

        do {
            let info = try await Purchases.shared.restorePurchases()
            apply(info)
            if !isPlus { errorMessage = "No active Vemuni Plus subscription was found." }
            return isPlus
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func identify(firebaseUserID: String) async {
        guard isConfigured else { return }
        if identifiedUserID == firebaseUserID {
            await refresh()
            return
        }

        do {
            let result = try await Purchases.shared.logIn(firebaseUserID)
            identifiedUserID = firebaseUserID
            apply(result.customerInfo)
            await refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func clearIdentity() async {
        guard isConfigured, identifiedUserID != nil else { return }
        do {
            let info = try await Purchases.shared.logOut()
            identifiedUserID = nil
            apply(info)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    nonisolated func purchases(_ purchases: Purchases, receivedUpdated customerInfo: CustomerInfo) {
        Task { @MainActor in self.apply(customerInfo) }
    }

    private func apply(_ info: CustomerInfo) {
        isPlus = info.entitlements[Self.entitlementID]?.isActive == true
    }

    private func packageOrder(_ package: Package) -> Int {
        switch package.packageType {
        case .annual: return 0
        case .monthly: return 1
        default: return 2
        }
    }
}
