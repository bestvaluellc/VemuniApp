import SwiftUI
import UIKit

struct ResultsView: View {
    let result: VemuniScanResult
    let saveState: ScanSaveState?
    let receiptImage: UIImage?
    let receiptImagePath: String?
    let savedVisitID: String?
    @State private var selectedTip = 20
    @State private var selectedPriceRange: MenuPriceRange = .any
    @State private var selectedItemIDs: Set<String> = []
    @State private var showingOrder = false
    @State private var showingDetectionBanner = true
    @State private var showingReceiptImage = false

    init(
        result: VemuniScanResult,
        saveState: ScanSaveState?,
        receiptImage: UIImage? = nil,
        receiptImagePath: String? = nil,
        savedVisitID: String? = nil,
        initialMenuPicks: [SavedMenuPick] = []
    ) {
        self.result = result
        self.saveState = saveState
        self.receiptImage = receiptImage
        self.receiptImagePath = receiptImagePath
        self.savedVisitID = savedVisitID
        _selectedItemIDs = State(initialValue: Set(initialMenuPicks.map(\.selectionKey)))
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                if saveState != nil && showingDetectionBanner {
                    detectionBanner
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
                if let saveState { saveBanner(saveState) }
                if result.kind == "receipt", let receipt = result.receipt {
                    receiptView(receipt)
                } else {
                    menuView
                }
                if !result.warnings.isEmpty { warnings }
            }
            .padding(20)
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if result.kind != "receipt" {
                menuControls
            }
        }
        .sheet(isPresented: $showingOrder) {
            OrderSummaryView(items: selectedItems, currencyCode: result.currencyCode) { key in
                selectedItemIDs.remove(key)
                if selectedItemIDs.isEmpty { showingOrder = false }
            }
            .presentationDetents([.medium, .large])
        }
        .fullScreenCover(isPresented: $showingReceiptImage) {
            ReceiptImageViewer(
                localImage: receiptImage,
                storagePath: receiptImagePath
            )
        }
        .task(id: saveState != nil) {
            guard saveState != nil else {
                showingDetectionBanner = false
                return
            }
            showingDetectionBanner = true
            try? await Task.sleep(for: .seconds(2))
            withAnimation(.easeOut(duration: 0.25)) {
                showingDetectionBanner = false
            }
        }
        .task(id: picksPersistenceToken) {
            guard result.kind != ScanMode.receipt.rawValue, let savedVisitID else { return }
            try? await Task.sleep(for: .milliseconds(350))
            try? await VisitStorageService().saveMenuPicks(menuPickSnapshots, for: savedVisitID)
        }
    }

    private func saveBanner(_ state: ScanSaveState) -> some View {
        HStack(spacing: 10) {
            switch state {
            case .saving:
                ProgressView()
                Text(result.kind == "receipt" ? "Saving bill and scan…" : "Saving scan…")
            case .saved:
                Image(systemName: "checkmark.icloud.fill")
                    .foregroundStyle(VemuniTheme.sage)
                Text(result.kind == "receipt" ? "Bill image and scan saved" : "Scan saved")
            case .failed(let message):
                Image(systemName: "exclamationmark.icloud.fill")
                    .foregroundStyle(VemuniTheme.copper)
                Text("Scan completed, but it wasn’t saved. \(message)")
            }
        }
        .font(.footnote.weight(.medium))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 4)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var detectionBanner: some View {
        HStack(spacing: 9) {
            Image(systemName: scanNeedsReview ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundStyle(scanNeedsReview ? VemuniTheme.copper : VemuniTheme.sage)
                .font(.subheadline.weight(.semibold))
            Text(scanNeedsReview ? "Review scan" : "Scan complete")
                .fontWeight(.semibold)
                .foregroundStyle(VemuniTheme.espresso)
            Text("· \(compactDetectionSummary)")
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Spacer(minLength: 0)
        }
        .font(.subheadline)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(scanNeedsReview ? VemuniTheme.copper.opacity(0.08) : VemuniTheme.sage.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var scanNeedsReview: Bool {
        let text = ([result.notice] + result.warnings).joined(separator: " ").lowercased()
        return ["blurry", "uncertain", "inferred", "partial", "review", "missing"]
            .contains { text.contains($0) }
    }

    private var compactDetectionSummary: String {
        let language = Locale.current.localizedString(forLanguageCode: result.detectedLanguage)
            ?? result.detectedLanguage.uppercased()
        return "\(language) \(detectedContentDescription)"
    }

    private var detectedContentDescription: String {
        switch result.menuType {
        case "wine": return "wine list"
        case "drinks": return "drinks menu"
        case "mixed": return "food and drinks menu"
        default: return result.kind == "receipt" ? "bill" : "menu"
        }
    }

    @ViewBuilder
    private var menuView: some View {
        if filteredMenuSections.isEmpty {
            ContentUnavailableView(
                "No menu items",
                systemImage: "line.3.horizontal.decrease.circle",
                description: Text("Try a different category or price range.")
            )
            .frame(maxWidth: .infinity)
            .padding(.vertical, 30)
        }

        ForEach(filteredMenuSections) { section in
            Section {
                ForEach(section.items) { item in
                    NavigationLink {
                        itemDestination(item, sectionID: section.sourceID)
                            .onAppear {
                                VemuniAnalytics.menuItemOpened(
                                    hasAllergenHints: !item.allergens.isEmpty,
                                    hasDietaryHints: !item.dietary.isEmpty
                                )
                            }
                    } label: {
                        MenuItemRow(
                            item: item,
                            isInOrder: selectedItemIDs.contains(selectionKey(item, in: section.sourceID))
                        )
                    }
                    .buttonStyle(.plain)
                }
            } header: {
                Text(section.name.uppercased())
                    .font(.system(.headline, design: .serif, weight: .bold))
                    .foregroundStyle(VemuniTheme.copper)
                    .padding(.top, 4)
            }
        }

    }

    private var menuControls: some View {
        VStack(spacing: 0) {
            if !selectedItemIDs.isEmpty {
                orderBar
                Divider().opacity(0.45)
            }
            menuFilters
        }
        .background(.bar)
    }

    private var orderBar: some View {
        Button { showingOrder = true } label: {
            HStack(spacing: 10) {
                Image(systemName: "bag.fill")
                    .foregroundStyle(VemuniTheme.copper)
                Text("My picks").fontWeight(.semibold)
                Text("· \(selectedItems.count) \(selectedItems.count == 1 ? "item" : "items")")
                    .foregroundStyle(.secondary)
                Spacer()
                Text(orderTotalText).fontWeight(.semibold)
                Image(systemName: "chevron.right")
                    .font(.caption.bold())
                    .foregroundStyle(.tertiary)
            }
            .font(.subheadline)
            .foregroundStyle(VemuniTheme.espresso)
            .padding(.horizontal, 20)
            .padding(.vertical, 11)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Show My picks, \(selectedItems.count) items, \(orderTotalText)")
    }

    private var orderTotalText: String {
        let prices = selectedItems.compactMap { $0.item.numericPrice }
        guard !prices.isEmpty else { return "View" }
        let formattedTotal = prices.reduce(0, +).formatted(
            .currency(code: result.currencyCode.isEmpty ? "USD" : result.currencyCode)
        )
        return prices.count == selectedItems.count ? formattedTotal : "\(formattedTotal)+"
    }

    private var menuFilters: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(MenuPriceRange.allCases) { range in
                    Button(range.title) { selectedPriceRange = range }
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(selectedPriceRange == range ? VemuniTheme.onCopper : VemuniTheme.espresso)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 7)
                        .background(selectedPriceRange == range ? VemuniTheme.copper : VemuniTheme.paper)
                        .clipShape(Capsule())
                        .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 9)
        }
    }

    private var filteredMenuSections: [FilteredMenuSection] {
        result.menuSections.compactMap { section in
            let items = section.items.filter { item in
                selectedPriceRange.contains(item.numericPrice)
            }
            return items.isEmpty ? nil : FilteredMenuSection(sourceID: section.id, name: section.name, items: items)
        }
    }

    private var selectedItems: [OrderItem] {
        result.menuSections.flatMap { section in
            section.items.compactMap { item in
                let key = selectionKey(item, in: section.id)
                return selectedItemIDs.contains(key)
                    ? OrderItem(key: key, sectionName: section.name, item: item)
                    : nil
            }
        }
    }

    private var menuPickSnapshots: [SavedMenuPick] {
        selectedItems.map { orderItem in
            SavedMenuPick(
                selectionKey: orderItem.key,
                sectionName: orderItem.sectionName,
                originalName: orderItem.item.originalName,
                englishName: orderItem.item.englishName,
                price: orderItem.item.price,
                numericPrice: orderItem.item.numericPrice
            )
        }
    }

    private var picksPersistenceToken: String {
        "\(savedVisitID ?? "unsaved")|\(selectedItemIDs.sorted().joined(separator: ","))"
    }

    private func selectionKey(_ item: MenuItem, in sectionID: String) -> String {
        "\(sectionID)|\(item.id)"
    }

    private func selectionBinding(_ item: MenuItem, in sectionID: String) -> Binding<Bool> {
        let key = selectionKey(item, in: sectionID)
        return Binding(
            get: { selectedItemIDs.contains(key) },
            set: { isSelected in
                if isSelected {
                    selectedItemIDs.insert(key)
                } else {
                    selectedItemIDs.remove(key)
                }
            }
        )
    }

    @ViewBuilder
    private func itemDestination(_ item: MenuItem, sectionID: String) -> some View {
        if item.itemType == "wine", let wine = item.wineDetails {
            WineDetailView(item: item, wine: wine, isInOrder: selectionBinding(item, in: sectionID))
        } else if item.itemType == "drink", let drink = item.drinkDetails {
            DrinkDetailView(item: item, drink: drink, isInOrder: selectionBinding(item, in: sectionID))
        } else {
            MenuItemDetailView(item: item, isInOrder: selectionBinding(item, in: sectionID))
        }
    }

    private func receiptView(_ receipt: ReceiptAnalysis) -> some View {
        VStack(spacing: 18) {
            if receiptImage != nil || receiptImagePath != nil {
                Button { showingReceiptImage = true } label: {
                    Label("View receipt", systemImage: "doc.viewfinder")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 11)
                }
                .buttonStyle(.bordered)
                .tint(VemuniTheme.copper)
            }

            if receipt.possibleDuplicateTipRisk {
                Label("A service charge or tip may already be included. Check before adding another tip.", systemImage: "exclamationmark.triangle.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.orange)
                    .padding(15)
                    .background(Color.orange.opacity(0.10))
                    .clipShape(RoundedRectangle(cornerRadius: 15))
            }

            VStack(spacing: 11) {
                moneyRow("Subtotal", receipt.subtotal)
                moneyRow("Tax", receipt.tax)
                if let charge = receipt.serviceCharge {
                    moneyRow(receipt.serviceChargeLabel ?? "Service charge", charge)
                }
                if let tip = receipt.statedTip { moneyRow("Tip on bill", tip) }
                Divider()
                moneyRow("Total due", receipt.total, emphasized: true)
            }
            .padding(18)
            .background(VemuniTheme.paper)
            .clipShape(RoundedRectangle(cornerRadius: 20))

            if !receipt.tipAlreadyIncluded {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Choose a tip").font(.headline)
                    Picker("Tip", selection: $selectedTip) {
                        ForEach([15, 18, 20, 22, 25], id: \.self) { Text("\($0)%").tag($0) }
                    }
                    .pickerStyle(.segmented)
                    HStack {
                        VStack(alignment: .leading) {
                            Text("Tip").font(.caption).foregroundStyle(.secondary)
                            Text(currency(receipt.tipAmount(percent: selectedTip)))
                                .font(.title3.weight(.semibold))
                        }
                        Spacer()
                        VStack(alignment: .trailing) {
                            Text("New total").font(.caption).foregroundStyle(.secondary)
                            Text(currency(receipt.totalWithTip(percent: selectedTip)))
                                .font(.title3.weight(.bold))
                        }
                    }
                }
                .padding(18)
                .background(VemuniTheme.paper)
                .clipShape(RoundedRectangle(cornerRadius: 20))
            }
        }
    }

    private var warnings: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(result.warnings, id: \.self) { warning in
                Label(warning, systemImage: "info.circle")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func moneyRow(_ label: String, _ amount: Double?, emphasized: Bool = false) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(currency(amount))
        }
        .font(emphasized ? .title3.bold() : .body)
        .foregroundStyle(emphasized ? VemuniTheme.espresso : .primary)
    }

    private func currency(_ amount: Double?) -> String {
        guard let amount else { return "—" }
        return amount.formatted(.currency(code: result.currencyCode.isEmpty ? "USD" : result.currencyCode))
    }
}

