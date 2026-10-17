import FirebaseAnalytics

enum VemuniAnalytics {
    static func screen(_ name: String) {
        Analytics.logEvent(AnalyticsEventScreenView, parameters: [
            AnalyticsParameterScreenName: name,
            AnalyticsParameterScreenClass: name
        ])
    }

    static func scanOpened(mode: ScanMode) {
        Analytics.logEvent("scan_opened", parameters: ["scan_type": mode.rawValue])
    }

    static func photoSelected(mode: ScanMode, source: String) {
        Analytics.logEvent("scan_photo_selected", parameters: [
            "scan_type": mode.rawValue,
            "photo_source": source
        ])
    }

    static func scanStarted(mode: ScanMode) {
        Analytics.logEvent("scan_started", parameters: ["scan_type": mode.rawValue])
    }

    static func scanCompleted(mode: ScanMode, result: VemuniScanResult) {
        Analytics.logEvent("scan_completed", parameters: [
            "scan_type": mode.rawValue,
            "detected_language": sanitized(result.detectedLanguage),
            "menu_section_count": result.menuSections.count,
            "menu_item_count": result.menuSections.reduce(0) { $0 + $1.items.count },
            "duplicate_tip_risk": result.receipt?.possibleDuplicateTipRisk == true ? 1 : 0
        ])
    }

    static func scanFailed(mode: ScanMode, error: Error) {
        Analytics.logEvent("scan_failed", parameters: [
            "scan_type": mode.rawValue,
            "error_category": errorCategory(error)
        ])
    }

    static func menuItemOpened(hasAllergenHints: Bool, hasDietaryHints: Bool) {
        Analytics.logEvent("menu_item_opened", parameters: [
            "has_allergen_hints": hasAllergenHints ? 1 : 0,
            "has_dietary_hints": hasDietaryHints ? 1 : 0
        ])
    }

    static func authAttempt(method: String, creatingAccount: Bool = false) {
        Analytics.logEvent("auth_attempt", parameters: [
            "method": method,
            "creating_account": creatingAccount ? 1 : 0
        ])
    }

    static func authCompleted(method: String, isNewUser: Bool) {
        Analytics.logEvent(AnalyticsEventLogin, parameters: [
            AnalyticsParameterMethod: method,
            "is_new_user": isNewUser ? 1 : 0
        ])
    }

    private static func errorCategory(_ error: Error) -> String {
        if error is URLError { return "network" }
        guard let scanError = error as? ScanServiceError else { return "server_or_unknown" }
        switch scanError {
        case .missingEndpoint: return "configuration"
        case .imageEncoding: return "image_encoding"
        case .invalidResponse: return "invalid_response"
        case .server: return "server"
        }
    }

    private static func sanitized(_ value: String) -> String {
        String(value.lowercased().prefix(40))
    }
}
