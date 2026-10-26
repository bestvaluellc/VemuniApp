import SwiftUI

struct SavedScansView: View {
    @State private var visits: [SavedVisitRecord] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var visitPendingDeletion: SavedVisitRecord?
    @State private var deletingVisitId: String?

    var body: some View {
        Group {
            if isLoading && visits.isEmpty {
                ProgressView("Loading scans…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if visits.isEmpty {
                emptyState
            } else {
                scanList
            }
        }
        .background(VemuniTheme.cream.ignoresSafeArea())
        .navigationTitle("Saved Scans")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            // Let the navigation push finish before starting Firebase and list work.
            if visits.isEmpty {
                try? await Task.sleep(for: .milliseconds(300))
            }
            guard !Task.isCancelled else { return }
            await loadVisits()
        }
        .confirmationDialog(
            "Delete this scan?",
            isPresented: Binding(
                get: { visitPendingDeletion != nil },
                set: { if !$0 { visitPendingDeletion = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete Scan", role: .destructive) {
                guard let visit = visitPendingDeletion else { return }
                visitPendingDeletion = nil
                Task { await delete(visit) }
            }
            Button("Cancel", role: .cancel) { visitPendingDeletion = nil }
        } message: {
            Text("This permanently deletes the saved scan and its bill image, if it has one.")
        }
    }

    private var scanList: some View {
        List {
            if let errorMessage {
                Section {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(VemuniTheme.copper)
                }
            }

            Section {
                ForEach(visits) { visit in
                    NavigationLink {
                        ResultsView(
                            result: visit.result,
                            saveState: nil,
                            receiptImagePath: visit.receiptImagePath,
                            savedVisitID: visit.id,
                            initialMenuPicks: visit.menuPicks
                        )
                            .navigationTitle(visit.title)
                            .navigationBarTitleDisplayMode(.inline)
                    } label: {
                        SavedScanRow(
                            visit: visit,
                            isDeleting: deletingVisitId == visit.id
                        )
                    }
                    .disabled(deletingVisitId == visit.id)
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) {
                            visitPendingDeletion = visit
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .refreshable { await loadVisits() }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No Saved Scans", systemImage: "doc.text.magnifyingglass")
        } description: {
            Text(errorMessage ?? "Menus, wine lists, drinks, and bills will appear here after you scan them.")
        } actions: {
            if errorMessage != nil {
                Button("Try Again") { Task { await loadVisits() } }
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    @MainActor
    private func loadVisits() async {
        if visits.isEmpty { isLoading = true }
        errorMessage = nil
        do {
            let loadedVisits = try await VisitStorageService().fetchVisits()
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                visits = loadedVisits
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    @MainActor
    private func delete(_ visit: SavedVisitRecord) async {
        deletingVisitId = visit.id
        errorMessage = nil
        do {
            try await VisitStorageService().delete(visit)
            visits.removeAll { $0.id == visit.id }
        } catch {
            errorMessage = "Couldn’t delete the scan. \(error.localizedDescription)"
        }
        deletingVisitId = nil
    }
}

private struct SavedScanRow: View {
    let visit: SavedVisitRecord
    let isDeleting: Bool

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: visit.scanSymbol)
                .font(.title3)
                .foregroundStyle(visit.isReceipt || visit.result.menuType == "wine" ? VemuniTheme.copper : VemuniTheme.sage)
                .frame(width: 44, height: 44)
                .background(VemuniTheme.cream)
                .clipShape(RoundedRectangle(cornerRadius: 13))

            if isDeleting {
                ProgressView()
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(visit.title)
                    .font(.headline)
                    .foregroundStyle(VemuniTheme.espresso)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                Text(visit.isReceipt ? "Bill" : visit.pageDescription)
                    .lineLimit(1)

                if !visit.dateAndPicksDescription.isEmpty {
                    Text(visit.dateAndPicksDescription)
                        .lineLimit(1)
                }

#if DEBUG
                if let totalTokens = visit.result.aiUsage?.totalTokens {
                    HStack(spacing: 5) {
                        Text("AI tokens")
                        Text(totalTokens.formatted())
                            .fontWeight(.semibold)
                    }
                    .font(.caption)
                    .foregroundStyle(VemuniTheme.sage)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("AI tokens, \(totalTokens)")
                }
#endif
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .layoutPriority(1)
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 5)
    }
}

private extension SavedVisitRecord {
    var isReceipt: Bool { result.kind == ScanMode.receipt.rawValue }

    var title: String {
        let restaurant = result.restaurantName?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let restaurant, !restaurant.isEmpty { return restaurant }
        if isReceipt { return "Restaurant Bill" }
        if result.menuType == "wine" { return "Wine List" }
        if result.menuType == "drinks" { return "Drinks Menu" }
        return "Restaurant Menu"
    }

    var pageDescription: String {
        let label: String
        switch result.menuType {
        case "wine": label = "Wine list"
        case "drinks": label = "Drinks"
        case "mixed": label = "Food & drinks"
        default: label = "Menu"
        }
        return pageCount == 1 ? label : "\(label) · \(pageCount) pages"
    }

    var dateAndPicksDescription: String {
        var values: [String] = []
        if let createdAt {
            values.append(createdAt.formatted(.dateTime.month(.abbreviated).day().year()))
        }
        if !menuPicks.isEmpty {
            values.append("\(menuPicks.count) \(menuPicks.count == 1 ? "pick" : "picks")")
        }
        return values.joined(separator: " · ")
    }

    var scanSymbol: String {
        if isReceipt { return "receipt.fill" }
        switch result.menuType {
        case "wine": return "wineglass"
        case "drinks": return "martini"
        case "mixed": return "fork.knife"
        default: return "text.viewfinder"
        }
    }
}
