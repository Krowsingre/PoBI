import SwiftUI

/// Your nickname and friend code, friend requests, and your friends.
struct FriendsView: View {
    @State private var profile: ServerClient.Profile?
    @State private var nickname = ""
    @State private var friends: [ServerClient.Friend] = []
    @State private var code = ""
    @State private var message: String?
    @State private var loading = true

    private var accepted: [ServerClient.Friend] { friends.filter { $0.status == "friend" } }
    private var incoming: [ServerClient.Friend] { friends.filter { $0.status == "incoming" } }
    private var outgoing: [ServerClient.Friend] { friends.filter { $0.status == "outgoing" } }

    var body: some View {
        List {
            Section {
                HStack {
                    TextField("Nickname", text: $nickname)
                        .textInputAutocapitalization(.words)
                        .submitLabel(.done)
                        .onSubmit { Task { await saveNickname() } }
                    if nickname.trimmingCharacters(in: .whitespaces) != (profile?.nickname ?? "") {
                        Button("Save") { Task { await saveNickname() } }
                    }
                }
                if let code = profile?.friend_code {
                    LabeledContent("Your friend code") {
                        Text(code).font(.body.monospaced())
                    }
                    ShareLink(item: "Add me on Plate or Break It. My friend code is \(code).") {
                        Label("Share your friend code", systemImage: "square.and.arrow.up")
                    }
                }
            } header: {
                Text("You")
            } footer: {
                Text("Friends see your nickname and your ratings. Other players only see totals.")
            }

            Section {
                HStack {
                    TextField("Friend code", text: $code)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .font(.body.monospaced())
                    Button("Add") { Task { await add() } }
                        .disabled(code.trimmingCharacters(in: .whitespaces).count < 8)
                }
                if let message {
                    Text(message).font(.footnote).foregroundStyle(.secondary)
                }
            } header: {
                Text("Add a friend")
            } footer: {
                Text("They'll see your request and can accept it. You become friends once they do.")
            }

            if !incoming.isEmpty {
                Section("Asked to be your friend") {
                    ForEach(incoming) { friend in
                        HStack {
                            FriendName(friend: friend)
                            Spacer()
                            Button("Accept") { Task { await answer(friend, accept: true) } }
                                .buttonStyle(.borderedProminent)
                            Button("Decline", role: .destructive) { Task { await answer(friend, accept: false) } }
                                .buttonStyle(.bordered)
                        }
                    }
                }
            }

            Section("Friends") {
                if accepted.isEmpty && !loading {
                    Text("No friends yet. Share your code or add theirs.").foregroundStyle(.secondary)
                }
                ForEach(accepted) { friend in
                    NavigationLink {
                        FriendDetailView(friend: friend)
                    } label: {
                        HStack {
                            FriendName(friend: friend)
                            Spacer()
                            Text("\(friend.ratings ?? 0) rated").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .swipeActions {
                        Button("Remove", role: .destructive) { Task { await remove(friend) } }
                    }
                }
            }

            if !outgoing.isEmpty {
                Section("Waiting for them to accept") {
                    ForEach(outgoing) { friend in
                        HStack {
                            FriendName(friend: friend)
                            Spacer()
                            Button("Cancel") { Task { await remove(friend) } }
                        }
                    }
                }
            }
        }
        .navigationTitle("Friends")
        .refreshable { await load() }
        .task { await load() }
        .overlay {
            if loading && profile == nil { ProgressView() }
        }
    }

    private func load() async {
        defer { loading = false }
        do {
            profile = try await ServerClient.shared.myProfile()
            if nickname.isEmpty { nickname = profile?.nickname ?? "" }
            friends = try await ServerClient.shared.friends()
        } catch {
            message = error.localizedDescription
        }
    }

    private func saveNickname() async {
        do {
            try await ServerClient.shared.setNickname(nickname)
            await load()
        } catch {
            message = error.localizedDescription
        }
    }

    private func add() async {
        do {
            switch try await ServerClient.shared.addFriend(code: code) {
            case "accepted": message = "They'd already asked you, so you're friends now."
            case "already": message = "You're already friends."
            default: message = "Request sent."
            }
            code = ""
            await load()
        } catch {
            message = error.localizedDescription
        }
    }

    private func answer(_ friend: ServerClient.Friend, accept: Bool) async {
        try? await ServerClient.shared.answerFriend(friend.id, accept: accept)
        await load()
    }

    private func remove(_ friend: ServerClient.Friend) async {
        try? await ServerClient.shared.removeFriend(friend.id)
        await load()
    }
}

private struct FriendName: View {
    let friend: ServerClient.Friend

    var body: some View {
        HStack(spacing: 6) {
            if let team = friend.team.flatMap(Team.init(rawValue:)) {
                Circle().fill(team.color).frame(width: 10, height: 10)
            }
            Text(friend.name)
        }
    }
}

/// A friend's ratings: the places they liked and disliked.
struct FriendDetailView: View {
    @EnvironmentObject private var store: GameStore
    let friend: ServerClient.Friend

    @State private var ratings: [ServerClient.FriendRating] = []
    @State private var filter: HistoryScreen.Filter = .all
    @State private var failure: String?
    @State private var loaded = false

    private var shown: [ServerClient.FriendRating] {
        switch filter {
        case .all: return ratings
        case .liked: return ratings.filter { $0.verdict == "plateIt" }.sorted { $0.stars > $1.stars }
        case .disliked: return ratings.filter { $0.verdict == "breakIt" }.sorted { $0.stars > $1.stars }
        }
    }

    var body: some View {
        List {
            if let team = friend.team.flatMap(Team.init(rawValue:)) {
                LabeledContent("Team") {
                    HStack(spacing: 6) {
                        Circle().fill(team.color).frame(width: 10, height: 10)
                        Text(team.name)
                    }
                }
            }
            Section {
                Picker("Show", selection: $filter) {
                    ForEach(HistoryScreen.Filter.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
            }
            Section("\(filter == .all ? "Ratings" : filter.title) (\(shown.count))") {
                if let failure {
                    Text(failure).foregroundStyle(.secondary)
                } else if loaded && shown.isEmpty {
                    Text("Nothing here yet.").foregroundStyle(.secondary)
                }
                ForEach(shown) { rating in
                    if let place = store.place(id: rating.place_id), let verdict = Verdict(rawValue: rating.verdict) {
                        NavigationLink {
                            PlaceDetailView(place: place)
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(place.name).font(.headline)
                                    Text(place.town).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                VerdictBadge(verdict: verdict, stars: rating.stars, compact: true)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle(friend.name)
        .task {
            do {
                ratings = try await ServerClient.shared.friendRatings(friend.id)
            } catch {
                failure = error.localizedDescription
            }
            loaded = true
        }
    }
}

/// What other players think of a place: everyone, your team, your friends, and each friend.
struct PlaceRatingsSection: View {
    @EnvironmentObject private var store: GameStore
    let place: Place

    @State private var ratings: ServerClient.PlaceRatings?
    @State private var failure: String?

    var body: some View {
        Section {
            if let ratings {
                TallyRow(title: "Everyone", tally: ratings.overall)
                TallyRow(title: store.team.map { "\($0.name) (your team)" } ?? "Your team", tally: ratings.team)
                TallyRow(title: "Your friends", tally: ratings.friends)
                ForEach(ratings.friend_ratings) { rating in
                    if let verdict = Verdict(rawValue: rating.verdict) {
                        HStack {
                            if let team = rating.team.flatMap(Team.init(rawValue:)) {
                                Circle().fill(team.color).frame(width: 8, height: 8)
                            }
                            Text(rating.nickname)
                            Spacer()
                            VerdictBadge(verdict: verdict, stars: rating.stars, compact: true)
                        }
                        .padding(.leading, 12)
                    }
                }
            } else if let failure {
                Text(failure).foregroundStyle(.secondary)
            } else if ServerClient.shared.isConfigured {
                ProgressView()
            } else {
                Text("Not connected in this build.").foregroundStyle(.secondary)
            }
        } header: {
            Text("Ratings from players")
        } footer: {
            Text("Score runs from −3 (all three-star Break It) to +3 (all three-star Plate It). Pending ratings aren't included.")
        }
        // Reload after each finished sync too, so a new rating (or one that starts counting) shows up.
        .task(id: "\(store.ratings.count) \(store.syncState)") {
            guard ServerClient.shared.isConfigured else { return }
            do {
                ratings = try await ServerClient.shared.placeRatings(place.id)
                failure = nil
            } catch {
                failure = "Couldn't load other players' ratings."
            }
        }
    }
}

private struct TallyRow: View {
    let title: String
    let tally: ServerClient.Tally

    var body: some View {
        LabeledContent(title) {
            if tally.total == 0 {
                Text("No ratings yet")
            } else {
                HStack(spacing: 10) {
                    Label("\(tally.plate)", systemImage: Verdict.plateIt.symbol).foregroundStyle(Verdict.plateIt.color)
                    Label("\(tally.dislikes)", systemImage: Verdict.breakIt.symbol).foregroundStyle(Verdict.breakIt.color)
                    if let score = tally.score {
                        Text(score.formatted(.number.precision(.fractionLength(1)).sign(strategy: .always())))
                            .monospacedDigit()
                            .fontWeight(.semibold)
                    }
                }
                .labelStyle(.titleAndIcon)
                .font(.callout)
            }
        }
    }
}