private enum MenuPriceRange: String, CaseIterable, Identifiable {
    case any
    case upTo15
    case upTo25

    var id: String { rawValue }

    var title: String {
        switch self {
        case .any: return "All prices"
        case .upTo15: return "15 or less"
        case .upTo25: return "25 or less"
        }
    }

    func contains(_ price: Double?) -> Bool {
        guard self != .any else { return true }
        guard let price else { return false }
        switch self {
        case .any: return true
        case .upTo15: return price <= 15
        case .upTo25: return price <= 25
        }
    }
}

private struct FilteredMenuSection: Identifiable {
    let sourceID: String
    let name: String
    let items: [MenuItem]
    var id: String { sourceID }
}

private struct OrderItem: Identifiable {
    let key: String
    let sectionName: String
    let item: MenuItem
    var id: String { key }
}

private struct OrderSummaryView: View {
    let items: [OrderItem]
    let currencyCode: String
    let remove: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(items) { orderItem in
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(orderItem.item.originalName)
                                    .font(.body.weight(.semibold))
                                if orderItem.item.englishName != orderItem.item.originalName {
                                    Text(orderItem.item.englishName)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            Text(orderItem.item.price ?? "—")
                                .foregroundStyle(VemuniTheme.espresso)
                            Button {
                                remove(orderItem.key)
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Remove \(orderItem.item.originalName)")
                        }
                    }
                } header: {
                    Text("Selected items")
                }

