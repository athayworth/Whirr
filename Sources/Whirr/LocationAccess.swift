import AppKit
import CoreLocation
import Observation

/// Optional Location access, used for one thing: macOS only tells apps
/// Wi-Fi network names with it, and names let the connection test tell
/// your own network apart from neighbours'. Whirr never asks for a
/// location fix and never stores a network name.
@MainActor
@Observable
final class LocationAccess: NSObject, @preconcurrency CLLocationManagerDelegate {
    enum State { case notAsked, allowed, denied }

    private(set) var state: State = .notAsked
    private let manager = CLLocationManager()

    override init() {
        super.init()
        manager.delegate = self
        state = Self.state(manager.authorizationStatus)
    }

    func request() {
        manager.requestWhenInUseAuthorization()
    }

    func openSystemSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices") {
            NSWorkspace.shared.open(url)
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        state = Self.state(manager.authorizationStatus)
    }

    private static func state(_ status: CLAuthorizationStatus) -> State {
        switch status {
        case .authorizedAlways, .authorizedWhenInUse: return .allowed
        case .denied, .restricted: return .denied
        default: return .notAsked
        }
    }
}
