import Foundation

enum ScanMode: String, Codable, CaseIterable, Identifiable {
    case menu
    case receipt

    var id: String { rawValue }
    var title: String { self == .menu ? "Scan Menu" : "Check Bill" }
    var subtitle: String {
        self == .menu
            ? "Translate and explain every dish"
            : "Spot fees and calculate the tip"
    }
    var symbol: String { self == .menu ? "text.viewfinder" : "receipt" }
}

struct VemuniScanResult: Codable, Equatable {
    let kind: String
    let detectedLanguage: String
    let notice: String
    let restaurantName: String?
    let currencyCode: String
    let menuSections: [MenuSection]
    let receipt: ReceiptAnalysis?
    let warnings: [String]
}

struct MenuSection: Codable, Equatable, Identifiable {
    let name: String
    let items: [MenuItem]
    var id: String { name }
}

struct MenuItem: Codable, Equatable, Identifiable {
    let originalName: String
    let englishName: String
    let explanation: String
    let price: String?
    let dietary: [String]
    let allergens: [String]
    let spiceLevel: String?
    var id: String { "\(originalName)-\(price ?? "")" }
}

struct ReceiptAnalysis: Codable, Equatable {
    let subtotal: Double?
    let tax: Double?
    let serviceCharge: Double?
    let serviceChargeLabel: String?
    let statedTip: Double?
    let total: Double?
    let tipBase: Double?
    let tipAlreadyIncluded: Bool
    let possibleDuplicateTipRisk: Bool
    let lineItems: [ReceiptLineItem]
}

struct ReceiptLineItem: Codable, Equatable, Identifiable {
    let name: String
    let amount: Double
    var id: String { "\(name)-\(amount)" }
}

extension ReceiptAnalysis {
    func tipAmount(percent: Int) -> Double? {
        guard let tipBase else { return nil }
        return tipBase * Double(percent) / 100
    }

    func totalWithTip(percent: Int) -> Double? {
        guard let total, let tip = tipAmount(percent: percent) else { return nil }
        return tipAlreadyIncluded ? total : total + tip
    }
}
