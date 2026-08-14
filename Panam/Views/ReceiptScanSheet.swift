//
//  ReceiptScanSheet.swift
//  Panam
//

import SwiftUI
import SwiftData
import PhotosUI
import Vision
import UIKit

/// Captures or picks a receipt photo, OCRs it with Vision, and hands the
/// recognized text to the on-device model for parsing into transaction
/// fields — the receipt counterpart to VoiceEntrySheet.
struct ReceiptScanSheet: View {
    @Environment(\.dismiss) private var dismiss

    let onParsed: (ParsedTransaction) -> Void

    @Query(sort: \Category.name) private var categories: [Category]
    @Query(sort: \Account.name) private var accounts: [Account]

    @State private var pickedImage: UIImage?
    @State private var recognizedText = ""
    @State private var isRecognizing = false
    @State private var isParsing = false
    @State private var errorMessage: String?
    @State private var showingCamera = false
    @State private var showingPhotoPicker = false

    private var canUseText: Bool {
        !isRecognizing && !isParsing
            && !recognizedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                if let pickedImage {
                    Image(uiImage: pickedImage)
                        .resizable()
                        .scaledToFit()
                        .frame(maxHeight: 200)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }

                HStack(spacing: 12) {
                    Button {
                        showingCamera = true
                    } label: {
                        Label("Take Photo", systemImage: "camera.fill")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.appPrimary)
                    .disabled(!UIImagePickerController.isSourceTypeAvailable(.camera) || isRecognizing)

                    Button {
                        showingPhotoPicker = true
                    } label: {
                        Label("Choose Photo", systemImage: "photo.on.rectangle")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.appPrimary)
                    .disabled(isRecognizing)
                }

                TextEditor(text: $recognizedText)
                    .font(.footnote.monospaced())
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
                    .frame(minHeight: 140)
                    .overlay(alignment: .topLeading) {
                        if recognizedText.isEmpty && !isRecognizing {
                            Text("Scanned text will appear here — take or choose a receipt photo above. Edit it if anything looks misread.")
                                .font(.footnote)
                                .foregroundStyle(.tertiary)
                                .padding(16)
                                .allowsHitTesting(false)
                        }
                    }
                    .overlay {
                        if isRecognizing {
                            ProgressView("Reading receipt…")
                        }
                    }

                if let errorMessage {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                Button {
                    useText()
                } label: {
                    if isParsing {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                    } else {
                        Text("Use This")
                            .frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(.appPrimary)
                .disabled(!canUseText)
            }
            .padding()
            .navigationTitle("Scan Receipt")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
            }
            .sheet(isPresented: $showingCamera) {
                CameraCapture {
                    showingCamera = false
                    handlePicked($0)
                } onCancel: {
                    showingCamera = false
                }
                .ignoresSafeArea()
            }
            .sheet(isPresented: $showingPhotoPicker) {
                PhotoLibraryPicker {
                    showingPhotoPicker = false
                    handlePicked($0)
                } onCancel: {
                    showingPhotoPicker = false
                }
            }
        }
    }

    private func handlePicked(_ image: UIImage) {
        pickedImage = image
        recognizeText(in: image)
    }

    // MARK: - OCR

    private func recognizeText(in image: UIImage) {
        guard let cgImage = image.cgImage else {
            errorMessage = "Couldn't read that photo."
            return
        }
        errorMessage = nil
        recognizedText = ""
        isRecognizing = true

        let request = VNRecognizeTextRequest { request, error in
            Task { @MainActor in
                isRecognizing = false
                if let error {
                    errorMessage = "Couldn't read text from that photo: \(error.localizedDescription)"
                    return
                }
                let observations = (request.results as? [VNRecognizedTextObservation]) ?? []
                recognizedText = observations
                    .compactMap { $0.topCandidates(1).first?.string }
                    .joined(separator: "\n")
                if recognizedText.isEmpty {
                    errorMessage = "No text found in that photo. Try a clearer, well-lit shot."
                }
            }
        }
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true

        Task.detached {
            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            do {
                try handler.perform([request])
            } catch {
                await MainActor.run {
                    isRecognizing = false
                    errorMessage = "Couldn't read text from that photo: \(error.localizedDescription)"
                }
            }
        }
    }

    // MARK: - Parse

    private func useText() {
        isParsing = true
        errorMessage = nil
        Task {
            do {
                let parsed = try await ReceiptTransactionParser.parse(
                    receiptText: recognizedText,
                    categories: categories,
                    accounts: accounts
                )
                isParsing = false
                onParsed(parsed)
                dismiss()
            } catch {
                isParsing = false
                errorMessage = error.localizedDescription
            }
        }
    }
}

// MARK: - Camera capture (UIImagePickerController)

private struct CameraCapture: UIViewControllerRepresentable {
    let onPick: (UIImage) -> Void
    let onCancel: () -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onPick: onPick, onCancel: onCancel)
    }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let onPick: (UIImage) -> Void
        let onCancel: () -> Void

        init(onPick: @escaping (UIImage) -> Void, onCancel: @escaping () -> Void) {
            self.onPick = onPick
            self.onCancel = onCancel
        }

        func imagePickerController(_ picker: UIImagePickerController,
                                    didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.originalImage] as? UIImage {
                onPick(image)
            } else {
                onCancel()
            }
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            onCancel()
        }
    }
}

// MARK: - Photo library picker (PHPickerViewController)

private struct PhotoLibraryPicker: UIViewControllerRepresentable {
    let onPick: (UIImage) -> Void
    let onCancel: () -> Void

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var configuration = PHPickerConfiguration()
        configuration.filter = .images
        configuration.selectionLimit = 1
        let picker = PHPickerViewController(configuration: configuration)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onPick: onPick, onCancel: onCancel)
    }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let onPick: (UIImage) -> Void
        let onCancel: () -> Void

        init(onPick: @escaping (UIImage) -> Void, onCancel: @escaping () -> Void) {
            self.onPick = onPick
            self.onCancel = onCancel
        }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            guard let provider = results.first?.itemProvider,
                  provider.canLoadObject(ofClass: UIImage.self) else {
                onCancel()
                return
            }
            provider.loadObject(ofClass: UIImage.self) { [onPick, onCancel] object, _ in
                Task { @MainActor in
                    if let image = object as? UIImage {
                        onPick(image)
                    } else {
                        onCancel()
                    }
                }
            }
        }
    }
}

#Preview {
    ReceiptScanSheet { _ in }
        .modelContainer(for: [Account.self, Category.self, Transaction.self], inMemory: true)
}
