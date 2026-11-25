import SwiftUI

/// An original rating: receipt photo, dish photo, Plate It or Break It, one to three stars.
/// You can rate from anywhere (D11), but the receipt must be dated within the last 7 days,
/// and both photos are taken with the app's camera (D13). Where food photos aren't allowed,
/// a storefront photo stands in (D16). That photo must be taken at the place, and can be finished
/// into a rating from anywhere within 7 days (D17). If the app can't read the receipt, the player
/// types it in (D18); if they left without the photo, they can still rate (D19). Both make the
/// rating pending until it's reviewed or, for a missing photo, until they check in there.
struct RateView: View {
    @EnvironmentObject private var store: GameStore
    @EnvironmentObject private var location: LocationManager
    @Environment(\.dismiss) private var dismiss
    let place: Place
    /// A receipt file shared into the app, to use instead of a receipt photo.
    var sharedReceipt: URL? = nil

    private enum Shot: String, Identifiable {
        case receipt, dish
        var id: String { rawValue }
    }

    @State private var shooting: Shot?
    @State private var receiptImage: UIImage?
    @State private var receiptCheck: ReceiptReader.Result?
    @State private var receiptScan: ReceiptReader.Scan?
    @State private var receiptMatch: ReceiptMatcher.Result?
    @State private var checkingReceipt = false
    /// The receipt came as a file (PDF, email, screenshot), so it goes to review before counting.
    @State private var digital = false
    @State private var importing = false
    @State private var checkingPhoto = false
    /// The food or storefront photo, taken at the place and kept as a draft for 7 days (D17).
    @State private var dishImage: UIImage?
    /// The place doesn't allow food photos, so a photo of the outside or sign stands in (D16).
    @State private var noPhotosAllowed = false
    /// Delivered food (Grubhub, DoorDash...): photo anywhere, rating only, no territory.
    @State private var delivery = false
    /// The app couldn't read the receipt, so the player types the business and date (D18).
    @State private var typingReceipt = false
    @State private var typedBusiness = ""
    @State private var typedDate = Date.now
    /// The player left without taking the food or storefront photo (D19).
    @State private var forgotPhoto = false
    @State private var verdict: Verdict = .plateIt
    @State private var stars = 2
    @State private var error: String?

    private var receiptOK: Bool {
        guard case .valid = receiptCheck, case .matches = receiptMatch else { return false }
        return true
    }

    /// Receipt reads that typing can't override: a clear date that's too old, or another branch's receipt.
    private var receiptClearlyWrong: Bool {
        if case .tooOld = receiptCheck { return true }
        if case .otherBranch = receiptMatch { return true }
        return false
    }

    private var canTypeReceipt: Bool {
        receiptImage != nil && receiptCheck != nil && !receiptOK && !receiptClearlyWrong
    }

    private var earliestReceiptDate: Date {
        let calendar = GameStore.calendar
        return calendar.date(byAdding: .day, value: -ReceiptReader.maxAgeDays, to: calendar.startOfDay(for: .now)) ?? .now
    }

    private var typedReceipt: TypedReceipt? {
        guard canTypeReceipt, typingReceipt else { return nil }
        let business = typedBusiness.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !business.isEmpty, typedDate >= earliestReceiptDate, typedDate <= .now else { return nil }
        return TypedReceipt(business: business, date: typedDate)
    }

    /// A delivery photo (taken away from the place) only counts while "Delivery order" is on.
    private var usableDraft: PhotoDraft? {
        guard let draft = store.draft(for: place), draft.delivery != true || delivery else { return nil }
        return draft
    }
    private var hasPhoto: Bool { dishImage != nil && usableDraft != nil }
    private var skippingPhoto: Bool { forgotPhoto && !hasPhoto && !delivery }
    private var willBePending: Bool { typedReceipt != nil || skippingPhoto || digital }

