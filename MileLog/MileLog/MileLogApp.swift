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
        notifications.detector = detector
        store.detector = detector
        store.detectionLog = log
        let location = LocationManager()
        // Wire the two recorders to each other so they can refuse to overlap.
        location.detector = detector
        location.detectionLog = log
        detector.manualLocationManager = location
        // Sync the persisted energy preset into the manual recorder
        // (TripDetector reads its own preset from store.settings on each trip).
        location.apply(energyMode: store.settings.energyMode)

        let supabase = SupabaseService()
        // Lets signOut() discard an in-progress trip/recording the instant
        // it happens, rather than only reacting once a later sign-in's sync
        // gets around to it — see SupabaseService's own property comments.
        supabase.detector = detector
        supabase.manualLocation = location

        _store = StateObject(wrappedValue: store)
        _location = StateObject(wrappedValue: location)
        _supabase = StateObject(wrappedValue: supabase)
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
                        } else if appLock.enabled && scenePhase != .active {
                            // Bridges the gap before `.background`'s lock()
                            // call — see PrivacyCurtainView's doc comment.
                            PrivacyCurtainView().transition(.opacity)
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
            // applyAutomaticLocks() previously only ran at Store.init() (cold
            // launch) or the manual "Apply locks now" button — a trip could
            // sit editable well past its configured lockAfterDays threshold
            // for as long as the process stays alive across background
            // sessions without a full relaunch, which this app's own
            // location-tracking design makes routine. Also re-running it on
            // every foreground narrows the window for the stale-@State-
            // detail-screen scenario `updateTrip` now defends against
            // (round-11 adversarial review finding).
            if phase == .active { store.applyAutomaticLocks() }
        }
    }
}
