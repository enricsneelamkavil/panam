//
//  ReceiptScanSheet.swift
//  Panam
//

import SwiftUI
import SwiftData
import PhotosUI
import Vision
import UIKit

/// Captures or picks a receipt photo, OCRs it with Vision, hands the
/// recognized text to the on-device model for parsing, then — instead of
/// handing back raw text for the user to fix by eye — shows the parsed
/// result as real editable fields (same set/layout as AddEditTransactionView's
/// core form) so corrections use proper controls (a date picker, a decimal
/// keypad, dropdown pickers) instead of hand-editing OCR text and hoping a
/// re-parse gets it right. "Use This" builds the final ParsedTransaction
/// straight from those fields — never re-parses anything.
struct ReceiptScanSheet: View {
    @Environment(\.dismiss) private var dismiss

    let onParsed: (ParsedTransaction) -> Void

    @Query(sort: \Category.name) private var categories: [Category]
    @Query(sort: \Account.name) private var accounts: [Account]

    // MARK: Capture + OCR + parse phase

    @State private var pickedImage: UIImage?
    @State private var isRecognizing = false
    @State private var isParsing = false
    @State private var errorMessage: String?
    @State private var showingCamera = false
    @State private var showingPhotoPicker = false

    // MARK: Review phase — populated once parsing succeeds

    @State private var isReviewing = false
    /// Carried through unedited — ReceiptTransactionParser already defaults
    /// this to "expense" unless the receipt clearly reads as a refund/credit,
    /// and Type isn't one of the fields this review screen exposes.
    @State private var reviewType = "expense"
    @State private var reviewAmount: Double?
    @State private var reviewMerchant = ""
    @State private var reviewDate: Date = .now
    @State private var reviewCategory: Category?
    @State private var reviewAccount: Account?
    @State private var reviewPaymentMethod: PaymentMethod?
    @State private var reviewNote: String?
    @State private var reviewLastFourDigits: String?

    private static let isoDateFormat: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    var body: some View {
        NavigationStack {
            Group {
                if isReviewing {
                    reviewForm
                } else {
                    captureView
                }
            }
            .navigationTitle(isReviewing ? "Review Receipt" : "Scan Receipt")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                if isReviewing {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Use This") {
                            useReviewedFields()
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.appPrimary)
                        .disabled((reviewAmount ?? 0) <= 0)
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

    // MARK: - Capture phase

    private var captureView: some View {
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
                .disabled(!UIImagePickerController.isSourceTypeAvailable(.camera) || isRecognizing || isParsing)

                Button {
                    showingPhotoPicker = true
                } label: {
                    Label("Choose Photo", systemImage: "photo.on.rectangle")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.borderedProminent)
                .tint(.appPrimary)
                .disabled(isRecognizing || isParsing)
            }

            if isRecognizing || isParsing {
                ProgressView(isRecognizing ? "Reading receipt…" : "Extracting details…")
                    .frame(maxWidth: .infinity)
                    .padding(.top, 8)
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Spacer()
        }
        .padding()
    }

    // MARK: - Review phase

    /// Same field set and Section layout as AddEditTransactionView's core
    /// form: Amount; Payment Method; Account + Category + Merchant; Date.
    private var reviewForm: some View {
        Form {
            Section {
                TextField("Amount", value: $reviewAmount, format: .number)
                    .keyboardType(.decimalPad)
            }

            Section {
                Picker("Payment Method", selection: $reviewPaymentMethod) {
                    Text("Not set").tag(nil as PaymentMethod?)
                    ForEach(PaymentMethod.allCases, id: \.self) { method in
                        Text(method.rawValue).tag(method as PaymentMethod?)
                    }
                }
            }

            Section {
                Picker("Account", selection: $reviewAccount) {
                    Text("Select Account").tag(nil as Account?)
                    ForEach(accounts) { account in
                        Text(account.name).tag(account as Account?)
                    }
                }

                Picker("Category", selection: $reviewCategory) {
                    Text("Select Category").tag(nil as Category?)
                    ForEach(categories) { category in
                        Label(category.name, systemImage: category.icon)
                            .tag(category as Category?)
                    }
                }

                TextField("Merchant", text: $reviewMerchant)
            }

            Section {
                DatePicker("Date", selection: $reviewDate, displayedComponents: [.date])
            }

            if let errorMessage {
                Section {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
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
        isRecognizing = true

        let request = VNRecognizeTextRequest { request, error in
            Task { @MainActor in
                isRecognizing = false
                if let error {
                    errorMessage = "Couldn't read text from that photo: \(error.localizedDescription)"
                    return
                }
                let observations = (request.results as? [VNRecognizedTextObservation]) ?? []
                let recognizedText = observations
                    .compactMap { $0.topCandidates(1).first?.string }
                    .joined(separator: "\n")
                guard !recognizedText.isEmpty else {
                    errorMessage = "No text found in that photo. Try a clearer, well-lit shot."
                    return
                }
                parseAndReview(recognizedText)
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

    private func parseAndReview(_ text: String) {
        isParsing = true
        errorMessage = nil
        Task {
            do {
                let parsed = try await ReceiptTransactionParser.parse(
                    receiptText: text,
                    categories: categories,
                    accounts: accounts
                )
                isParsing = false
                populateReview(from: parsed)
            } catch {
                isParsing = false
                errorMessage = error.localizedDescription
            }
        }
    }

    /// Same name-based resolution AddEditTransactionView.apply(_:) uses to
    /// turn a ParsedTransaction's category/account/payment-method name
    /// guesses into real picker selections.
    private func populateReview(from parsed: ParsedTransaction) {
        reviewType = parsed.type
        reviewAmount = parsed.amount
        reviewDate = parsed.resolvedDate
        reviewMerchant = parsed.merchantName ?? ""
        reviewNote = parsed.note
        reviewLastFourDigits = parsed.lastFourDigits

        if let methodName = parsed.paymentMethodName,
           let method = PaymentMethod.allCases.first(where: {
               $0.rawValue.compare(methodName, options: .caseInsensitive) == .orderedSame
           }) {
            reviewPaymentMethod = method
        }

        if let name = parsed.categoryName,
           let match = categories.first(where: {
               $0.name.compare(name, options: .caseInsensitive) == .orderedSame
           }) {
            reviewCategory = match
        }

        let trimmedLastFour = parsed.lastFourDigits?.trimmingCharacters(in: .whitespaces) ?? ""
        if !trimmedLastFour.isEmpty {
            reviewAccount = accounts.first { $0.lastFourDigits == trimmedLastFour }
        } else if let name = parsed.accountName {
            reviewAccount = accounts.first {
                $0.name.compare(name, options: .caseInsensitive) == .orderedSame
            }
        }

        isReviewing = true
    }

    /// Builds the final ParsedTransaction straight from the (possibly
    /// user-edited) review fields — no re-parsing of any text.
    private func useReviewedFields() {
        let trimmedMerchant = reviewMerchant.trimmingCharacters(in: .whitespaces)
        let parsed = ParsedTransaction(
            amount: reviewAmount ?? 0,
            type: reviewType,
            categoryName: reviewCategory?.name,
            accountName: reviewAccount?.name,
            note: reviewNote,
            merchantName: trimmedMerchant.isEmpty ? nil : trimmedMerchant,
            lastFourDigits: reviewLastFourDigits,
            resolvedDateString: Self.isoDateFormat.string(from: reviewDate),
            paymentMethodName: reviewPaymentMethod?.rawValue,
            isGenuineTransaction: true
        )
        onParsed(parsed)
        dismiss()
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
