import SwiftUI
import PhotosUI

/// "Receipts" Form section: list of receipts for a trip + a single
/// "Add receipt photo" affordance that lets the user choose between
/// **camera** and **library**, then runs on-device OCR (Vision) to
/// auto-fill the amount field from the scanned receipt.
struct ReceiptsSection: View {
    let tripID: UUID
    @Binding var receipts: [Receipt]

    @EnvironmentObject var supabase: SupabaseService

    @State private var photoItem: PhotosPickerItem?
    @State private var capturedImage: UIImage?
    @State private var newType: ReceiptType = .fuel
    @State private var newAmount: String = ""
    @State private var isUploading = false
    @State private var isScanning = false
    @State private var errorText: String?
    @State private var scanHint: String?
    @State private var showingSourcePicker = false
    @State private var showingCamera = false
    @State private var showingPhotosPicker = false

    var body: some View {
        Section("Receipts") {
            ForEach(receipts) { receipt in
                ReceiptRow(receipt: receipt)
            }
            .onDelete(perform: deleteReceipts)

            Picker("Type", selection: $newType) {
                ForEach(ReceiptType.allCases) { Text($0.label).tag($0) }
            }

            HStack {
                Text("Amount")
                Spacer()
                TextField("0.00", text: $newAmount)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                Text("€").foregroundColor(.secondary)
            }

            Button {
                showingSourcePicker = true
            } label: {
                if isUploading {
                    HStack { ProgressView(); Text("Uploading…") }
                } else if isScanning {
                    HStack { ProgressView(); Text("Scanning receipt…") }
                } else {
                    Label("Add receipt photo", systemImage: "camera.fill")
                }
            }
            .disabled(isUploading || isScanning)

            if let scanHint {
                Label(scanHint, systemImage: "sparkles")
                    .font(.footnote)
                    .foregroundColor(.blue)
            }

            if let errorText {
                Text(errorText).font(.footnote).foregroundColor(.red)
            }
        }
        .confirmationDialog("Add receipt photo", isPresented: $showingSourcePicker) {
            Button {
                showingCamera = true
            } label: {
                Label("Take photo", systemImage: "camera")
            }
            Button {
                showingPhotosPicker = true
            } label: {
                Label("Choose from library", systemImage: "photo.on.rectangle")
            }
            Button("Cancel", role: .cancel) {}
        }
        .sheet(isPresented: $showingCamera) {
            CameraImagePicker(image: $capturedImage)
                .ignoresSafeArea()
        }
        .photosPicker(isPresented: $showingPhotosPicker,
                      selection: $photoItem,
                      matching: .images,
                      photoLibrary: .shared())
        .onChange(of: photoItem) { _, newItem in
            guard let newItem else { return }
            Task { await handleLibraryPick(newItem) }
        }
        .onChange(of: capturedImage) { _, newImage in
            guard let newImage else { return }
            Task { await handleImage(newImage) }
        }
    }

    // MARK: - Photo handling

    private func handleLibraryPick(_ item: PhotosPickerItem) async {
        defer { photoItem = nil }
        guard let data = try? await item.loadTransferable(type: Data.self),
              let image = UIImage(data: data) else {
            errorText = "Could not load image."
            return
        }
        await handleImage(image)
    }

    private func handleImage(_ image: UIImage) async {
        errorText = nil
        scanHint = nil
        defer { capturedImage = nil }

        // 1. Run OCR first — the user can review the auto-filled amount
        //    in the editor before tapping the next action.
        isScanning = true
        if let detected = await ReceiptScanner.extractAmount(from: image) {
            newAmount = String(format: "%.2f", detected)
            scanHint = String(format: "Auto-detected: € %.2f", detected)
        } else {
            scanHint = "Couldn't read an amount — enter it manually."
        }
        isScanning = false

        // 2. Upload + persist.
        await upload(image: image)
    }

    private func upload(image: UIImage) async {
        guard let jpeg = image.jpegData(compressionQuality: 0.75) else {
            errorText = "Could not encode image."
            return
        }
        isUploading = true
        defer { isUploading = false }

        let receipt = Receipt(
            type: newType,
            amountEur: Double(newAmount.replacingOccurrences(of: ",", with: ".")),
            vendor: "",
            photoPath: "",
            date: Date(),
            notes: ""
        )

        do {
            let fileName = "\(receipt.id.uuidString).jpg"
            let path = try await supabase.uploadReceiptPhoto(jpeg, fileName: fileName)
            var saved = receipt
            saved.photoPath = path
            try await supabase.pushReceipt(saved, tripID: tripID)
            receipts.append(saved)
            newAmount = ""
            // Keep scanHint visible briefly so the user sees the OCR result.
        } catch {
            errorText = "Upload failed: \(error.localizedDescription)"
        }
    }

    private func deleteReceipts(at offsets: IndexSet) {
        // Soft delete locally; Supabase row deletion can be added later.
        receipts.remove(atOffsets: offsets)
    }
}

private struct ReceiptRow: View {
    let receipt: Receipt
    @EnvironmentObject var supabase: SupabaseService

    @State private var image: UIImage?

    var body: some View {
        HStack(spacing: 12) {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 48, height: 48)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            } else {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.secondary.opacity(0.2))
                    .frame(width: 48, height: 48)
                    .overlay(Image(systemName: "photo").foregroundColor(.secondary))
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(receipt.type.label).font(.subheadline.bold())
                if let amount = receipt.amountEur {
                    Text(String(format: "€ %.2f", amount))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                if let date = receipt.date {
                    Text(date.formatted(date: .abbreviated, time: .omitted))
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
            Spacer()
        }
        .task {
            guard image == nil, !receipt.photoPath.isEmpty else { return }
            if let data = try? await supabase.downloadReceiptPhoto(path: receipt.photoPath) {
                image = UIImage(data: data)
            }
        }
    }
}
