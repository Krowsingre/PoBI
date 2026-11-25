import SwiftUI

struct TeamPickerView: View {
    @EnvironmentObject private var store: GameStore

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "fork.knife.circle.fill")
                .font(.system(size: 72))
                .foregroundStyle(Color.accentColor)
            VStack(spacing: 8) {
                Text("Plate or Break It")
                    .font(.largeTitle.bold())
                Text("Rate real places, check in, and win New Jersey for your team.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            }
            Text("Pick your team")
                .font(.headline)
                .padding(.top, 8)
            VStack(spacing: 12) {
                ForEach(Team.allCases) { team in
                    Button {
                        store.team = team
                    } label: {
                        HStack {
                            Circle().fill(team.color).frame(width: 14, height: 14)
                            Text(team.name).font(.body.weight(.semibold))
                            Spacer()
                            Image(systemName: "chevron.right").foregroundStyle(.secondary)
                        }
                        .padding()
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
                    }
                    .buttonStyle(.plain)
                }
            }
            if ServerClient.shared.isConfigured {
                VStack(spacing: 8) {
                    Text("Already playing on another iPhone?")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    AppleSignInButton()
                }
                .padding(.top, 8)
            }
            Spacer()
        }
        .padding()
    }
}