                if pricedItemsCount > 0 {
                    Section {
                        HStack {
                            Text("Estimated subtotal")
                                .fontWeight(.semibold)
                            Spacer()
                            Text(subtotal.formatted(.currency(code: currencyCode.isEmpty ? "USD" : currencyCode)))
                                .fontWeight(.bold)
                        }
                        if pricedItemsCount < items.count {
                            Text("Some item prices weren’t available and aren’t included in the subtotal.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("My picks")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var pricedItemsCount: Int {
        items.compactMap { $0.item.numericPrice }.count
    }

    private var subtotal: Double {
        items.compactMap { $0.item.numericPrice }.reduce(0, +)
    }
}

private struct MenuItemRow: View {
    let item: MenuItem
    let isInOrder: Bool
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if let itemSymbol {
                Image(systemName: itemSymbol)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(VemuniTheme.copper)
                    .frame(width: 20)
                    .padding(.top, 2)
            }
            VStack(alignment: .leading, spacing: 5) {
                Text(item.originalName)
                    .font(.headline)
                    .foregroundStyle(VemuniTheme.espresso)
                if item.englishName != item.originalName {
                    Text(item.englishName).font(.subheadline.weight(.medium))
                }
                Text(item.explanation)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                if item.itemType == "wine", let wine = item.wineDetails {
                    Text(wineSummary(wine))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(VemuniTheme.sage)
                        .lineLimit(2)
                } else if item.itemType == "drink", let drink = item.drinkDetails,
                          !drink.flavorProfile.isEmpty {
                    Text(drink.flavorProfile.joined(separator: " • "))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(VemuniTheme.sage)
                } else if !item.dietary.isEmpty {
                    Text(item.dietary.joined(separator: " • "))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(VemuniTheme.sage)
                }
            }
            Spacer(minLength: 8)
            if let price = item.price {
                Text(price).font(.headline).foregroundStyle(VemuniTheme.espresso)
            }
            Image(systemName: "chevron.right")
                .font(.caption.weight(.bold))
                .foregroundStyle(.tertiary)
                .padding(.top, 4)
        }
        .padding(16)
        .background(isInOrder ? VemuniTheme.sage.opacity(0.20) : VemuniTheme.paper)
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .overlay {
            if isInOrder {
                RoundedRectangle(cornerRadius: 18)
                    .stroke(VemuniTheme.sage.opacity(0.75), lineWidth: 1.5)
            }
        }
    }

    private var itemSymbol: String? {
        switch item.itemType {
        case "wine": return "wineglass"
        case "drink": return "martini"
        default: return nil
        }
    }

    private func wineSummary(_ wine: WineDetails) -> String {
        [wine.grape, wine.region, wine.vintage]
            .compactMap { value in
                guard let value, !value.isEmpty else { return nil }
                return value
            }
            .joined(separator: " • ")
    }
}

private struct OrderSelectionButton: View {
    let item: MenuItem
    @Binding var isInOrder: Bool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Button {
            if isInOrder {
                isInOrder = false
            } else {
                isInOrder = true
                dismiss()
            }
        } label: {
            HStack(spacing: 9) {
                Image(systemName: isInOrder ? "checkmark.circle.fill" : "plus.circle.fill")
                Text(isInOrder ? "Added to my picks" : "Add to my picks")
                Spacer()
                if let price = item.price, !price.isEmpty {
                    Text(price)
                }
            }
            .font(.headline)
            .foregroundStyle(isInOrder ? VemuniTheme.espresso : Color.white)
            .padding(.horizontal, 18)
            .frame(height: 52)
            .background(isInOrder ? VemuniTheme.paper : VemuniTheme.primaryAction)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .overlay {
                if isInOrder {
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(VemuniTheme.sage, lineWidth: 1.5)
                }
            }
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 6)
        .background(.bar)
        .accessibilityLabel(isInOrder ? "Remove \(item.originalName) from my picks" : "Add \(item.originalName) to my picks")
    }
}

