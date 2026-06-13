import SwiftUI

@main
struct MileLogApp: App {
    @StateObject private var store = Store()
    @StateObject private var location = LocationManager()

    var body: some Scene {
        WindowGroup {
            RootTabView()
                .environmentObject(store)
                .environmentObject(location)
        }
    }
}
