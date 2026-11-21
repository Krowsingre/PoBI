import CoreLocation
import Foundation

final class LocationManager: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published private(set) var location: CLLocation?
    @Published private(set) var authorization: CLAuthorizationStatus = .notDetermined
    /// Test builds only: a pretend position that replaces GPS for ratings, photos and check-ins.
    @Published private(set) var testLocation: TestLocation?

    struct TestLocation: Equatable {
        let name: String
        let coordinate: CLLocationCoordinate2D

        static func == (a: TestLocation, b: TestLocation) -> Bool {
            a.name == b.name && a.coordinate.latitude == b.coordinate.latitude && a.coordinate.longitude == b.coordinate.longitude
        }
    }

    /// TestFlight, debug and simulator builds can fake their location. App Store builds can't.
    static let testingAllowed: Bool = {
        #if DEBUG || targetEnvironment(simulator)
        return true
        #else
        return Bundle.main.appStoreReceiptURL?.lastPathComponent == "sandboxReceipt"
        #endif
    }()

    private let manager = CLLocationManager()
    private var realLocation: CLLocation?
    private var refreshTimer: Timer?

    override init() {
        super.init()
        authorization = manager.authorizationStatus
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
    }

    func start() {
        // Use the phone's last known position right away while a fresh fix comes in.
        if realLocation == nil, let cached = manager.location {
            realLocation = cached
            publish()
        }
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse, .authorizedAlways:
            manager.startUpdatingLocation()
        default:
            break
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let latest = locations.last
        DispatchQueue.main.async {
            self.realLocation = latest
            self.publish()
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        DispatchQueue.main.async {
            self.authorization = status
            if status == .authorizedWhenInUse || status == .authorizedAlways {
                manager.startUpdatingLocation()
            } else {
                // Without permission, an old position must not count as where you are.
                self.realLocation = nil
                self.publish()
            }
        }
    }

    /// Pretends you're standing at a place. Only works in test builds.
    func setTestLocation(at place: Place) {
        guard Self.testingAllowed else { return }
        testLocation = TestLocation(name: place.name, coordinate: place.coordinate)
        publish()
        // Keep the pretend fix fresh, since check-ins ignore positions older than two minutes.
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.publish()
        }
    }

    func clearTestLocation() {
        testLocation = nil
        refreshTimer?.invalidate()
        refreshTimer = nil
        publish()
    }

    private func publish() {
        if let testLocation {
            location = CLLocation(
                coordinate: testLocation.coordinate, altitude: 0,
                horizontalAccuracy: 5, verticalAccuracy: -1, timestamp: .now
            )
        } else {
            location = realLocation
        }
    }

    func distanceText(to place: Place) -> String? {
        guard let location else { return nil }
        let meters = location.distance(from: place.location)
        let miles = meters / 1609.344
        if miles < 0.1 { return "\(Int(meters.rounded())) m away" }
        return String(format: "%.1f mi away", miles)
    }
}