private struct WineDetailView: View {
    let item: MenuItem
    let wine: WineDetails
    @Binding var isInOrder: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 7) {
                    if let style = wine.style, !style.isEmpty {
                        Text(style.uppercased())
                            .font(.caption.weight(.bold))
                            .foregroundStyle(VemuniTheme.copper)
                    }
                    Text(item.originalName)
                        .font(.system(.largeTitle, design: .serif, weight: .bold))
                        .foregroundStyle(VemuniTheme.espresso)
                    if item.englishName != item.originalName {
                        Text(item.englishName).font(.title3.weight(.semibold))
                    }
                    if !wineOrigin.isEmpty {
                        Text(wineOrigin)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    if !prices.isEmpty {
                        HStack(spacing: 22) {
                            ForEach(prices, id: \.0) { label, value in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(label).font(.caption).foregroundStyle(.secondary)
                                    Text(value).font(.title3.weight(.bold))
                                }
                            }
                        }
                        .padding(.top, 4)
                    }
                }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(VemuniTheme.paper)
                .clipShape(RoundedRectangle(cornerRadius: 20))

                if wine.profileIsTypical {
                    Label(
                        "Typical profile for this wine style; details can vary by producer and vintage.",
                        systemImage: "info.circle"
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }

                if !item.explanation.isEmpty {
                    wineCard("What it tastes like", symbol: "nose") {
                        Text(item.explanation).lineSpacing(3)
                    }
                }

                if !profileRows.isEmpty {
                    wineCard("Style", symbol: "slider.horizontal.3") {
                        VStack(spacing: 10) {
                            ForEach(profileRows, id: \.0) { label, value in
                                HStack {
                                    Text(label).foregroundStyle(.secondary)
                                    Spacer()
                                    Text(value).fontWeight(.semibold)
                                }
                            }
                        }
                    }
                }

                if !wine.flavors.isEmpty {
                    wineCard("Flavors and aromas", symbol: "sparkles") {
                        FlowingTags(values: wine.flavors)
                    }
                }

                if !wine.foodPairings.isEmpty {
                    wineCard("Good with", symbol: "fork.knife") {
                        FlowingTags(values: wine.foodPairings)
                    }
                }

                if let serving = wine.servingSuggestion, !serving.isEmpty {
                    wineCard("Serving suggestion", symbol: "thermometer.medium") {
                        Text(serving)
                    }
                }
            }
            .padding(20)
        }
        .background(VemuniTheme.cream.ignoresSafeArea())
        .safeAreaInset(edge: .bottom) {
            OrderSelectionButton(item: item, isInOrder: $isInOrder)
        }
        .navigationTitle("Wine details")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var wineOrigin: String {
        [wine.producer, wine.grape, wine.region, wine.country, wine.vintage]
            .compactMap { value in
                guard let value, !value.isEmpty else { return nil }
                return value
            }
            .joined(separator: " · ")
    }

    private var prices: [(String, String)] {
        var values: [(String, String)] = []
        if let glass = wine.glassPrice, !glass.isEmpty { values.append(("Glass", glass)) }
        if let bottle = wine.bottlePrice, !bottle.isEmpty { values.append(("Bottle", bottle)) }
        if values.isEmpty, let price = item.price, !price.isEmpty { values.append(("Price", price)) }
        return values
    }

    private var profileRows: [(String, String)] {
        [
            ("Body", wine.body),
            ("Acidity", wine.acidity),
            ("Tannin", wine.tannin),
            ("Sweetness", wine.sweetness),
            ("Alcohol", wine.alcohol)
        ].compactMap { label, value in
            guard let value, !value.isEmpty else { return nil }
            return (label, value)
        }
    }

    private func wineCard<Content: View>(
        _ title: String,
        symbol: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            Label(title, systemImage: symbol)
                .font(.headline)
                .foregroundStyle(VemuniTheme.espresso)
            content()
                .font(.body)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(VemuniTheme.paper)
        .clipShape(RoundedRectangle(cornerRadius: 20))
    }
}

