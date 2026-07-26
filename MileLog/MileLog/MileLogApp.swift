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
    /// Set when the user opens a password-reset link from their email —
    /// see `SetNewPasswordView`. Presented over everything else, because
    /// the recovery session it rides on is short-lived.
    @State private var showingSetNewPassword = false
    @State private var recoveryLinkFailed = false
    @State private var launchIsSlow = false

    var body: some View {
        Group {
            if !supabase.didResolveInitialAuth {
                // Neither signed-in nor signed-out yet — showing the
                // sign-in form here (the old behaviour, since
                // `isAuthenticated` starts false) made every cold launch
                // flash the email/password screen (round-7 UX review
                // finding).
                launchState
            } else if supabase.isAuthenticated {
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
        // Receives the password-reset link from the user's email. Without
        // this the "Forgot password?" flow was a dead end — the email was
        // sent, but nothing in the app could complete it (round-6 UX
        // review finding). Requires the `milelog` URL scheme registered on
        // the target; see SupabaseConfig.passwordResetRedirect.
        .onOpenURL { url in
            guard url.scheme == "milelog" else { return }
            Task {
                do {
                    try await supabase.handleRecoveryLink(url)
                    showingSetNewPassword = true
                } catch {
                    // Previously an empty catch: the user tapped the link in
                    // their email, watched MileLog open, and saw the same
                    // sign-in form with zero acknowledgement — no way to
                    // tell an expired link from a broken app from a tap
                    // that didn't register, in the one flow where they're
                    // already anxious about being locked out (round-7 UX
                    // review finding).
                    recoveryLinkFailed = true
                }
            }
        }
        .alert("That reset link didn't work", isPresented: $recoveryLinkFailed) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("It may have expired or already been used. Request a new one with “Forgot password?” below.")
        }
        .sheet(isPresented: $showingSetNewPassword) {
            SetNewPasswordView()
                .environmentObject(supabase)
        }
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

    /// Shown for the brief window between launch and the session restore
    /// resolving. Intentionally minimal — it should read as the app coming
    /// up, not as a screen the user has to do something about.
    private var launchState: some View {
        VStack(spacing: 16) {
            Image(systemName: "car.fill")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(Theme.brandGradient)
                .accessibilityHidden(true)
            ProgressView()
            // Round 7 shipped this as a bare icon and spinner with no text,
            // no timeout, and no way out — and it blocks the whole app. For
            // a returning user with an expired token, the session refresh is
            // a network call, so a bad connection parked them on a
            // contentless spinner for the full URLSession timeout with the
            // sign-in screen no longer reachable behind it. Round 4 already
            // solved this exact shape one level down in the trips list;
            // this state, which blocks strictly more, had none of it
            // (round-8 UX review finding).
            Text("Restoring your session…")
                .font(.subheadline)
                .foregroundColor(.secondary)

            if launchIsSlow {
                VStack(spacing: 10) {
                    Text("This is taking longer than usual — your connection may be slow.")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                    Button("Sign in instead") {
                        // Gives up waiting and shows the interactive screen.
                        // Nothing is lost: a session that resolves later
                        // simply signs the user straight in.
                        supabase.abandonSessionRestore()
                    }
                    .font(.subheadline.weight(.semibold))
                }
                .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
        .animation(.easeInOut(duration: 0.2), value: launchIsSlow)
        .task {
            try? await Task.sleep(for: .seconds(10))
            if !Task.isCancelled { launchIsSlow = true }
        }
    }
}
