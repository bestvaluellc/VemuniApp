import PhotosUI
import SwiftUI
import UIKit

struct ScanView: View {
    @Environment(\.dismiss) private var dismiss
    let mode: ScanMode
    let onSuccessfulScan: () -> Void

    @State private var photoItems: [PhotosPickerItem] = []
    @State private var images: [UIImage] = []
    @State private var selectedPageIndex = 0
    @State private var showCamera = false
    @State private var isAnalyzing = false
    @State private var result: VemuniScanResult?
    @State private var saveState: ScanSaveState?
    @State private var savedVisitID: String?
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Group {
                if let result {
                    ResultsView(
                        result: result,
                        saveState: saveState,
                        receiptImage: mode == .receipt ? images.first : nil,
                        savedVisitID: savedVisitID
                    )
                } else {
                    scanner
                }
            }
            .background(VemuniTheme.cream.ignoresSafeArea())
            .navigationTitle(mode.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
            .sheet(isPresented: $showCamera) {
                CameraPicker { selected in
                    if mode == .menu {
                        if images.count < maximumPageCount {
                            images.append(selected)
                            selectedPageIndex = images.count - 1
                        }
                    } else {
                        images = [selected]
                        selectedPageIndex = 0
                    }
                    VemuniAnalytics.photoSelected(mode: mode, source: "camera")
                }
                    .ignoresSafeArea()
            }
            .onChange(of: photoItems) { _, items in
                guard !items.isEmpty else { return }
                Task {
                    var selectedImages: [UIImage] = []
                    for item in items.prefix(maximumPageCount) {
                        guard let data = try? await item.loadTransferable(type: Data.self),
                              let selected = UIImage(data: data) else { continue }
                        selectedImages.append(selected)
                    }
                    if mode == .menu {
                        images.append(contentsOf: selectedImages.prefix(maximumPageCount - images.count))
                        if !selectedImages.isEmpty {
                            selectedPageIndex = images.count - 1
                        }
                    } else if let selected = selectedImages.first {
                        images = [selected]
                        selectedPageIndex = 0
                    }
                    photoItems = []
                    if !selectedImages.isEmpty {
                        VemuniAnalytics.photoSelected(mode: mode, source: "photo_library")
                    }
                }
            }
            .onAppear { VemuniAnalytics.screen(mode == .menu ? "menu_scan" : "receipt_scan") }
        }
    }

    private var scanner: some View {
        ScrollView {
            VStack(spacing: 22) {
                if let image = selectedPageImage {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxHeight: 390)
                        .clipShape(RoundedRectangle(cornerRadius: 22))
                        .overlay { RoundedRectangle(cornerRadius: 22).stroke(.white, lineWidth: 3) }
                        .id(selectedPageIndex)
                        .transition(.opacity)
                    if mode == .menu { pageStrip }
                } else {
                    scanGuide
                }

                if images.isEmpty {
                    Button {
                        showCamera = true
                    } label: {
                        Label("Take Photo", systemImage: "camera.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(VemuniPrimaryButtonStyle())
                    .disabled(!UIImagePickerController.isSourceTypeAvailable(.camera))

                    PhotosPicker(selection: $photoItems, maxSelectionCount: maximumPageCount, matching: .images) {
                        Label("Choose from Photos", systemImage: "photo.on.rectangle")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)

                    if mode == .menu {
                        Text("Up to \(maximumPageCount) pages per menu scan")
                            .font(.footnote.weight(.medium))
                            .foregroundStyle(.secondary)
                    }
                } else {
                    if mode == .menu && images.count < maximumPageCount {
                        HStack(spacing: 12) {
                            Button { showCamera = true } label: {
                                compactActionLabel("Add Page", systemImage: "camera.fill")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)

                            PhotosPicker(
                                selection: $photoItems,
                                maxSelectionCount: maximumPageCount - images.count,
                                matching: .images
                            ) {
                                compactActionLabel("Add Photos", systemImage: "photo.on.rectangle")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                        }
                        .controlSize(.large)
                        .disabled(isAnalyzing)
                    }

                    Button { analyze() } label: {
                        HStack {
                            if isAnalyzing { ProgressView().tint(.white) }
                            Label(analyzeButtonTitle, systemImage: "sparkles")
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(VemuniPrimaryButtonStyle())
                    .disabled(isAnalyzing)

                    Button(mode == .menu ? "Start over" : "Use a different photo") {
                        images.removeAll()
                        selectedPageIndex = 0
                        saveState = nil
                        errorMessage = nil
                    }
                        .disabled(isAnalyzing)
                }

                if let errorMessage {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                }

                Text(mode == .menu
                     ? "Vemuni identifies food, wine, and drinks, translates menu text, and explains unfamiliar items."
                     : "Vemuni checks totals, identifies service charges, and helps prevent accidental double tipping.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(20)
        }
    }

    private var maximumPageCount: Int { mode == .menu ? 8 : 1 }

    private var selectedPageImage: UIImage? {
        guard images.indices.contains(selectedPageIndex) else { return images.last }
        return images[selectedPageIndex]
    }

    private func compactActionLabel(_ title: String, systemImage: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
            Text(title)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .font(.subheadline.weight(.semibold))
    }

    private var analyzeButtonTitle: String {
        if isAnalyzing {
            return images.count > 1 ? "Reading \(images.count) pages…" : "Reading…"
        }
        return mode == .menu && images.count > 1 ? "Read \(images.count) Pages" : mode.title
    }

    private var pageStrip: some View {
        VStack(spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(Array(images.enumerated()), id: \.offset) { index, image in
                        ZStack(alignment: .topTrailing) {
                            Button {
                                guard selectedPageIndex != index else { return }
                                withAnimation(.easeInOut(duration: 0.15)) {
                                    selectedPageIndex = index
                                }
                            } label: {
                                Image(uiImage: image)
                                    .resizable()
                                    .scaledToFill()
                                    .frame(width: 76, height: 96)
                                    .clipShape(RoundedRectangle(cornerRadius: 12))
                                    .overlay(alignment: .bottomLeading) {
                                        Text("Page \(index + 1)")
                                            .font(.caption2.weight(.bold))
                                            .foregroundStyle(.white)
                                            .padding(6)
                                            .background(.black.opacity(0.55))
                                            .clipShape(RoundedRectangle(cornerRadius: 7))
                                            .padding(5)
                                    }
                                    .overlay {
                                        RoundedRectangle(cornerRadius: 12)
                                            .stroke(
                                                index == selectedPageIndex ? VemuniTheme.primaryAction : .clear,
                                                lineWidth: 3
                                            )
                                    }
                                    .contentShape(RoundedRectangle(cornerRadius: 12))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Page \(index + 1)")
                            .accessibilityAddTraits(index == selectedPageIndex ? .isSelected : [])

                            Button {
                                images.remove(at: index)
                                if images.isEmpty {
                                    selectedPageIndex = 0
                                } else if index < selectedPageIndex {
                                    selectedPageIndex -= 1
                                } else if selectedPageIndex >= images.count {
                                    selectedPageIndex = images.count - 1
                                }
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .symbolRenderingMode(.palette)
                                    .foregroundStyle(.white, Color.black.opacity(0.65))
                            }
                            .offset(x: 5, y: -5)
                            .disabled(isAnalyzing)
                            .accessibilityLabel("Remove page \(index + 1)")
                        }
                    }
                }
                .padding(.horizontal, 6)
                .padding(.top, 6)
            }

            Text(images.count == maximumPageCount
                 ? "Maximum of \(maximumPageCount) pages reached"
                 : "\(images.count) of \(maximumPageCount) pages selected")
                .font(.footnote.weight(.medium))
                .foregroundStyle(images.count == maximumPageCount ? VemuniTheme.copper : Color.secondary)
        }
        .accessibilityLabel("\(images.count) menu pages selected")
    }

    private var scanGuide: some View {
        VStack(spacing: 16) {
            Image(systemName: mode.symbol)
                .font(.system(size: 58, weight: .light))
                .foregroundStyle(VemuniTheme.copper)
            Text(mode == .menu ? "Fit the full menu in frame" : "Fit the entire bill in frame")
                .font(.title3.weight(.semibold))
                .foregroundStyle(VemuniTheme.espresso)
            Text("Hold steady and avoid glare. Low light is okay—use flash if needed.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, minHeight: 300)
        .padding()
        .background(VemuniTheme.paper)
        .clipShape(RoundedRectangle(cornerRadius: 24))
    }

    private func analyze() {
        guard !images.isEmpty else { return }
        errorMessage = nil
        isAnalyzing = true
        VemuniAnalytics.scanStarted(mode: mode)
        Task {
            do {
                let value = try await ScanService().analyze(images: images, mode: mode)
                await MainActor.run {
                    result = value
                    saveState = .saving
                    isAnalyzing = false
                    VemuniAnalytics.scanCompleted(mode: mode, result: value)
                    onSuccessfulScan()
                }
                do {
                    let savedVisit = try await VisitStorageService().save(result: value, sourceImages: images)
                    await MainActor.run {
                        savedVisitID = savedVisit.id
                        saveState = .saved
                    }
                } catch {
                    await MainActor.run { saveState = .failed(error.localizedDescription) }
                }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    isAnalyzing = false
                    VemuniAnalytics.scanFailed(mode: mode, error: error)
                }
            }
        }
    }
}

struct VemuniPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .padding(.vertical, 15)
            .padding(.horizontal, 18)
            .foregroundStyle(.white)
            .background(VemuniTheme.primaryAction.opacity(configuration.isPressed ? 0.8 : 1))
            .clipShape(RoundedRectangle(cornerRadius: 16))
    }
}
