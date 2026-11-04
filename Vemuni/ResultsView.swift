import CoreImage
import CoreImage.CIFilterBuiltins
import FirebaseFunctions
import SwiftUI
import UIKit

struct ResultsView: View {
    let result: VemuniScanResult
    let saveState: ScanSaveState?
    let receiptImage: UIImage?
    let receiptImagePath: String?
    let savedVisitID: String?
    @State private var selectedTip = 20
    @State private var selectedItemFilter: MenuItemFilter = .all
    @State private var selectedItemIDs: Set<String> = []
    @State private var showingOrder = false
    @State private var searchText = ""
    @State private var isSearchPresented = false
    @State private var showingDetectionBanner = true
    @State private var showingReceiptImage = false
    @State private var showingShareOptions = false
    @State private var showingTextShare = false
    @State private var sharedMenuSession: SharedMenuSession?
    @State private var qrCodeSession: SharedMenuSession?
    @State private var sharedMenuShare: SharedMenuShare?
    @State private var shareErrorMessage = ""
    @State private var showingShareError = false
    @State private var isCreatingShareLink = false
    @State private var showingTablePicks = false
    @State private var tablePicksSummary = SharedTablePicksResponse.empty

    init(
        result: VemuniScanResult,
        saveState: ScanSaveState?,
        receiptImage: UIImage? = nil,
        receiptImagePath: String? = nil,
        savedVisitID: String? = nil,
        initialMenuPicks: [SavedMenuPick] = [],
        initialSharedMenuID: String? = nil,
        initialSharedMenuURL: String? = nil
    ) {
        self.result = result
        self.saveState = saveState
        self.receiptImage = receiptImage
        self.receiptImagePath = receiptImagePath
        self.savedVisitID = savedVisitID
        _selectedItemIDs = State(initialValue: Set(initialMenuPicks.map(\.selectionKey)))
        if let initialSharedMenuID,
           let initialSharedMenuURL,
           let url = URL(string: initialSharedMenuURL) {
            _sharedMenuSession = State(initialValue: SharedMenuSession(id: initialSharedMenuID, url: url))
        }
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
        .sheet(item: $qrCodeSession) { session in
            TableQRCodeView(result: result, session: session)
        }
        .sheet(isPresented: $showingTextShare) {
            ActivityView(activityItems: [sharedMenuText])
        }
        .sheet(item: $sharedMenuShare) { share in
            ActivityView(activityItems: [share.url])
        }
        .sheet(isPresented: $showingTablePicks) {
            if let sharedMenuSession {
                TablePicksView(session: sharedMenuSession)
            }
        }
        .confirmationDialog("Share menu", isPresented: $showingShareOptions, titleVisibility: .visible) {
            Button("Share Menu Link") {
                Task { await shareMenuLink() }
            }
            Button("Show Menu QR Code") {
                Task { await showMenuQRCode() }
            }
            Button("Share as Plain Text") { showingTextShare = true }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The link and QR code open a readable menu webpage. Original photos and your My Picks are not shared.")
        }
        .alert("Couldn’t share menu", isPresented: $showingShareError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(shareErrorMessage)
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
        .task(id: sharedMenuSession?.id) {
            guard let id = sharedMenuSession?.id else { return }
            while !Task.isCancelled {
                await refreshTablePicksSummary(id: id)
                try? await Task.sleep(for: .seconds(4))
            }
        }
        .onChange(of: savedVisitID) { _, newValue in
            guard let newValue, let sharedMenuSession else { return }
            Task { try? await VisitStorageService().saveSharedMenuSession(id: sharedMenuSession.id, url: sharedMenuSession.url, for: newValue) }
        }
        .toolbar {
            if result.kind != ScanMode.receipt.rawValue {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { isSearchPresented = true } label: {
                        Image(systemName: "magnifyingglass")
                    }
                    .accessibilityLabel("Search menu")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showingShareOptions = true } label: {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .accessibilityLabel("Share full menu")
                }
            }
        }
        .searchable(
            text: $searchText,
            isPresented: $isSearchPresented,
            placement: .navigationBarDrawer(displayMode: .automatic),
            prompt: "Search menu"
        )
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
                searchText.isEmpty ? "No menu items" : "No matching items",
                systemImage: searchText.isEmpty ? "line.3.horizontal.decrease.circle" : "magnifyingglass",
                description: Text(searchText.isEmpty
                    ? "Try a different category."
                    : "Try another search or reset your filters.")
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
                            isInOrder: isItemSelected(item, in: section.sourceID)
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
            if sharedMenuSession != nil {
                tablePicksBar
                Divider().opacity(0.45)
                if !selectedItemIDs.isEmpty || tablePicksSummary.totalPickCount > 0 {
                    allPicksBar
                    Divider().opacity(0.45)
                }
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
        let prices = selectedItems.compactMap(\.numericPrice)
        guard !prices.isEmpty else { return "View" }
        let formattedTotal = prices.reduce(0, +).formatted(
            .currency(code: result.currencyCode.isEmpty ? "USD" : result.currencyCode)
        )
        return prices.count == selectedItems.count ? formattedTotal : "\(formattedTotal)+"
    }

    private var tablePicksBar: some View {
        Button { showingTablePicks = true } label: {
            HStack(spacing: 10) {
                Image(systemName: "person.2.fill")
                    .foregroundStyle(VemuniTheme.copper)
                Text("Table Picks").fontWeight(.semibold)
                Spacer()
                Text(tablePicksSummary.compactSummary)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
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
        .accessibilityLabel("Show Table Picks, \(tablePicksSummary.compactSummary)")
    }

    private var allPicksBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "checklist")
                .foregroundStyle(VemuniTheme.sage)
            Text("All Picks")
                .fontWeight(.semibold)
            Text("· \(allPicksItemCount) \(allPicksItemCount == 1 ? "item" : "items")")
                .foregroundStyle(.secondary)
            Spacer()
            Text(allPicksTotalText)
                .fontWeight(.bold)
        }
        .font(.subheadline)
        .foregroundStyle(VemuniTheme.espresso)
        .padding(.horizontal, 20)
        .padding(.vertical, 11)
        .background(VemuniTheme.sage.opacity(0.10))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("All Picks, \(allPicksItemCount) items, \(allPicksTotalText)")
    }