    private var canSubmit: Bool {
        (receiptOK || typedReceipt != nil) && (hasPhoto || skippingPhoto) && !checkingReceipt && !checkingPhoto
    }

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
                    Button {
                        importing = true
                    } label: {
                        Label(digital ? "Choose another digital receipt" : "Use a digital receipt", systemImage: "doc.richtext")
                    }
                    .disabled(checkingReceipt)
                    if digital && receiptCheck != nil {
                        Label("Digital receipt: a reviewer checks it before your rating counts.", systemImage: "hourglass")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    }
                    receiptStatus
                    if canTypeReceipt {
                        Toggle("Can't scan it? Type it in", isOn: $typingReceipt)
                        if typingReceipt {
                            TextField("Business name on the receipt", text: $typedBusiness)
                                .textInputAutocapitalization(.words)
                            DatePicker("Date on the receipt", selection: $typedDate,
                                       in: earliestReceiptDate...Date.now, displayedComponents: .date)
                            Text("Your rating will be pending until someone checks the receipt photo.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("Receipt")
                } footer: {
                    Text("The receipt must be from this place and the last 7 days, with the name and date in view. A digital receipt can be a PDF, a saved email or a screenshot. It's read on your phone, and only kept if your rating needs a review.")
                }

                Section {
                    if let draft = usableDraft, let dishImage {
                        Toggle("Delivery order", isOn: $delivery)
                        Image(uiImage: dishImage)
                            .resizable()
                            .scaledToFit()
                            .frame(maxHeight: 200)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        Label(
                            draft.delivery == true
                                ? "Delivery food photo taken \(draft.takenAt.formatted(.relative(presentation: .named)))"
                                : "\(draft.storefront ? "Storefront" : "Food") photo taken here \(draft.takenAt.formatted(.relative(presentation: .named)))",
                            systemImage: "checkmark.circle.fill"
                        )
                        .foregroundStyle(.green)
                        // The saved photo is only replaced once a new one is taken at the place.
                        Button("Retake photo") { shooting = .dish }
                            .disabled(!CameraPicker.isAvailable || (!delivery && presence != .allowed) || checkingPhoto)
                    } else if delivery {
                        Toggle("Delivery order", isOn: $delivery)
                        Button {
                            shooting = .dish
                        } label: {
                            Label("Take food photo", systemImage: "camera")
                        }
                        .disabled(!CameraPicker.isAvailable || checkingPhoto)
                        if checkingPhoto {
                            HStack {
                                ProgressView()
                                Text("Checking the photo…").foregroundStyle(.secondary)
                            }
                        }
                    } else if forgotPhoto {
                        Toggle("I left without taking it", isOn: $forgotPhoto)
                        Text("Your rating will be pending. It counts once you check in here within \(Rating.revisitDays) days, or once the receipt passes a review.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        Toggle("Delivery order", isOn: $delivery)
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
                        if checkingPhoto {
                            HStack {
                                ProgressView()
                                Text("Checking the photo…").foregroundStyle(.secondary)
                            }
                        }
                        if let hint = photoHint {
                            Text(hint).font(.footnote).foregroundStyle(.secondary)
                        }
                        if presence != .allowed {
                            Toggle("I left without taking it", isOn: $forgotPhoto)
                        }
                    }
                } header: {
                    Text(noPhotosAllowed ? "The place" : "Your food")
                } footer: {
                    Text(delivery
                         ? "For food delivered by Grubhub, DoorDash and the like. Take the photo wherever you're eating. Delivery ratings show in the place's ratings but don't count toward territory."
                         : noPhotosAllowed
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
                    Button(willBePending ? "Submit for review" : "Submit") { submit() }
                        .disabled(!canSubmit)
                }
            }
            .onAppear {
                if let draft = store.draft(for: place) {
                    dishImage = store.draftPhoto(for: place)
                    noPhotosAllowed = draft.storefront
                    delivery = draft.delivery == true
                }
                if typedBusiness.isEmpty { typedBusiness = place.name }
                if let sharedReceipt, receiptCheck == nil, !checkingReceipt { checkDigital(sharedReceipt) }
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: DigitalReceipt.types) { result in
                if case .success(let url) = result { checkDigital(url) }
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
                Text("Reading the receipt…").foregroundStyle(.secondary)
            }
        } else if let receiptCheck {
            matchStatus
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

    @ViewBuilder
    private var matchStatus: some View {
        switch receiptMatch {
        case .matches(let confirmed):
            Label(
                confirmed ? "From this \(place.name)" : "Says \(place.name). Your photo at the place shows which branch.",
                systemImage: "checkmark.circle.fill"
            )
            .foregroundStyle(.green)
        case .otherBranch(let other):
            Label(
                "This receipt is from the \(other.name) at \(other.address.isEmpty ? other.town : other.address + ", " + other.town), not this one.",
                systemImage: "xmark.circle.fill"
            )
            .foregroundStyle(.red)
        case .nameNotFound:
            Label(
                "Couldn't find \(place.name) on this receipt. Retake it with the business name in view.",
                systemImage: "xmark.circle.fill"
            )
            .foregroundStyle(.red)
        case nil:
            EmptyView()
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
        let storefront = noPhotosAllowed && !delivery
        let forDelivery = delivery
        checkingPhoto = true
        error = nil
        Task {
            let ok = await PhotoChecker.looksRight(photo, for: storefront ? .storefront : .food)
            checkingPhoto = false
            guard ok else {
                error = storefront
                    ? "That doesn't look like the outside of a place. Photograph the building or its sign."
                    : "That doesn't look like food or a drink. Take a photo of what you ordered."
                return
            }
            do {
                try store.savePhotoDraft(photo, for: place, storefront: storefront, from: location.location, delivery: forDelivery)
                dishImage = photo
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func checkDigital(_ url: URL) {
        receiptImage = nil
        receiptCheck = nil
        receiptScan = nil
        receiptMatch = nil
        checkingReceipt = true
        error = nil
        Task {
            do {
                let receipt = try await DigitalReceipt.load(url)
                let scan = ReceiptReader.scan(lines: receipt.lines)
                receiptImage = receipt.image
                receiptMatch = ReceiptMatcher.check(lines: scan.lines, place: place, catalog: store.catalog)
                receiptCheck = scan.date
                receiptScan = scan
                digital = true
            } catch {
                self.error = error.localizedDescription
            }
            checkingReceipt = false
        }
    }

    private func checkReceipt(_ image: UIImage) {
        digital = false
        receiptImage = image
        receiptCheck = nil
        receiptScan = nil
        receiptMatch = nil
        checkingReceipt = true
        error = nil
        Task {
            let scan = await ReceiptReader.read(image)
            receiptMatch = ReceiptMatcher.check(lines: scan.lines, place: place, catalog: store.catalog)
            receiptCheck = scan.date
            receiptScan = scan
            checkingReceipt = false
        }
    }

    private func submit() {
        guard canSubmit else {
            error = GameError.missingPhotos.localizedDescription
            return
        }
        do {
            try store.rate(
                place, verdict: verdict, stars: stars,
                receiptPhoto: receiptImage,
                typedReceipt: receiptOK ? nil : typedReceipt,
                withoutPhoto: skippingPhoto,
                digitalReceipt: digital,
                delivery: delivery,
                receiptPrintedAt: receiptScan?.printedAt,
                receiptNumber: receiptScan?.number,
                receiptDate: { if case .valid(let day) = receiptScan?.date { return day } else { return nil } }()
            )
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
