import Foundation
import Combine
import UserNotifications

/// Local notifications for auto-detected trips: ask the user to confirm/edit
/// the classification with three quick-action buttons.
@MainActor
final class NotificationManager: NSObject, ObservableObject, UNUserNotificationCenterDelegate {

    static let shared = NotificationManager()

    /// Set by the app on launch so action taps can route to the store.
    weak var store: Store?
    weak var detectionLog: DetectionLog?

    private let center = UNUserNotificationCenter.current()
    private let classifyCategoryID = "TRIP_CLASSIFY"

    override init() {
        super.init()
        center.delegate = self
        registerCategories()
    }

    // MARK: - Permission

    func requestPermission() async -> Bool {
        do {
            return try await center.requestAuthorization(options: [.alert, .sound, .badge])
        } catch {
            return false
        }
    }

    // MARK: - Categories with quick-classify actions

    private func registerCategories() {
        let business = UNNotificationAction(identifier: "CLASSIFY_BUSINESS",
                                            title: String(localized: "Business"), options: [])
        let commute  = UNNotificationAction(identifier: "CLASSIFY_COMMUTE",
                                            title: String(localized: "Commute"),  options: [])
        let priv     = UNNotificationAction(identifier: "CLASSIFY_PRIVATE",
                                            title: String(localized: "Private"),  options: [])

        let category = UNNotificationCategory(
            identifier: classifyCategoryID,
            actions: [business, commute, priv],
            intentIdentifiers: [],
            options: []
        )
        center.setNotificationCategories([category])
    }

    // MARK: - Sending

    func sendClassifyNotification(for trip: Trip) async {
        let content = UNMutableNotificationContent()
        content.title = String(localized: "Trip ended")
        let distanceText = String(format: "%.1f km", trip.distanceKm)
        content.subtitle = "\(distanceText) · \(trip.type.label)"
        if trip.customerName.isEmpty {
            content.body = String(localized: "Tap to classify, or pick one below.")
        } else {
            content.body = String(localized: "Customer: \(trip.customerName). Tap to confirm or change.")
        }
        content.categoryIdentifier = classifyCategoryID
        content.userInfo = ["tripID": trip.id.uuidString]
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "trip-\(trip.id.uuidString)",
            content: content,
            trigger: nil   // deliver immediately
        )
        try? await center.add(request)
    }

    // MARK: - Handling action taps

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let actionID = response.actionIdentifier
        // Pull the only piece of userInfo we care about into a Sendable String
        // before the @Sendable Task closure, so we don't capture the non-Sendable
        // [AnyHashable: Any] dictionary.
        let tripIDString = response.notification.request.content.userInfo["tripID"] as? String

        Task { @MainActor in
            self.handleAction(actionID: actionID, tripIDString: tripIDString)
            completionHandler()
        }
    }

    /// Show the notification banner even when the app is in the foreground.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    @MainActor
    private func handleAction(actionID: String, tripIDString: String?) {
        guard
            let idString = tripIDString,
            let tripID = UUID(uuidString: idString),
            let store,
            var trip = store.trips.first(where: { $0.id == tripID })
        else { return }

        let newType: TripType?
        switch actionID {
        case "CLASSIFY_BUSINESS": newType = .business
        case "CLASSIFY_COMMUTE":  newType = .commute
        case "CLASSIFY_PRIVATE":  newType = .privateTrip
        default:                  newType = nil
        }

        if let newType {
            trip.type = newType
            store.updateTrip(trip)
            detectionLog?.log("Classified \(idString.prefix(8)) as \(newType.label) via notification")
        }
        // Default action (UNNotificationDefaultActionIdentifier) → app opens to trips list naturally.
    }
}
