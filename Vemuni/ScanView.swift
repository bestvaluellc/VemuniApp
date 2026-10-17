import PhotosUI
import SwiftUI
import UIKit

struct ScanView: View {
    @Environment(\.dismiss) private var dismiss
    let mode: ScanMode
    let onSuccessfulScan: () -> Void

    @State private var photoItem: PhotosPickerItem?
    @State private var image: UIImage?
    @State private var showCamera = false
    @State private var isAnalyzing = false
    @State private var result: VemuniScanResult?
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Group {
                if let result {
                    ResultsView(result: result)
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
                    image = selected
                    VemuniAnalytics.photoSelected(mode: mode, source: "camera")
                }
                    .ignoresSafeArea()
            }
            .onChange(of: photoItem) { _, item in
                guard let item else { return }
                Task {
                    guard let data = try? await item.loadTransferable(type: Data.self),
                          let selected = UIImage(data: data) else { return }
                    image = selected
                    VemuniAnalytics.photoSelected(mode: mode, source: "photo_library")
                }
            }
            .onAppear { VemuniAnalytics.screen(mode == .menu ? "menu_scan" : "receipt_scan") }
        }
    }

    private var scanner: some View {
        ScrollView {
            VStack(spacing: 22) {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxHeight: 390)
                        .clipShape(RoundedRectangle(cornerRadius: 22))
                        .overlay { RoundedRectangle(cornerRadius: 22).stroke(.white, lineWidth: 3) }
                } else {
                    scanGuide
                }

                if image == nil {
                    Button {
                        showCamera = true
                    } label: {
                        Label("Take Photo", systemImage: "camera.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(VemuniPrimaryButtonStyle())
                    .disabled(!UIImagePickerController.isSourceTypeAvailable(.camera))

                    PhotosPicker(selection: $photoItem, matching: .images) {
                        Label("Choose from Photos", systemImage: "photo.on.rectangle")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                } else {
                    Button { analyze() } label: {
                        HStack {
                            if isAnalyzing { ProgressView().tint(.white) }
                            Label(isAnalyzing ? "Reading…" : mode.title, systemImage: "sparkles")
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(VemuniPrimaryButtonStyle())
                    .disabled(isAnalyzing)

                    Button("Use a different photo") { image = nil; errorMessage = nil }
                        .disabled(isAnalyzing)
                }

                if let errorMessage {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                }

                Text(mode == .menu
                     ? "Vemuni identifies the language, translates dishes, and explains unfamiliar ingredients."
                     : "Vemuni checks totals, identifies service charges, and helps prevent accidental double tipping.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(20)
        }
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
        guard let image else { return }
        errorMessage = nil
        isAnalyzing = true
        VemuniAnalytics.scanStarted(mode: mode)
        Task {
            do {
                let value = try await ScanService().analyze(image: image, mode: mode)
                await MainActor.run {
                    result = value
                    isAnalyzing = false
                    VemuniAnalytics.scanCompleted(mode: mode, result: value)
                    onSuccessfulScan()
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
            .background(VemuniTheme.espresso.opacity(configuration.isPressed ? 0.8 : 1))
            .clipShape(RoundedRectangle(cornerRadius: 16))
    }
}