    private var allPicksItemCount: Int {
        selectedItems.count + tablePicksSummary.totalPickCount
    }

    private var allPicksTotalText: String {
        let myPrices = selectedItems.compactMap(\.numericPrice)
        let pricedCount = myPrices.count + tablePicksSummary.pricedPickCount
        guard pricedCount > 0 else { return "View" }
        let total = myPrices.reduce(0, +) + tablePicksSummary.estimatedTotal
        let formatted = total.formatted(
            .currency(code: result.currencyCode.isEmpty ? "USD" : result.currencyCode)
        )
        return pricedCount == allPicksItemCount ? formatted : "\(formatted)+"
    }

    private var menuFilters: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 9) {
                ForEach(availableMenuFilters) { filter in
                    let isSelected = selectedItemFilter == filter
                    Button {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            selectedItemFilter = filter
                        }
                    } label: {
                        Text(filter.title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(isSelected ? VemuniTheme.onCopper : VemuniTheme.espresso)
                            .padding(.horizontal, 16)
                            .frame(height: 38)
                            .background(isSelected ? VemuniTheme.copper : VemuniTheme.paper)
                            .clipShape(Capsule())
                            .overlay {
                                if !isSelected {
                                    Capsule().stroke(VemuniTheme.espresso.opacity(0.12), lineWidth: 1)
                                }
                            }
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 9)
        }
        .background(.bar)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Menu categories")
    }

    private var availableMenuFilters: [MenuItemFilter] {
        MenuItemFilter.allCases.filter { filter in
            guard filter != .all else { return true }
            return result.menuSections.contains { section in
                section.items.contains { filter.matches(section: section, item: $0) }
            }
        }
    }

    private var filteredMenuSections: [FilteredMenuSection] {
        var rankedSections: [RankedFilteredMenuSection] = []

        for (originalIndex, section) in result.menuSections.enumerated() {
            let items = section.items.filter { item in
                guard selectedItemFilter.matches(section: section, item: item) else { return false }
                return item.matchesSearch(searchText, sectionName: section.name)
            }

            guard !items.isEmpty else { continue }
            rankedSections.append(RankedFilteredMenuSection(
                rank: menuSectionRank(section),
                originalIndex: originalIndex,
                section: FilteredMenuSection(sourceID: section.id, name: section.name, items: items)
            ))
        }

        rankedSections.sort { left, right in
            left.rank == right.rank
                ? left.originalIndex < right.originalIndex
                : left.rank < right.rank
        }
        return rankedSections.map(\.section)
    }

    private func menuSectionRank(_ section: MenuSection) -> Int {
        let name = section.name.lowercased()
        let containsAny: ([String]) -> Bool = { terms in
            terms.contains { containsMenuTerm($0, in: name) }
        }

        if section.sectionType == "wine"
            || section.items.contains(where: { $0.itemType == "wine" }) {
            return 90
        }
        if containsAny(["dessert", "desserts", "sweet", "sweets", "pastry", "pastries"])
            || section.items.contains(where: { MenuItemFilter.desserts.matches(section: section, item: $0) }) {
            return 50
        }
        if containsAny(["mocktail", "mocktails", "non-alcoholic", "nonalcoholic", "alcohol-free", "soft drinks", "soda", "juice", "water", "coffee", "tea"]) {
            return 60
        }
        if containsAny(["cocktail", "cocktails", "mixed drinks"]) { return 70 }
        if containsAny(["beer", "beers", "ale", "lager", "cider"]) { return 80 }
        if containsAny(["spirit", "spirits", "whiskey", "whisky", "bourbon", "scotch", "tequila", "mezcal", "vodka", "gin", "rum", "cognac", "brandy"]) {
            return 85
        }
        if section.sectionType == "drink"
            || section.items.contains(where: { $0.itemType == "drink" }) {
            return 75
        }
        if containsAny(["appetizer", "appetizers", "starter", "starters", "first", "small plates", "snacks", "raw bar"]) {
            return 10
        }
        if containsAny(["soup", "soups"]) { return 15 }
        if containsAny(["salad", "salads"]) { return 20 }
        if containsAny(["side", "sides", "accompaniment", "accompaniments"]) { return 40 }
        if containsAny(["entree", "entrees", "main", "mains", "turf", "surf", "steak", "steaks", "seafood", "pasta"]) {
            return 30
        }
        return 30
    }

    private var selectedItems: [OrderItem] {
        result.menuSections.flatMap { section in
            section.items.flatMap { item -> [OrderItem] in
                let baseKey = selectionKey(item, in: section.id)
                var values: [OrderItem] = []

                // Keep picks saved by earlier versions readable.
                if selectedItemIDs.contains(baseKey) {
                    values.append(OrderItem(
                        key: baseKey,
                        sectionName: section.name,
                        item: item,
                        servingLabel: nil,
                        displayPrice: item.displayPrice,
                        numericPrice: item.numericPrice
                    ))
                }

                if let wine = item.wineDetails {
                    for option in winePickOptions(for: wine) {
                        let key = wineSelectionKey(item, in: section.id, option: option)
                        if selectedItemIDs.contains(key) {
                            values.append(OrderItem(
                                key: key,
                                sectionName: section.name,
                                item: item,
                                servingLabel: option.label,
                                displayPrice: option.price,
                                numericPrice: option.numericPrice
                            ))
                        }
                    }
                }
                return values
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
                servingLabel: orderItem.servingLabel,
                price: orderItem.displayPrice,
                numericPrice: orderItem.numericPrice
            )
        }
    }

    private var picksPersistenceToken: String {
        "\(savedVisitID ?? "unsaved")|\(selectedItemIDs.sorted().joined(separator: ","))"
    }

    private var sharedMenuText: String {
        var lines: [String] = []
        if let restaurantName = result.restaurantName, !restaurantName.isEmpty {
            lines.append(restaurantName)
        }
        lines.append("Menu")

        for section in result.menuSections {
            lines.append("")
            lines.append(section.name.uppercased())
            for item in section.items {
                var heading = "• \(item.originalName)"
                if item.hasDistinctEnglishName {
                    heading += " (\(item.englishName))"
                }
                if let price = item.displayPrice, !price.isEmpty {
                    heading += " — \(price)"
                }
                lines.append(heading)
                if !item.explanation.isEmpty {
                    lines.append("  \(item.explanation)")
                }
            }
        }
        return lines.joined(separator: "\n")
    }

    @MainActor
    private func shareMenuLink() async {
        guard !isCreatingShareLink else { return }
        if let sharedMenuSession {
            try? await Task.sleep(for: .milliseconds(250))
            sharedMenuShare = SharedMenuShare(url: sharedMenuSession.url)
            return
        }
        isCreatingShareLink = true
        defer { isCreatingShareLink = false }
        do {
            let session = try await SharedMenuService.createSession(for: result)
            sharedMenuSession = session
            await persistSharedMenuSession(session)
            sharedMenuShare = SharedMenuShare(url: session.url)
        } catch {
            shareErrorMessage = error.localizedDescription
            showingShareError = true
        }
    }

    @MainActor
    private func showMenuQRCode() async {
        guard !isCreatingShareLink else { return }
        if let sharedMenuSession {
            try? await Task.sleep(for: .milliseconds(250))
            qrCodeSession = sharedMenuSession
            return
        }
        isCreatingShareLink = true
        defer { isCreatingShareLink = false }
        do {
            let session = try await SharedMenuService.createSession(for: result)
            sharedMenuSession = session
            await persistSharedMenuSession(session)
            qrCodeSession = session
        } catch {
            shareErrorMessage = error.localizedDescription
            showingShareError = true
        }
    }

    @MainActor
    private func refreshTablePicksSummary(id: String) async {
        if let summary = try? await SharedMenuService.tablePicks(for: id) {
            tablePicksSummary = summary
        }
    }

    private func persistSharedMenuSession(_ session: SharedMenuSession) async {
        guard let savedVisitID else { return }
        try? await VisitStorageService().saveSharedMenuSession(id: session.id, url: session.url, for: savedVisitID)
    }

    private func selectionKey(_ item: MenuItem, in sectionID: String) -> String {
        "\(sectionID)|\(item.id)"
    }

    private func wineSelectionKey(_ item: MenuItem, in sectionID: String, option: WinePickOption) -> String {
        "\(selectionKey(item, in: sectionID))|serving:\(option.id)"
    }

    private func isItemSelected(_ item: MenuItem, in sectionID: String) -> Bool {
        let baseKey = selectionKey(item, in: sectionID)
        if selectedItemIDs.contains(baseKey) { return true }
        guard let wine = item.wineDetails else { return false }
        return winePickOptions(for: wine).contains {
            selectedItemIDs.contains(wineSelectionKey(item, in: sectionID, option: $0))
        }
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
        if let wine = item.wineDetails {
            WineDetailView(
                item: item,
                wine: wine,
                baseSelectionKey: selectionKey(item, in: sectionID),
                pickOptions: winePickOptions(for: wine),
                selectedItemIDs: $selectedItemIDs
            )
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

private enum MenuItemFilter: String, CaseIterable, Identifiable {
    case all
    case food
    case drinks
    case wine
    case desserts

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return "All"
        case .food: return "Food"
        case .drinks: return "Drinks"
        case .wine: return "Wine"
        case .desserts: return "Dessert"
        }
    }

    func matches(section: MenuSection, item: MenuItem) -> Bool {
        let sectionText = [section.name, section.sectionType ?? ""]
            .map { $0.lowercased() }
            .joined(separator: " ")
        let itemLabelText = [item.itemType ?? "", item.originalName, item.englishName]
            .map { $0.lowercased() }
            .joined(separator: " ")
        let itemText = "\(itemLabelText) \(item.explanation.lowercased())"
        guard self != .all else { return true }
        let categoryText = "\(sectionText) \(itemLabelText)"

        switch self {
        case .all:
            return true
        case .food:
            return !MenuItemFilter.drinks.matches(section: section, item: item)
                && !MenuItemFilter.wine.matches(section: section, item: item)
                && !MenuItemFilter.desserts.matches(section: section, item: item)
        case .drinks:
            if item.itemType == "food" || item.itemType == "wine" || section.sectionType == "wine" {
                return false
            }
            if item.itemType == "drink" || section.sectionType == "drink" {
                return true
            }
            guard item.itemType == nil, section.sectionType == nil else { return false }
            return ["drink", "drinks", "cocktail", "cocktails", "beer", "beers", "beverage", "beverages", "coffee", "tea"]
                .contains { containsMenuTerm($0, in: categoryText) }
        case .wine:
            if item.itemType == "food" || item.itemType == "drink" || section.sectionType == "drink" {
                return false
            }
            if item.itemType == "wine" || section.sectionType == "wine" {
                return true
            }
            guard item.itemType == nil, section.sectionType == nil else { return false }
            return ["wine", "wines", "champagne", "prosecco", "sparkling", "rosé", "rose wine"]
                .contains { containsMenuTerm($0, in: categoryText) }
        case .desserts:
            let dessertSectionTerms = [
                "dessert", "desserts", "sweet", "sweets", "pastry", "pastries", "after dinner"
            ]
            if dessertSectionTerms.contains(where: { containsMenuTerm($0, in: sectionText) }) {
                return true
            }

            let savoryTerms = [
                "savory", "crab", "fish", "salmon", "cod", "shrimp", "lobster",
                "goat cheese", "blue cheese", "black truffle", "white truffle", "truffle oil", "potato", "corn", "rice",
                "zucchini", "vegetable", "meat", "chicken", "pork", "beef"
            ]
            if savoryTerms.contains(where: { containsMenuTerm($0, in: itemText) }) {
                return false
            }

            let unambiguousDessertTerms = [
                "dessert", "desserts", "ice cream", "gelato", "sorbet", "cheesecake",
                "brownie", "brownies", "cookie", "cookies", "pudding", "mousse",
                "tiramisu", "crème brûlée", "creme brulee", "pie", "pies", "pastry", "pastries"
            ]
            if unambiguousDessertTerms.contains(where: { containsMenuTerm($0, in: itemText) }) {
                return true
            }

            let hasCake = ["cake", "cakes"].contains { containsMenuTerm($0, in: itemText) }
            return hasCake
        }
    }
}

