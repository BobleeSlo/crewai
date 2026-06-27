import SwiftUI

@main
struct MileLogApp: App {
    @StateObject private var store: Store
    @StateObject private var location: LocationManager
    @StateObject private var supabase: SupabaseService
    @StateObject private var detectionLog: DetectionLog
    @StateObject private var notifications: NotificationManager
    @StateObject private var detector: TripDetector
    @StateObject private var appLock = AppLock()

    init() {
        // Build the dependency graph manually so the detector can hold non-owning
        // references to the store, log, and notification center.
        let store = Store()
        let log = DetectionLog()
        let notifications = NotificationManager.shared
        notifications.store = store
        notifications.detectionLog = log
        let detector = TripDetector(store: store, log: log, notifications: notifications)
        let location = LocationManager()
        // Wire the two recorders to each other so they can refuse to overlap.
        location.detector = detector
        detector.manualLocationManager = location
        // Sync the persisted energy preset into the manual recorder
        // (TripDetector reads its own preset from store.settings on each trip).
        location.apply(energyMode: store.settings.energyMode)

        _store = StateObject(wrappedValue: store)
        _location = StateObject(wrappedValue: location)
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
                .environmentObject(appLock)
        }
    }
}

/// Shows the auth screen until the user signs in, then hands off to the tabbed UI
/// and triggers an initial cloud sync. When the optional biometric lock is on,
/// a LockView covers the content until the user passes Face ID / Touch ID.
struct RootView: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var supabase: SupabaseService
    @EnvironmentObject var appLock: AppLock
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            if supabase.isAuthenticated {
                RootTabView()
                    .task(id: supabase.userEmail) {
                        await store.initialSync(via: supabase)
                    }
                    .overlay {
                        if appLock.isLocked {
                            LockView().transition(.opacity)
                        }
                    }
            } else {
                AuthView()
            }
        }
        .animation(.easeInOut(duration: 0.2), value: appLock.isLocked)
        .onChange(of: scenePhase) { _, phase in
            // Re-lock whenever the app is sent to the background, so returning
            // to MileLog requires Face ID again. Only .background triggers it —
            // .inactive happens during the Face ID sheet itself.
            if phase == .background { appLock.lock() }
        }
    }
}
