import SwiftUI

struct ResultsView: View {
    let result: VemuniScanResult
    @State private var selectedTip = 20

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                detectionBanner
                if result.kind == "receipt", let receipt = result.receipt {
                    receiptView(receipt)
                } else {
                    menuView
                }
                if !result.warnings.isEmpty { warnings }
            }
            .padding(20)
        }
    }

    private var detectionBanner: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(VemuniTheme.sage)
                .font(.title3)
            VStack(alignment: .leading, spacing: 3) {
                Text("\(result.detectedLanguage) detected")
                    .font(.headline)
                    .foregroundStyle(VemuniTheme.espresso)
                Text(result.notice)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(VemuniTheme.paper)
        .clipShape(RoundedRectangle(cornerRadius: 18))
    }

    private var menuView: some View {
        ForEach(result.menuSections) { section in
            Section {
                ForEach(section.items) { item in
                    NavigationLink {
                        MenuItemDetailView(item: item)
                            .onAppear {
                                VemuniAnalytics.menuItemOpened(
                                    hasAllergenHints: !item.allergens.isEmpty,
                                    hasDietaryHints: !item.dietary.isEmpty
                                )
                            }
                    } label: {
                        MenuItemRow(item: item)
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

    private func receiptView(_ receipt: ReceiptAnalysis) -> some View {
        VStack(spacing: 18) {
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

private struct MenuItemRow: View {
    let item: MenuItem
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
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
                if !item.dietary.isEmpty {
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
        .background(VemuniTheme.paper)
        .clipShape(RoundedRectangle(cornerRadius: 18))
    }
}

private struct MenuItemDetailView: View {
    let item: MenuItem
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
