import SwiftUI

/// An original rating: receipt photo, dish photo, Plate It or Break It, one to three stars.
/// You can rate from anywhere (D11), but the receipt must be dated within the last 7 days,
/// and both photos are taken with the app's camera (D13). Where food photos aren't allowed,
/// a storefront photo stands in (D16). That photo must be taken at the place, and can be finished
/// into a rating from anywhere within 7 days (D17).
struct RateView: View {
    @EnvironmentObject private var store: GameStore
    @EnvironmentObject private var location: LocationManager
    @Environment(\.dismiss) private var dismiss
    let place: Place

    private enum Shot: String, Identifiable {
        case receipt, dish
        var id: String { rawValue }
    }

    @State private var shooting: Shot?
    @State private var receiptCheck: ReceiptReader.Result?
    @State private var checkingReceipt = false
    /// The food or storefront photo, taken at the place and kept as a draft for 7 days (D17).
    @State private var dishImage: UIImage?
    /// The place doesn't allow food photos, so a photo of the outside or sign stands in (D16).
    @State private var noPhotosAllowed = false
    @State private var verdict: Verdict = .plateIt
    @State private var stars = 2
    @State private var error: String?

    private var receiptOK: Bool {
        if case .valid = receiptCheck { return true }
        return false
    }

    private var canSubmit: Bool { receiptOK && dishImage != nil && store.draft(for: place) != nil && !checkingReceipt }

    private var presence: CheckInStatus { store.presence(at: place, from: location.location) }

    var body: some View {
        NavigationStack {
            Form {
                if !CameraPicker.isAvailable {
                    Section {
                        Text("This device has no camera, so it can't take receipt and dish photos.")
                            .foregroundStyle(.secondary)
                    }
                }

                Section {
                    Button {
                        shooting = .receipt
                    } label: {
                        Label(receiptCheck == nil ? "Take receipt photo" : "Retake receipt photo", systemImage: "doc.text.viewfinder")
                    }
                    .disabled(!CameraPicker.isAvailable || checkingReceipt)
                    receiptStatus
                } header: {
                    Text("Receipt")
                } footer: {
                    Text("The receipt must be from the last 7 days, with the date in the photo. It's read on your phone and never saved.")
                }

                Section {
                    if let draft = store.draft(for: place), let dishImage {
                        Image(uiImage: dishImage)
                            .resizable()
                            .scaledToFit()
                            .frame(maxHeight: 200)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        Label(
                            "\(draft.storefront ? "Storefront" : "Food") photo taken here \(draft.takenAt.formatted(.relative(presentation: .named)))",
                            systemImage: "checkmark.circle.fill"
                        )
                        .foregroundStyle(.green)
                        Button("Retake photo", role: .destructive) {
                            store.discardDraft(for: place)
                            self.dishImage = nil
                        }
                    } else {
                        Toggle("No photos allowed inside", isOn: $noPhotosAllowed)
                        Button {
                            shooting = .dish
                        } label: {
                            Label(
                                noPhotosAllowed ? "Take storefront photo" : "Take food photo",
                                systemImage: noPhotosAllowed ? "storefront" : "camera"
                            )
                        }
                        .disabled(!CameraPicker.isAvailable || presence != .allowed)
                        if let hint = photoHint {
                            Text(hint).font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text(noPhotosAllowed ? "The place" : "Your food")
                } footer: {
                    Text(noPhotosAllowed
                         ? "Photograph the outside or the sign, at the place. The rating counts the same."
                         : "Take this photo at the place. It's kept for 7 days, so you can finish the rating after you leave.")
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
            .onAppear {
                if let draft = store.draft(for: place) {
                    dishImage = store.draftPhoto(for: place)
                    noPhotosAllowed = draft.storefront
                }
            }
            .fullScreenCover(item: $shooting) { shot in
                CameraPicker { image in
                    switch shot {
                    case .receipt: checkReceipt(image)
                    case .dish: saveDish(image)
                    }
                }
                .ignoresSafeArea()
            }
        }
    }

    @ViewBuilder
    private var receiptStatus: some View {
        if checkingReceipt {
            HStack {
                ProgressView()
                Text("Reading the date…").foregroundStyle(.secondary)
            }
        } else if let receiptCheck {
            switch receiptCheck {
            case .valid(let date):
                Label("Dated \(date.formatted(.dateTime.month().day().year()))", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            case .tooOld(let date):
                Label("This receipt is from \(date.formatted(.dateTime.month().day().year())). It must be from the last 7 days.", systemImage: "xmark.circle.fill")
                    .foregroundStyle(.red)
            case .inFuture(let date):
                Label("The date reads as \(date.formatted(.dateTime.month().day().year())), which hasn't happened yet. Retake the photo.", systemImage: "xmark.circle.fill")
                    .foregroundStyle(.red)
            case .noDate:
                Label("Couldn't read a date. Retake the photo with the date in view, flat and well lit.", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
        }
    }

    /// Why the food or storefront photo can't be taken right now, if it can't.
    private var photoHint: String? {
        switch presence {
        case .allowed: return nil
        case .tooFar(let meters):
            let away = Measurement(value: Double(meters), unit: UnitLength.meters)
                .formatted(.measurement(width: .abbreviated, usage: .road))
            return "You're \(away) away. Take this photo at the place, within \(GameStore.checkInReachText)."
        default: return presence.hint
        }
    }

    private func saveDish(_ image: UIImage) {
        let photo = ImageResizer.downscale(image)
        do {
            try store.savePhotoDraft(photo, for: place, storefront: noPhotosAllowed, from: location.location)
            dishImage = photo
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func checkReceipt(_ image: UIImage) {
        receiptCheck = nil
        checkingReceipt = true
        error = nil
        Task {
            let result = await ReceiptReader.check(image)
            receiptCheck = result
            checkingReceipt = false
        }
    }

    private func submit() {
        guard canSubmit else {
            error = GameError.missingPhotos.localizedDescription
            return
        }
        do {
            try store.rate(place, verdict: verdict, stars: stars)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