private enum DrinkFilter: String, CaseIterable, Identifiable {
    case all
    case wine
    case cocktails
    case spirits
    case beer
    case nonAlcoholic

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return "All drinks"
        case .wine: return "Wine"
        case .cocktails: return "Cocktails"
        case .spirits: return "Spirits"
        case .beer: return "Beer"
        case .nonAlcoholic: return "Non-alcoholic"
        }
    }

    func matches(section: MenuSection, item: MenuItem, itemFilter: MenuItemFilter) -> Bool {
        guard itemFilter == .drinks, self != .all else { return true }
        let text = [
            section.name,
            section.sectionType ?? "",
            item.itemType ?? "",
            item.drinkDetails?.drinkType ?? "",
            item.drinkDetails?.baseSpirit ?? "",
            item.originalName,
            item.englishName
        ]
            .map { $0.lowercased() }
            .joined(separator: " ")

        switch self {
        case .all:
            return true
        case .wine:
            return item.itemType == "wine"
                || section.sectionType == "wine"
                || ["wine", "wines", "champagne", "prosecco", "sparkling", "rosé", "rose wine"]
                    .contains { containsMenuTerm($0, in: text) }
        case .cocktails:
            return ["cocktail", "cocktails", "mixed drink", "mixed drinks", "martini", "margarita", "highball", "spritz"]
                .contains { containsMenuTerm($0, in: text) }
        case .spirits:
            return [
                "spirits", "tequila", "whiskey", "whisky", "scotch", "cognac", "bourbon",
                "vodka", "gin", "rum", "mezcal", "brandy", "liqueur"
            ].contains { containsMenuTerm($0, in: text) }
        case .beer:
            return ["beer", "ale", "lager", "stout", "porter", "pilsner", "ipa", "cider"]
                .contains { containsMenuTerm($0, in: text) }
        case .nonAlcoholic:
            return [
                "non-alcoholic", "nonalcoholic", "alcohol-free", "mocktail", "soft drink",
                "soda", "juice", "water", "coffee", "tea", "lemonade"
            ].contains { containsMenuTerm($0, in: text) }
        }
    }
}

