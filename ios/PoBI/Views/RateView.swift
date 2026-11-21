import SwiftUI

/// An original rating: receipt photo, dish photo, Plate It or Break It, one to three stars.
/// You can rate from anywhere (D11), but the receipt must be dated within the last 7 days,
/// and both photos are taken with the app's camera (D13).
struct RateView: View {
    @EnvironmentObject private var store: GameStore
    @Environment(\.dismiss) private var dismiss
    let place: Place

    private enum Shot: String, Identifiable {
        case receipt, dish
        var id: String { rawValue }
    }

    @State private var shooting: Shot?
    @State private var receiptCheck: ReceiptReader.Result?
    @State private var checkingReceipt = false
    @State private var dishImage: UIImage?
    @State private var verdict: Verdict = .plateIt
    @State private var stars = 2
    @State private var error: String?

    private var receiptOK: Bool {
        if case .valid = receiptCheck { return true }
        return false
    }

    private var canSubmit: Bool { receiptOK && dishImage != nil && !checkingReceipt }

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

                Section("Your food") {
                    Button {
                        shooting = .dish
                    } label: {
                        Label(dishImage == nil ? "Take food photo" : "Retake food photo", systemImage: "camera")
                    }
                    .disabled(!CameraPicker.isAvailable)
                    if let dishImage {
                        Image(uiImage: dishImage)
                            .resizable()
                            .scaledToFit()
                            .frame(maxHeight: 200)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
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
            .fullScreenCover(item: $shooting) { shot in
                CameraPicker { image in
                    switch shot {
                    case .receipt: checkReceipt(image)
                    case .dish: dishImage = ImageResizer.downscale(image)
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
        guard canSubmit, let dishImage else {
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
