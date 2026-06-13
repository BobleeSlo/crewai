import SwiftUI

@main
struct MileLogApp: App {
    @StateObject private var store = Store()
    @StateObject private var location = LocationManager()
    @StateObject private var supabase = SupabaseService()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .environmentObject(location)
                .environmentObject(supabase)
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