private struct DrinkDetailView: View {
    let item: MenuItem
    let drink: DrinkDetails
    @Binding var isInOrder: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text(item.originalName)
                    .font(.system(.largeTitle, design: .serif, weight: .bold))
                    .foregroundStyle(VemuniTheme.espresso)
                if item.englishName != item.originalName {
                    Text(item.englishName).font(.title3.weight(.semibold))
                }
                Text(item.explanation).lineSpacing(4)
                if let type = drink.drinkType, !type.isEmpty {
                    detail("Type", type, symbol: "martini")
                }
                if let spirit = drink.baseSpirit, !spirit.isEmpty {
                    detail("Base", spirit, symbol: "drop")
                }
                if !drink.ingredients.isEmpty {
                    detail("Ingredients", drink.ingredients.joined(separator: ", "), symbol: "list.bullet")
                }
                if !drink.flavorProfile.isEmpty {
                    detail("Flavor", drink.flavorProfile.joined(separator: ", "), symbol: "sparkles")
                }
                if let abv = drink.abv, !abv.isEmpty {
                    detail("Alcohol", abv, symbol: "percent")
                }
            }
            .padding(20)
        }
        .background(VemuniTheme.cream.ignoresSafeArea())
        .safeAreaInset(edge: .bottom) {
            OrderSelectionButton(item: item, isInOrder: $isInOrder)
        }
        .navigationTitle("Drink details")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func detail(_ title: String, _ value: String, symbol: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol).foregroundStyle(VemuniTheme.copper).frame(width: 22)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.caption).foregroundStyle(.secondary)
                Text(value).font(.body.weight(.medium))
            }
        }
    }
}