private func containsMenuTerm(_ term: String, in text: String) -> Bool {
    let escapedTerm = NSRegularExpression.escapedPattern(for: term)
    return text.range(of: "\\b\(escapedTerm)\\b", options: .regularExpression) != nil
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

private struct MenuFilterSheet: View {
    @Binding var itemFilter: MenuItemFilter
    @Binding var drinkFilter: DrinkFilter
    @Binding var priceRange: MenuPriceRange
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Item type") {
                    Picker("Item type", selection: $itemFilter) {
                        ForEach(MenuItemFilter.allCases) { filter in
                            Text(filter.title).tag(filter)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.inline)
                }

                if itemFilter == .drinks {
                    Section("Drink type") {
                        Picker("Drink type", selection: $drinkFilter) {
                            ForEach(DrinkFilter.allCases) { filter in
                                Text(filter.title).tag(filter)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.inline)
                    }
                }

                Section("Price") {
                    Picker("Price", selection: $priceRange) {
                        ForEach(MenuPriceRange.allCases) { range in
                            Text(range.title).tag(range)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.inline)
                }
            }
            .navigationTitle("Filter menu")
            .navigationBarTitleDisplayMode(.inline)
            .onChange(of: itemFilter) { _, newValue in
                if newValue != .drinks { drinkFilter = .all }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Reset") {
                        itemFilter = .all
                        drinkFilter = .all
                        priceRange = .any
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .fontWeight(.semibold)
                }
            }
        }
    }
}

