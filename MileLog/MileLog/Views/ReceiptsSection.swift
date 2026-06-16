import SwiftUI
import PhotosUI

/// "Receipts" Form section: list of receipts for a trip + a PhotosPicker to add
/// a new one. Uploads the photo to Supabase Storage and inserts a row.
struct ReceiptsSection: View {
    let tripID: UUID
    @Binding var receipts: [Receipt]

    @EnvironmentObject var supabase: SupabaseService

    @State private var photoItem: PhotosPickerItem?
    @State private var newType: ReceiptType = .fuel
    @State private var newAmount: String = ""
    @State private var isUploading = false
    @State private var errorText: String?

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

            PhotosPicker(selection: $photoItem, matching: .images, photoLibrary: .shared()) {
                if isUploading {
                    HStack { ProgressView(); Text("Uploading…") }
                } else {
                    Label("Add receipt photo", systemImage: "camera.fill")
                }
            }
            .disabled(isUploading)
            .onChange(of: photoItem) { item in
                guard let item else { return }
                Task { await uploadSelectedPhoto(item) }
            }

            if let errorText {
                Text(errorText).font(.footnote).foregroundColor(.red)
            }
        }
    }

    private func uploadSelectedPhoto(_ item: PhotosPickerItem) async {
        errorText = nil
        isUploading = true
        defer { isUploading = false; photoItem = nil }

        guard let data = try? await item.loadTransferable(type: Data.self),
              let image = UIImage(data: data),
              let jpeg = image.jpegData(compressionQuality: 0.75)
        else {
            errorText = "Could not load image."
            return
        }

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
