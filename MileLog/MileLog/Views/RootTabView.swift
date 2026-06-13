import SwiftUI

struct RootTabView: View {
    var body: some View {
        TabView {
            RecordTripView()
                .tabItem { Label("Record", systemImage: "record.circle") }

            TripsListView()
                .tabItem { Label("Trips", systemImage: "list.bullet.rectangle") }

            VehiclesView()
                .tabItem { Label("Vehicles", systemImage: "car.2") }

            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
        }
    }
}