private struct FlowingTags: View {
    let values: [String]

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack { tags }
            VStack(alignment: .leading) { tags }
        }
    }

    @ViewBuilder private var tags: some View {
        ForEach(values, id: \.self) { value in
            Text(value)
                .font(.caption.weight(.semibold))
                .foregroundStyle(VemuniTheme.sage)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(VemuniTheme.sage.opacity(0.10))
                .clipShape(Capsule())
        }
    }
}

private struct MenuItemDetailView: View {
    let item: MenuItem
    @Binding var isInOrder: Bool
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text(item.originalName)
                    .font(.system(.largeTitle, design: .serif, weight: .bold))
                    .foregroundStyle(VemuniTheme.espresso)
                if item.englishName != item.originalName {
                    Text(item.englishName).font(.title3.weight(.semibold))
                }
                Text(item.explanation).font(.body).lineSpacing(4)
                if let spice = item.spiceLevel, !spice.isEmpty {
                    detail("Spice level", spice, symbol: "flame")
                }
                if !item.dietary.isEmpty {
                    detail("Dietary", item.dietary.joined(separator: ", "), symbol: "leaf")
                }
                if !item.allergens.isEmpty {
                    detail("Possible allergens", item.allergens.joined(separator: ", "), symbol: "exclamationmark.shield")
                    Text("Ingredient and allergen information can be incomplete. Always verify with the restaurant.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(20)
        }
        .background(VemuniTheme.cream.ignoresSafeArea())
        .safeAreaInset(edge: .bottom) {
            OrderSelectionButton(item: item, isInOrder: $isInOrder)
        }
        .navigationTitle("Dish details")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func detail(_ title: String, _ value: String, symbol: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol).foregroundStyle(VemuniTheme.copper).frame(width: 22)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.caption).foregroundStyle(.secondary)
                Text(value).font(.body.weight(.medium))
            }
        }
    }
}

