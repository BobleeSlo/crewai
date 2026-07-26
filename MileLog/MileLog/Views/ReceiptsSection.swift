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
    /// Holds the photo between "OCR finished" and "user tapped Save" —
    /// nothing is uploaded/persisted while this is set. Previously the
    /// code went straight from OCR to `upload()` with no step in between
    /// at all, despite this file's own comment claiming "the user can
    /// review the auto-filled amount... before tapping the next action" —
    /// there was no next action to tap; whatever OCR guessed (or failed to
    /// guess) was saved immediately (round-1 UX review finding). For a
    /// record meant for tax/reimbursement, silently trusting an
    /// unconfirmed OCR guess is a real accuracy problem.
    @State private var pendingImage: UIImage?
    @State private var deleteCandidate: Receipt?

    var body: some View {
        Section("Receipts") {
            ForEach(receipts) { receipt in
                ReceiptRow(receipt: receipt)
            }
            .onDelete(perform: deleteReceipts)

            if let pendingImage {
                pendingReceiptReview(pendingImage)
            } else {
                Button {
                    showingSourcePicker = true
                } label: {
                    if isScanning {
                        HStack { ProgressView(); Text("Scanning receipt…") }
                    } else {
                        Label("Add receipt photo", systemImage: "camera.fill")
                    }
                }
                .disabled(isScanning)
            }

            if let errorText {
                Text(errorText).font(.footnote).foregroundColor(.red)
            }
        }
        .confirmationDialog(
            "Delete this receipt?",
            isPresented: Binding(
                get: { deleteCandidate != nil },
                set: { if !$0 { deleteCandidate = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let receipt = deleteCandidate {
                    Task { await confirmDelete(receipt) }
                }
                deleteCandidate = nil
            }
            Button("Cancel", role: .cancel) { deleteCandidate = nil }
        } message: {
            Text("Its photo and amount will be permanently removed from this trip.")
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

    /// The actual review step: photo thumbnail + editable type/amount
    /// (pre-filled from OCR, but the user must explicitly confirm or
    /// discard before anything is saved).
    @ViewBuilder
    private func pendingReceiptReview(_ image: UIImage) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: 56, height: 56)
                .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 10) {
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
                if let scanHint {
                    Label(scanHint, systemImage: "sparkles")
                        .font(.footnote)
                        .foregroundColor(.blue)
                }
            }
        }

        HStack {
            Button(role: .destructive) {
                self.pendingImage = nil
                newAmount = ""
                scanHint = nil
                // A failed "Save receipt" leaves errorText set (by design,
                // so the user can just retry without re-taking the photo)
                // — but if they Discard instead of retrying, that error
                // was orphaned here forever, left on screen with no
                // pending receipt left to explain it (round-2 UX review
                // finding).
                errorText = nil
            } label: {
                Text("Discard")
            }
            Spacer()
            Button {
                Task { await upload(image: image) }
            } label: {
                if isUploading {
                    HStack { ProgressView(); Text("Saving…") }
                } else {
                    Text("Save receipt")
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(isUploading)
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
        newAmount = ""
        defer { capturedImage = nil }

        // Run OCR, then STOP and hand off to the review step
        // (`pendingReceiptReview`) — upload() no longer runs automatically
        // from here. The user must explicitly tap "Save receipt" after
        // seeing (and optionally correcting) what OCR guessed.
        isScanning = true
        if let detected = await ReceiptScanner.extractAmount(from: image) {
            newAmount = String(format: "%.2f", detected)
            scanHint = String(format: "Auto-detected: € %.2f — check it's correct.", detected)
        } else {
            scanHint = "Couldn't read an amount — enter it manually."
        }
        isScanning = false

        pendingImage = image
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
            scanHint = nil
            pendingImage = nil
        } catch {
            // Leave pendingImage/newAmount in place on failure so the user
            // can just tap Save again rather than re-taking the photo.
            // Previously showed the raw SDK error string (round-2 UX
            // review finding) — a network/storage failure is common
            // enough here (photographing a receipt right after a drive,
            // often with weak signal) to deserve plain-language copy.
            errorText = "Couldn't save the receipt — check your connection and try again."
        }
    }

    private func deleteReceipts(at offsets: IndexSet) {
        // Previously local-only ("Supabase row deletion can be added
        // later"), which meant the receipt reappeared the next time the
        // trip was opened, since TripEditor re-pulls on every appearance.
        // It was also the last destructive action in the app with no
        // confirmation, after rounds 1-2 added one everywhere else
        // (round-5 UX review finding).
        guard let first = offsets.first, receipts.indices.contains(first) else { return }
        deleteCandidate = receipts[first]
    }

    private func confirmDelete(_ receipt: Receipt) async {
        do {
            try await supabase.deleteReceipt(receipt)
            receipts.removeAll { $0.id == receipt.id }
        } catch {
            errorText = "Couldn't delete the receipt — check your connection and try again."
        }
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
