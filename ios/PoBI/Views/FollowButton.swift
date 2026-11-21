import MapKit
import SwiftUI

/// The map's location arrow. One tap follows you and turns the map to face the way
/// you're facing, like Apple Maps' second tap. Tapping again keeps following with north up.
struct FollowButton: View {
    @Binding var position: MapCameraPosition

    var body: some View {
        Button {
            withAnimation {
                if position.followsUserHeading {
                    position = .userLocation(followsHeading: false, fallback: .automatic)
                } else {
                    position = .userLocation(followsHeading: true, fallback: .automatic)
                }
            }
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .semibold))
                .frame(width: 44, height: 44)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                .shadow(radius: 1)
        }
        .accessibilityLabel(position.followsUserHeading ? "Stop turning the map with you" : "Follow me in the direction I'm facing")
        .padding(12)
    }

    private var symbol: String {
        if position.followsUserHeading { return "location.north.line.fill" }
        if position.followsUserLocation { return "location.fill" }
        return "location"
    }
}