private struct ReceiptImageViewer: View {
    let localImage: UIImage?
    let storagePath: String?
    @Environment(\.dismiss) private var dismiss
    @State private var downloadedImage: UIImage?
    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let image = localImage ?? downloadedImage {
                ZoomableReceiptImage(image: image)
                    .ignoresSafeArea()
            } else if isLoading {
                ProgressView("Loading receipt…")
                    .tint(.white)
                    .foregroundStyle(.white)
            } else {
                ContentUnavailableView(
                    "Receipt unavailable",
                    systemImage: "photo.badge.exclamationmark",
                    description: Text(errorMessage ?? "The receipt image couldn’t be loaded.")
                )
                .foregroundStyle(.white)
            }

            VStack {
                HStack {
                    Spacer()
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.headline.weight(.bold))
                            .foregroundStyle(.white)
                            .frame(width: 44, height: 44)
                            .background(.black.opacity(0.62))
                            .clipShape(Circle())
                    }
                    .accessibilityLabel("Close receipt")
                }
                Spacer()
            }
            .padding()
        }
        .statusBarHidden()
        .task {
            guard localImage == nil, downloadedImage == nil, let storagePath else { return }
            isLoading = true
            do {
                downloadedImage = try await VisitStorageService().loadReceiptImage(at: storagePath)
            } catch {
                errorMessage = error.localizedDescription
            }
            isLoading = false
        }
    }
}

private struct ZoomableReceiptImage: UIViewRepresentable {
    let image: UIImage

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> UIScrollView {
        let scrollView = UIScrollView()
        scrollView.backgroundColor = .black
        scrollView.minimumZoomScale = 1
        scrollView.maximumZoomScale = 6
        scrollView.bouncesZoom = true
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.delegate = context.coordinator

        let imageView = UIImageView(image: image)
        imageView.contentMode = .scaleAspectFit
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.isUserInteractionEnabled = true
        scrollView.addSubview(imageView)

        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            imageView.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            imageView.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            imageView.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor),
            imageView.heightAnchor.constraint(equalTo: scrollView.frameLayoutGuide.heightAnchor)
        ])

        let doubleTap = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.didDoubleTap(_:))
        )
        doubleTap.numberOfTapsRequired = 2
        scrollView.addGestureRecognizer(doubleTap)

        context.coordinator.imageView = imageView
        context.coordinator.scrollView = scrollView
        return scrollView
    }

    func updateUIView(_ scrollView: UIScrollView, context: Context) {
        context.coordinator.imageView?.image = image
    }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        weak var imageView: UIImageView?
        weak var scrollView: UIScrollView?

        func viewForZooming(in scrollView: UIScrollView) -> UIView? {
            imageView
        }

        @objc func didDoubleTap(_ gesture: UITapGestureRecognizer) {
            guard let scrollView else { return }
            if scrollView.zoomScale > scrollView.minimumZoomScale {
                scrollView.setZoomScale(scrollView.minimumZoomScale, animated: true)
            } else {
                let point = gesture.location(in: imageView)
                let targetScale = min(3, scrollView.maximumZoomScale)
                let width = scrollView.bounds.width / targetScale
                let height = scrollView.bounds.height / targetScale
                scrollView.zoom(
                    to: CGRect(
                        x: point.x - width / 2,
                        y: point.y - height / 2,
                        width: width,
                        height: height
                    ),
                    animated: true
                )
            }
        }
    }
}
