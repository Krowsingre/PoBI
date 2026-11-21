import PhotosUI
import SwiftUI

/// An original rating: receipt photo, dish photo, Plate It or Break It, one to three stars.
struct RateView: View {
    @EnvironmentObject private var store: GameStore
    @Environment(\.dismiss) private var dismiss
    let place: Place

    @State private var receiptItem: PhotosPickerItem?
    @State private var dishItem: PhotosPickerItem?
    @State private var dishImage: UIImage?
    @State private var verdict: Verdict = .plateIt
    @State private var stars = 2
    @State private var error: String?

    private var canSubmit: Bool { receiptItem != nil && dishItem != nil }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    PhotosPicker(selection: $receiptItem, matching: .images) {
                        Label(
                            receiptItem == nil ? "Add receipt photo" : "Receipt added",
                            systemImage: receiptItem == nil ? "doc.text.viewfinder" : "checkmark.circle.fill"
                        )
                    }
                    PhotosPicker(selection: $dishItem, matching: .images) {
                        Label(
                            dishItem == nil ? "Add dish photo" : "Dish photo added",
                            systemImage: dishItem == nil ? "camera" : "checkmark.circle.fill"
                        )
                    }
                    if let dishImage {
                        Image(uiImage: dishImage)
                            .resizable()
                            .scaledToFit()
                            .frame(maxHeight: 200)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                } header: {
                    Text("Proof of your visit")
                } footer: {
                    Text("The receipt is checked and then deleted. Only the dish photo is kept.")
                }

                Section("Your verdict") {
                    Picker("Verdict", selection: $verdict) {
                        ForEach(Verdict.allCases) { verdict in
                            Text(verdict.title).tag(verdict)
                        }
                    }
                    .pickerStyle(.segmented)

                    Picker("Strength", selection: $stars) {
                        ForEach(1...3, id: \.self) { count in
                            Text(String(repeating: "★", count: count)).tag(count)
                        }
                    }
                    .pickerStyle(.segmented)

                    Label(verdict.meaning(stars: stars), systemImage: verdict.symbol)
                        .foregroundStyle(verdict.color)
                }

                if let error {
                    Section {
                        Text(error).foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle(place.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Submit") { submit() }
                        .disabled(!canSubmit)
                }
            }
            .onChange(of: dishItem) { _, item in
                Task {
                    guard let item,
                          let data = try? await item.loadTransferable(type: Data.self),
                          let image = UIImage(data: data) else { return }
                    dishImage = ImageResizer.downscale(image)
                }
            }
        }
    }

    private func submit() {
        guard canSubmit else {
            error = GameError.missingPhotos.localizedDescription
            return
        }
        do {
            try store.rate(place, verdict: verdict, stars: stars, dishPhoto: dishImage)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
