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
    let aiUsage: AIUsage?
}

struct AIUsage: Codable, Equatable {
    let model: String
    let inputTokens: Int
    let cachedInputTokens: Int
    let outputTokens: Int
    let reasoningTokens: Int
    let totalTokens: Int
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

    var hasDistinctEnglishName: Bool {
        let original = originalName.vemuniTitleNormalized
        let english = englishName.vemuniTitleNormalized
        guard !english.isEmpty, original != english else { return false }
        if original.replacingOccurrences(of: " ", with: "") == english.replacingOccurrences(of: " ", with: "") {
            return false
        }
        let originalWords = original.vemuniTitleContentWords
        let englishWords = english.vemuniTitleContentWords
        guard !originalWords.isEmpty, !englishWords.isEmpty else { return true }
        guard originalWords != englishWords else { return false }
        let genericDescriptors: Set<String> = [
            "appetizer", "cocktail", "dessert", "dish", "drink", "entree", "salad", "sandwich", "soup", "wine"
        ]
        let addedWords = englishWords.subtracting(originalWords)
        if originalWords.isSubset(of: englishWords), addedWords.isSubset(of: genericDescriptors) {
            return false
        }
        return true
    }

    var numericPrice: Double? {
        guard !hasVariablePrice, priceNumbers.count == 1 else { return nil }
        return priceNumbers.first
    }

    var filterPrice: Double? {
        guard !hasVariablePrice else { return nil }
        return priceNumbers.min()
    }

    var displayPrice: String? {
        guard let price, !price.isEmpty else { return nil }
        return price.replacingOccurrences(
            of: #"(?i)(\d+(?:[.,]\d{1,2})?)\s*(oz|ounce|ounces|lb|lbs|pound|pounds)\b"#,
            with: "$1/$2",
            options: .regularExpression
        )
    }

    private var priceNumbers: [Double] {
        guard let price, !price.isEmpty else { return [] }
        let normalized = price.replacingOccurrences(of: ",", with: ".")
        guard let expression = try? NSRegularExpression(pattern: #"\d+(?:\.\d{1,2})?"#) else { return [] }
        let range = NSRange(normalized.startIndex..., in: normalized)
        return expression.matches(in: normalized, range: range).compactMap { match in
            guard let swiftRange = Range(match.range, in: normalized) else { return nil }
            return Double(normalized[swiftRange])
        }
    }

    private var hasVariablePrice: Bool {
        guard let price else { return false }
        if price.range(of: #"(?i)\b(mp|market\s+price|market)\b"#, options: .regularExpression) != nil {
            return true
        }
        return price.range(
            of: #"(?i)\d+(?:[.,]\d{1,2})?\s*(?:/|per\s*)?(?:oz|ounce|ounces|lb|lbs|pound|pounds|g|gram|grams|kg|person|people|each)\b"#,
            options: .regularExpression
        ) != nil
    }

    func matchesSearch(_ query: String, sectionName: String) -> Bool {
        let terms = query.vemuniSearchNormalized
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
        guard !terms.isEmpty else { return true }

        var values = [
            sectionName,
            originalName,
            englishName,
            explanation,
            price ?? "",
            itemType ?? "",
            spiceLevel ?? ""
        ]
        values.append(contentsOf: dietary)
        values.append(contentsOf: allergens)

        if let wineDetails {
            values.append(contentsOf: [
                wineDetails.producer,
                wineDetails.grape,
                wineDetails.region,
                wineDetails.country,
                wineDetails.vintage,
                wineDetails.style,
                wineDetails.body,
                wineDetails.acidity,
                wineDetails.tannin,
                wineDetails.sweetness,
                wineDetails.alcohol,
                wineDetails.servingSuggestion
            ].compactMap { $0 })
            values.append(contentsOf: wineDetails.flavors)
            values.append(contentsOf: wineDetails.foodPairings)
        }

        if let drinkDetails {
            values.append(contentsOf: [
                drinkDetails.drinkType,
                drinkDetails.baseSpirit,
                drinkDetails.abv
            ].compactMap { $0 })
            values.append(contentsOf: drinkDetails.ingredients)
            values.append(contentsOf: drinkDetails.flavorProfile)
        }

        let searchableText = values.joined(separator: " ").vemuniSearchNormalized
        return terms.allSatisfy { searchableText.contains($0) }
    }
}

private extension String {
    var vemuniSearchNormalized: String {
        folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
    }

    var vemuniTitleNormalized: String {
        let folded = folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
        let characters: [Character] = folded.unicodeScalars
            .map { CharacterSet.alphanumerics.contains($0) ? Character(String($0)) : " " }
        return String(characters)
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
            .joined(separator: " ")
    }

    var vemuniTitleContentWords: Set<String> {
        let connectors: Set<String> = [
            "a", "an", "and", "at", "by", "for", "from", "in", "of", "on", "the", "to", "with"
        ]
        return Set(split(whereSeparator: { $0.isWhitespace }).map(String.init).filter { !connectors.contains($0) })
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