private struct FilteredMenuSection: Identifiable {
    let sourceID: String
    let name: String
    let items: [MenuItem]
    var id: String { sourceID }
}

private struct RankedFilteredMenuSection {
    let rank: Int
    let originalIndex: Int
    let section: FilteredMenuSection
}

private struct OrderItem: Identifiable {
    let key: String
    let sectionName: String
    let item: MenuItem
    let servingLabel: String?
    let displayPrice: String?
    let numericPrice: Double?
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
                                if let servingLabel = orderItem.servingLabel {
                                    Label(
                                        servingLabel,
                                        systemImage: servingLabel == "Glass" ? "wineglass" : "waterbottle.fill"
                                    )
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(VemuniTheme.copper)
                                }
                                if orderItem.item.hasDistinctEnglishName {
                                    Text(orderItem.item.englishName)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            Text(orderItem.displayPrice ?? "—")
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
                            Text("Market, per-unit, and choice-based prices aren’t included in the subtotal.")
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
        items.compactMap(\.numericPrice).count
    }

    private var subtotal: Double {
        items.compactMap(\.numericPrice).reduce(0, +)
    }
}

private struct MenuItemRow: View {
    let item: MenuItem
    let isInOrder: Bool
    var body: some View {
        Group {
            if let wine = item.wineDetails {
                wineRow(wine)
            } else {
                standardRow
            }
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

    private var standardRow: some View {
        HStack(alignment: .top, spacing: 12) {
            if let itemSymbol {
                Image(systemName: itemSymbol)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(VemuniTheme.copper)
                    .frame(width: 20)
                    .padding(.top, 2)
            }
            VStack(alignment: .leading, spacing: 5) {
                Text(rowTitle)
                    .font(.headline)
                    .foregroundStyle(VemuniTheme.espresso)
                if item.hasDistinctEnglishName {
                    Text(item.englishName).font(.subheadline.weight(.medium))
                    Text(item.explanation)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                } else if !item.explanation.isEmpty {
                    Text(item.explanation)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
                if item.itemType == "drink", let drink = item.drinkDetails,
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
            if let price = item.displayPrice {
                Text(price).font(.headline).foregroundStyle(VemuniTheme.espresso)
            }
            Image(systemName: "chevron.right")
                .font(.caption.weight(.bold))
                .foregroundStyle(.tertiary)
                .padding(.top, 4)
        }
    }

    private func wineRow(_ wine: WineDetails) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: "wineglass")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(VemuniTheme.copper)
                    .frame(width: 20)
                Text(rowTitle)
                    .font(.headline)
                    .foregroundStyle(VemuniTheme.espresso)
                Spacer(minLength: 8)
                if let price = item.displayPrice {
                    Text(price)
                        .font(.headline)
                        .foregroundStyle(VemuniTheme.espresso)
                        .fixedSize(horizontal: true, vertical: false)
                }
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.tertiary)
            }

            let details = wineSummary(wine, excluding: rowTitle)
            if !details.isEmpty {
                Text(details)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 32)
            } else if !item.explanation.isEmpty {
                Text(item.explanation)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 32)
            }

            if !wine.foodPairings.isEmpty {
                Label {
                    Text(wine.foodPairings.prefix(3).joined(separator: " • "))
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "fork.knife")
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(VemuniTheme.sage)
                .padding(.leading, 32)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Pairs with \(wine.foodPairings.prefix(3).joined(separator: ", "))")
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

    private var rowTitle: String {
        guard let producer = item.wineDetails?.producer?.trimmingCharacters(in: .whitespacesAndNewlines),
              !producer.isEmpty else {
            return item.originalName
        }
        return producer
    }

    private func wineSummary(_ wine: WineDetails, excluding title: String) -> String {
        let printedDetails = [wine.grape, wine.region, wine.vintage, wine.style]
            .compactMap { (value: String?) -> String? in
                guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !value.isEmpty,
                      !title.localizedCaseInsensitiveContains(value) else { return nil }
                return value
            }
            .reduce(into: [String]()) { values, value in
                guard !values.contains(where: { $0.caseInsensitiveCompare(value) == .orderedSame }) else { return }
                values.append(value)
            }
        if !printedDetails.isEmpty {
            return printedDetails.joined(separator: " • ")
        }

        let profile = [wine.body, wine.sweetness]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if !profile.isEmpty {
            return profile.joined(separator: " • ")
        }
        return wine.flavors.prefix(3).joined(separator: " • ")
    }
}

private struct WinePickOption: Identifiable, Hashable {
    let id: String
    let label: String
    let symbolName: String
    let price: String
    let numericPrice: Double?
}

private func winePickOptions(for wine: WineDetails) -> [WinePickOption] {
    [
        winePickOption(id: "glass", label: "Glass", symbolName: "wineglass", price: wine.glassPrice),
        winePickOption(id: "bottle", label: "Bottle", symbolName: "waterbottle.fill", price: wine.bottlePrice)
    ].compactMap { $0 }
}

