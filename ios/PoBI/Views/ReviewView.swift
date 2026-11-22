import SwiftUI

/// Pending ratings waiting for a person to look at the receipt (D18). Only reviewers
/// listed on the server see this screen; the server checks that too.
struct ReviewView: View {
    @EnvironmentObject private var store: GameStore
    @State private var items: [ServerClient.ReviewItem] = []
    @State private var loading = true
    @State private var error: String?

    var body: some View {
        List {
            if let error {
                Text(error).foregroundStyle(.red)
            }
            ForEach(items) { item in
                NavigationLink {
                    ReviewDetailView(item: item) { decided in
                        items.removeAll { $0.id == decided }
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(store.place(id: item.place_id)?.name ?? "Unknown place").font(.headline)
                        Text(ReviewDetailView.reasons(item)).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .overlay {
            if loading {
                ProgressView()
            } else if items.isEmpty && error == nil {
                ContentUnavailableView("Nothing to review", systemImage: "checkmark.seal",
                                       description: Text("Pending receipts show up here."))
            }
        }
        .navigationTitle("Review receipts")
        .refreshable { await load() }
        .task { await load() }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            items = try await ServerClient.shared.reviewQueue()
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct ReviewDetailView: View {
    @EnvironmentObject private var store: GameStore
    @Environment(\.dismiss) private var dismiss
    let item: ServerClient.ReviewItem
    let onDecided: (UUID) -> Void

    @State private var image: UIImage?
    @State private var note = ""
    @State private var working = false
    @State private var error: String?

    static func reasons(_ item: ServerClient.ReviewItem) -> String {
        var parts: [String] = []
        if item.pending.contains("typedReceipt") { parts.append("Typed in: the app couldn't read it") }
        if item.pending.contains("lookAlike") {
            let why = item.look_alike_reasons.isEmpty ? "" : " (\(item.look_alike_reasons.joined(separator: ", ")))"
            parts.append("Looks like part of another player's order\(why)")
        }
        if item.pending.contains("noFoodPhoto") { parts.append("No food photo, and no check-in within 30 days") }
        return parts.joined(separator: ". ")
    }

    var body: some View {
        let place = store.place(id: item.place_id)
        Form {
            Section("Place") {
                Text(place?.name ?? item.place_id)
                if let place { Text([place.address, place.town].filter { !$0.isEmpty }.joined(separator: ", ")).foregroundStyle(.secondary) }
            }
            Section("Why it's here") {
                Text(Self.reasons(item))
            }
            Section("What the player entered or the app read") {
                if let business = item.typed_business { LabeledContent("Business typed", value: business) }
                if let date = item.typed_date { LabeledContent("Date typed", value: date) }
                if let printed = item.receipt_printed_at { LabeledContent("Printed", value: printed) }
                if let number = item.receipt_number { LabeledContent("Order number", value: number) }
                LabeledContent("Rating", value: "\(item.verdict == "plateIt" ? "Plate It" : "Break It") \(String(repeating: "★", count: item.stars))")
            }
            Section("Receipt photo") {
                if let image {
                    Image(uiImage: image).resizable().scaledToFit()
                } else if item.receipt_path == nil {
                    Text("Not uploaded yet. It arrives the next time the player's app syncs.").foregroundStyle(.secondary)
                } else {
                    ProgressView()
                }
            }
            Section {
                TextField("Note (optional)", text: $note, axis: .vertical)
                Button("Approve: it counts") { decide(true) }
                    .disabled(working)
                Button("Reject: it doesn't count", role: .destructive) { decide(false) }
                    .disabled(working)
                if let error { Text(error).foregroundStyle(.red) }
            } footer: {
                Text("The receipt photo is deleted 30 days after your decision.")
            }
        }
        .navigationTitle("Review")
        .task {
            guard let path = item.receipt_path,
                  let data = try? await ServerClient.shared.receiptImage(at: path) else { return }
            image = UIImage(data: data)
        }
    }

    private func decide(_ approve: Bool) {
        working = true
        error = nil
        Task {
            do {
                let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
                try await ServerClient.shared.review(item.id, approve: approve, note: trimmed.isEmpty ? nil : trimmed)
                onDecided(item.id)
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
            working = false
        }
    }
}
