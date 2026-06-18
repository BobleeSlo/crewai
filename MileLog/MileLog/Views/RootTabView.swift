import SwiftUI

struct RootTabView: View {
    var body: some View {
        TabView {
            RecordTripView()
                .tabItem { Label("Record", systemImage: "circle.dotted") }

            TripsListView()
                .tabItem { Label("Trips", systemImage: "list.bullet.rectangle.fill") }

            VehiclesView()
                .tabItem { Label("Vehicles", systemImage: "car.2.fill") }

            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape.fill") }
        }
        .tint(Theme.accent)
    }
}