private func winePickOption(id: String, label: String, symbolName: String, price: String?) -> WinePickOption? {
    guard let price = price?.trimmingCharacters(in: .whitespacesAndNewlines),
          !price.isEmpty else { return nil }
    let normalized = price.replacingOccurrences(of: ",", with: ".")
    let number = normalized.range(of: #"\d+(?:\.\d{1,2})?"#, options: .regularExpression)
        .flatMap { Double(normalized[$0]) }
    return WinePickOption(id: id, label: label, symbolName: symbolName, price: price, numericPrice: number)
}

private struct WinePickSelectionButtons: View {
    let item: MenuItem
    let baseSelectionKey: String
    let options: [WinePickOption]
    @Binding var selectedItemIDs: Set<String>
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        HStack(spacing: 10) {
            ForEach(options) { option in
                let key = selectionKey(for: option)
                let isSelected = selectedItemIDs.contains(key)
                Button {
                    if isSelected {
                        selectedItemIDs.remove(key)
                    } else {
                        selectedItemIDs.insert(key)
                        dismiss()
                    }
                } label: {
                    VStack(spacing: 2) {
                        HStack(spacing: 6) {
                            Image(systemName: option.symbolName)
                            Text(isSelected ? "Added \(option.label.lowercased())" : "Add \(option.label.lowercased())")
                                .lineLimit(1)
                            if isSelected {
                                Image(systemName: "checkmark.circle.fill")
                            }
                        }
                        Text(option.price)
                            .font(.subheadline.weight(.semibold))
                    }
                    .font(.headline)
                    .foregroundStyle(isSelected ? VemuniTheme.espresso : Color.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 58)
                    .background(isSelected ? VemuniTheme.paper : VemuniTheme.primaryAction)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .overlay {
                        if isSelected {
                            RoundedRectangle(cornerRadius: 16)
                                .stroke(VemuniTheme.sage, lineWidth: 1.5)
                        }
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(
                    isSelected
                        ? "Remove \(option.label) of \(item.originalName) from my picks"
                        : "Add \(option.label) of \(item.originalName) to my picks"
                )
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 6)
        .background(.bar)
    }

    private func selectionKey(for option: WinePickOption) -> String {
        "\(baseSelectionKey)|serving:\(option.id)"
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
                if let price = item.displayPrice, !price.isEmpty {
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
    let baseSelectionKey: String
    let pickOptions: [WinePickOption]
    @Binding var selectedItemIDs: Set<String>

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
                    if item.hasDistinctEnglishName {
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
            if pickOptions.isEmpty {
                OrderSelectionButton(item: item, isInOrder: baseSelectionBinding)
            } else {
                WinePickSelectionButtons(
                    item: item,
                    baseSelectionKey: baseSelectionKey,
                    options: pickOptions,
                    selectedItemIDs: $selectedItemIDs
                )
            }
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
        if values.isEmpty, let price = item.displayPrice, !price.isEmpty { values.append(("Price", price)) }
        return values
    }

    private var baseSelectionBinding: Binding<Bool> {
        Binding(
            get: { selectedItemIDs.contains(baseSelectionKey) },
            set: { selected in
                if selected { selectedItemIDs.insert(baseSelectionKey) }
                else { selectedItemIDs.remove(baseSelectionKey) }
            }
        )
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
                if item.hasDistinctEnglishName {
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
                if item.hasDistinctEnglishName {
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

private struct TableQRCodeView: View {
    @Environment(\.dismiss) private var dismiss
    let result: VemuniScanResult
    let session: SharedMenuSession

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 22) {
                    Text(result.restaurantName?.isEmpty == false ? result.restaurantName! : "Shared Menu")
                        .font(.title2.weight(.bold))
                        .foregroundStyle(VemuniTheme.espresso)
                        .multilineTextAlignment(.center)

                    Group {
                        if let image = QRCodeRenderer.image(for: session.url.absoluteString) {
                            Image(uiImage: image)
                                .interpolation(.none)
                                .resizable()
                                .scaledToFit()
                                .padding(18)
                                .background(.white)
                                .clipShape(RoundedRectangle(cornerRadius: 24))
                                .shadow(color: VemuniTheme.espresso.opacity(0.12), radius: 20, y: 8)
                                .accessibilityLabel("QR code for the shared menu")
                        } else {
                            ContentUnavailableView("Couldn’t create QR code", systemImage: "exclamationmark.triangle")
                        }
                    }
                    .frame(maxWidth: 360, maxHeight: 360)

                    Text("Scan to view this menu")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(VemuniTheme.espresso)
                    Text("Guests can add picks using a first name and last initial. The link contains extracted menu text—not the original photos—and does not automatically expire.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)

                    Group {
                        ShareLink(item: session.url) {
                            Label("Share Link", systemImage: "square.and.arrow.up")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(VemuniPrimaryButtonStyle())

                        Button {
                            UIPasteboard.general.url = session.url
                        } label: {
                            Label("Copy Link", systemImage: "doc.on.doc")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                    }
                }
                .padding(24)
            }
            .background(VemuniTheme.cream.ignoresSafeArea())
            .navigationTitle("Menu QR Code")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

private struct TablePicksView: View {
    @Environment(\.dismiss) private var dismiss
    let session: SharedMenuSession
    @State private var summary = SharedTablePicksResponse.empty
    @State private var errorMessage: String?
    @State private var showingClearConfirmation = false
    @State private var participantPendingRemoval: SharedTableParticipant?
    @State private var showingRemoveConfirmation = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    VStack(spacing: 7) {
                        Label(summary.compactSummary, systemImage: "person.2.fill")
                            .font(.title2.weight(.bold))
                            .foregroundStyle(VemuniTheme.sage)
                        Text("Updates automatically")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(22)
                    .background(VemuniTheme.sage.opacity(0.10))
                    .clipShape(RoundedRectangle(cornerRadius: 20))

                    if summary.tablePicks.isEmpty {
                        ContentUnavailableView(
                            "Waiting for your table…",
                            systemImage: "person.2.fill",
                            description: Text("Ask everyone to add items to My Picks from the shared menu.")
                        )
                        .padding(.vertical, 36)
                    } else {
                        ForEach(summary.tablePicks) { pick in
                            HStack(alignment: .top, spacing: 14) {
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(pick.name)
                                        .font(.title3.weight(.semibold))
                                        .foregroundStyle(VemuniTheme.espresso)
                                    if !pick.pickedBy.isEmpty {
                                        Text(pick.pickedBy.joined(separator: " · "))
                                            .font(.subheadline)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                Spacer(minLength: 10)
                                VStack(alignment: .trailing, spacing: 7) {
                                    if pick.price?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
                                        Text(pick.formattedPrice(currencyCode: summary.currencyCode))
                                            .font(.title3.weight(.bold))
                                            .foregroundStyle(VemuniTheme.espresso)
                                    }
                                    Text("\(pick.count) \(pick.count == 1 ? "pick" : "picks")")
                                        .font(.headline)
                                        .foregroundStyle(pick.count == 1 ? VemuniTheme.sage : VemuniTheme.copper)
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 8)
                                        .background((pick.count == 1 ? VemuniTheme.sage : VemuniTheme.copper).opacity(0.12))
                                        .clipShape(Capsule())
                                }
                            }
                            .padding(18)
                            .background(VemuniTheme.paper)
                            .clipShape(RoundedRectangle(cornerRadius: 20))
                        }

                        if !summary.tableParticipants.isEmpty {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("Diners")
                                    .font(.headline)
                                    .foregroundStyle(VemuniTheme.espresso)
                                ForEach(summary.tableParticipants) { participant in
                                    HStack {
                                        Text(participant.displayName)
                                            .foregroundStyle(VemuniTheme.espresso)
                                        Spacer()
                                        Button(role: .destructive) {
                                            participantPendingRemoval = participant
                                            showingRemoveConfirmation = true
                                        } label: {
                                            Image(systemName: "trash")
                                        }
                                        .accessibilityLabel("Remove \(participant.displayName)")
                                    }
                                    .padding(.vertical, 4)
                                }
                            }
                            .padding(18)
                            .background(VemuniTheme.paper)
                            .clipShape(RoundedRectangle(cornerRadius: 20))
                        }

                        Button("Clear Table Picks", role: .destructive) {
                            showingClearConfirmation = true
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                        .frame(maxWidth: .infinity)
                    }

                    Text("Guests enter a first name and last initial. No account is required.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    if let errorMessage {
                        Text(errorMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(20)
            }
            .background(VemuniTheme.cream.ignoresSafeArea())
            .navigationTitle("Table Picks")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button { Task { await refresh() } } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .accessibilityLabel("Refresh Table Picks")
                }
            }
            .task(id: session.id) {
                while !Task.isCancelled {
                    await refresh()
                    try? await Task.sleep(for: .seconds(4))
                }
            }
            .confirmationDialog("Clear Table Picks?", isPresented: $showingClearConfirmation, titleVisibility: .visible) {
                Button("Clear Table Picks", role: .destructive) { Task { await clear() } }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This removes everyone’s picks from this shared menu.")
            }
            .confirmationDialog("Remove diner?", isPresented: $showingRemoveConfirmation, titleVisibility: .visible) {
                Button("Remove \(participantPendingRemoval?.displayName ?? "Diner")", role: .destructive) {
                    Task { await removeParticipant() }
                }
                Button("Cancel", role: .cancel) { participantPendingRemoval = nil }
            } message: {
                Text("This removes that browser’s picks from the table.")
            }
        }
    }

    @MainActor
    private func refresh() async {
        do {
            summary = try await SharedMenuService.tablePicks(for: session.id)
            errorMessage = nil
        } catch {
            errorMessage = "Couldn’t refresh Table Picks. Trying again…"
        }
    }

    @MainActor
    private func clear() async {
        do {
            try await SharedMenuService.clearTablePicks(for: session.id)
            summary = .empty
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func removeParticipant() async {
        guard let participant = participantPendingRemoval else { return }
        do {
            try await SharedMenuService.removeParticipant(participant.id, from: session.id)
            participantPendingRemoval = nil
            await refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private enum SharedMenuService {
    static func createSession(for result: VemuniScanResult) async throws -> SharedMenuSession {
        let encoded = try JSONEncoder().encode(result)
        guard let menu = try JSONSerialization.jsonObject(with: encoded) as? [String: Any] else {
            throw SharedMenuError.invalidMenu
        }
        let callable = Functions.functions(region: "us-central1").httpsCallable("createSharedMenu")
        let response = try await callable.call(["menu": menu])
        guard let payload = response.data as? [String: Any],
              let id = payload["id"] as? String,
              let value = payload["url"] as? String,
              let url = URL(string: value) else {
            throw SharedMenuError.invalidResponse
        }
        return SharedMenuSession(id: id, url: url)
    }

    static func createLink(for result: VemuniScanResult) async throws -> URL {
        try await createSession(for: result).url
    }

    static func tablePicks(for id: String) async throws -> SharedTablePicksResponse {
        var components = URLComponents(string: "https://us-central1-vemuni-d4f87.cloudfunctions.net/getSharedMenu")!
        components.queryItems = [
            URLQueryItem(name: "id", value: id),
            URLQueryItem(name: "picksOnly", value: "1")
        ]
        guard let url = components.url else { throw SharedMenuError.invalidResponse }
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let httpResponse = response as? HTTPURLResponse, 200..<300 ~= httpResponse.statusCode else {
            throw SharedMenuError.invalidResponse
        }
        return try JSONDecoder().decode(SharedTablePicksResponse.self, from: data)
    }

    static func clearTablePicks(for id: String) async throws {
        let callable = Functions.functions(region: "us-central1").httpsCallable("clearTablePicks")
        _ = try await callable.call(["id": id])
    }

    static func removeParticipant(_ participantId: String, from id: String) async throws {
        let callable = Functions.functions(region: "us-central1").httpsCallable("removeTableParticipant")
        _ = try await callable.call(["id": id, "participantId": participantId])
    }
}

private struct SharedMenuSession: Identifiable {
    let id: String
    let url: URL
}

private struct SharedTablePicksResponse: Decodable {
    let tablePicks: [SharedTablePick]
    let participantCount: Int
    let tableParticipants: [SharedTableParticipant]
    let currencyCode: String

    static let empty = SharedTablePicksResponse(
        tablePicks: [],
        participantCount: 0,
        tableParticipants: [],
        currencyCode: "USD"
    )

    private enum CodingKeys: String, CodingKey { case tablePicks, participantCount, tableParticipants, currencyCode }

    init(
        tablePicks: [SharedTablePick],
        participantCount: Int,
        tableParticipants: [SharedTableParticipant],
        currencyCode: String
    ) {
        self.tablePicks = tablePicks
        self.participantCount = participantCount
        self.tableParticipants = tableParticipants
        self.currencyCode = currencyCode
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        tablePicks = try container.decodeIfPresent([SharedTablePick].self, forKey: .tablePicks) ?? []
        participantCount = try container.decodeIfPresent(Int.self, forKey: .participantCount) ?? 0
        tableParticipants = try container.decodeIfPresent([SharedTableParticipant].self, forKey: .tableParticipants) ?? []
        currencyCode = try container.decodeIfPresent(String.self, forKey: .currencyCode) ?? "USD"
    }

    var totalPickCount: Int { tablePicks.reduce(0) { $0 + $1.count } }

    var pricedPickCount: Int {
        tablePicks.reduce(0) { total, pick in
            total + (pick.numericPrice == nil ? 0 : pick.count)
        }
    }

    var estimatedTotal: Double {
        tablePicks.reduce(0) { total, pick in
            total + ((pick.numericPrice ?? 0) * Double(pick.count))
        }
    }

    var compactSummary: String {
        let items = "\(totalPickCount) \(totalPickCount == 1 ? "item" : "items")"
        guard pricedPickCount > 0 else { return items }
        let formatted = estimatedTotal.formatted(.currency(code: currencyCode.isEmpty ? "USD" : currencyCode))
        return "\(items) · \(formatted)\(pricedPickCount == totalPickCount ? "" : "+")"
    }
}

private struct SharedTablePick: Decodable, Identifiable {
    let itemKey: String
    let name: String
    let price: String?
    let count: Int
    let pickedBy: [String]
    var id: String { itemKey }

    var numericPrice: Double? {
        guard let price else { return nil }
        let normalized = price.replacingOccurrences(of: ",", with: "")
        guard let expression = try? NSRegularExpression(pattern: #"\d+(?:\.\d{1,2})?"#) else { return nil }
        let range = NSRange(normalized.startIndex..., in: normalized)
        let matches = expression.matches(in: normalized, range: range)
        guard matches.count == 1,
              let swiftRange = Range(matches[0].range, in: normalized) else { return nil }
        return Double(normalized[swiftRange])
    }

    func formattedPrice(currencyCode: String) -> String {
        guard let numericPrice else { return price ?? "" }
        return numericPrice.formatted(
            .currency(code: currencyCode.isEmpty ? "USD" : currencyCode)
        )
    }

    private enum CodingKeys: String, CodingKey { case itemKey, name, price, count, pickedBy }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        itemKey = try container.decode(String.self, forKey: .itemKey)
        name = try container.decode(String.self, forKey: .name)
        price = try container.decodeIfPresent(String.self, forKey: .price)
        count = try container.decode(Int.self, forKey: .count)
        pickedBy = try container.decodeIfPresent([String].self, forKey: .pickedBy) ?? []
    }
}

private struct SharedTableParticipant: Decodable, Identifiable {
    let participantId: String
    let displayName: String
    var id: String { participantId }
}

private enum SharedMenuError: LocalizedError {
    case invalidMenu
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .invalidMenu: return "This menu could not be prepared for sharing."
        case .invalidResponse: return "Vemuni received an invalid sharing response."
        }
    }
}

private enum QRCodeRenderer {
    static func image(for value: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(value.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let transformed = output.transformed(by: CGAffineTransform(scaleX: 12, y: 12))
        guard let cgImage = CIContext().createCGImage(transformed, from: transformed.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}

private struct ActivityView: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

private struct SharedMenuShare: Identifiable {
    let id = UUID()
    let url: URL
}
