import SwiftUI

@main
struct MileLogApp: App {
    @StateObject private var store: Store
    @StateObject private var location: LocationManager
    @StateObject private var supabase: SupabaseService
    @StateObject private var detectionLog: DetectionLog
    @StateObject private var notifications: NotificationManager
    @StateObject private var detector: TripDetector

    init() {
        // Build the dependency graph manually so the detector can hold non-owning
        // references to the store, log, and notification center.
        let store = Store()
        let log = DetectionLog()
        let notifications = NotificationManager.shared
        notifications.store = store
        notifications.detectionLog = log
        let detector = TripDetector(store: store, log: log, notifications: notifications)

        _store = StateObject(wrappedValue: store)
        _location = StateObject(wrappedValue: LocationManager())
        _supabase = StateObject(wrappedValue: SupabaseService())
        _detectionLog = StateObject(wrappedValue: log)
        _notifications = StateObject(wrappedValue: notifications)
        _detector = StateObject(wrappedValue: detector)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .environmentObject(location)
                .environmentObject(supabase)
                .environmentObject(detectionLog)
                .environmentObject(notifications)
                .environmentObject(detector)
        }
    }
}

/// Shows the auth screen until the user signs in, then hands off to the tabbed UI
/// and triggers an initial cloud sync.
struct RootView: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var supabase: SupabaseService

    var body: some View {
        Group {
            if supabase.isAuthenticated {
                RootTabView()
                    .task(id: supabase.userEmail) {
                        await store.initialSync(via: supabase)
                    }
            } else {
                AuthView()
            }
        }
    }
}
