import Foundation
import Combine
import FirebaseAuth
import FirebaseFunctions
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
    private var revenueCatIsPlus = false
    private var overrideIsPlus = false

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
        if isConfigured {
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
        await refreshPlusOverride()
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
        if identifiedUserID == firebaseUserID {
            await refresh()
            return
        }

        identifiedUserID = firebaseUserID
        if isConfigured {
            do {
                let result = try await Purchases.shared.logIn(firebaseUserID)
                apply(result.customerInfo)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
        await refresh()
    }

    func clearIdentity() async {
        guard identifiedUserID != nil else { return }
        if isConfigured {
            do {
                let info = try await Purchases.shared.logOut()
                apply(info)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
        identifiedUserID = nil
        overrideIsPlus = false
        updatePlusStatus()
    }

    nonisolated func purchases(_ purchases: Purchases, receivedUpdated customerInfo: CustomerInfo) {
        Task { @MainActor in self.apply(customerInfo) }
    }

    private func apply(_ info: CustomerInfo) {
        revenueCatIsPlus = info.entitlements[Self.entitlementID]?.isActive == true
        updatePlusStatus()
    }

    private func refreshPlusOverride() async {
        guard Auth.auth().currentUser != nil else {
            overrideIsPlus = false
            updatePlusStatus()
            return
        }
        do {
            let result = try await Functions.functions(region: "us-central1")
                .httpsCallable("getVemuniPlusStatus")
                .call()
            let data = result.data as? [String: Any]
            overrideIsPlus = data?["overrideEnabled"] as? Bool ?? false
            #if DEBUG
            print("Vemuni Plus override check", Auth.auth().currentUser?.uid ?? "no-user", overrideIsPlus)
            #endif
            updatePlusStatus()
        } catch {
            overrideIsPlus = false
            updatePlusStatus()
            errorMessage = "Plus access check failed: \(error.localizedDescription)"
        }
    }

    private func updatePlusStatus() {
        isPlus = revenueCatIsPlus || overrideIsPlus
    }

    private func packageOrder(_ package: Package) -> Int {
        switch package.packageType {
        case .annual: return 0
        case .monthly: return 1
        default: return 2
        }
    }
}
