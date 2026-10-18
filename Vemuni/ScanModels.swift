import Foundation

enum ScanMode: String, Codable, CaseIterable, Identifiable {
    case menu
    case receipt

    var id: String { rawValue }
    var title: String { self == .menu ? "Scan Menu" : "Check Bill" }
    var subtitle: String {
        self == .menu
            ? "Explain food, wine, and drinks"
            : "Spot fees and calculate the tip"
    }
    var symbol: String { self == .menu ? "text.viewfinder" : "receipt" }
}

struct VemuniScanResult: Codable, Equatable {
    let kind: String
    let menuType: String?
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
    let sectionType: String?
    let items: [MenuItem]
    var id: String { name }
}

struct MenuItem: Codable, Equatable, Identifiable {
    let originalName: String
    let englishName: String
    let explanation: String
    let price: String?
    let itemType: String?
    let dietary: [String]
    let allergens: [String]
    let spiceLevel: String?
    let wineDetails: WineDetails?
    let drinkDetails: DrinkDetails?
    var id: String { "\(originalName)-\(price ?? "")" }

    var numericPrice: Double? {
        guard let price, !price.isEmpty else { return nil }
        let normalized = price.replacingOccurrences(of: ",", with: ".")
        guard let range = normalized.range(of: #"\d+(?:\.\d{1,2})?"#, options: .regularExpression) else {
            return nil
        }
        return Double(normalized[range])
    }
}

struct WineDetails: Codable, Equatable {
    let producer: String?
    let grape: String?
    let region: String?
    let country: String?
    let vintage: String?
    let style: String?
    let glassPrice: String?
    let bottlePrice: String?
    let body: String?
    let acidity: String?
    let tannin: String?
    let sweetness: String?
    let alcohol: String?
    let flavors: [String]
    let foodPairings: [String]
    let servingSuggestion: String?
    let profileIsTypical: Bool
}

struct DrinkDetails: Codable, Equatable {
    let drinkType: String?
    let baseSpirit: String?
    let ingredients: [String]
    let flavorProfile: [String]
    let abv: String?
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
