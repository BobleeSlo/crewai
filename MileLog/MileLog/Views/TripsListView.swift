import SwiftUI

struct TripsListView: View {
    @EnvironmentObject var store: Store
    /// Swipe-to-delete on a trip previously deleted immediately with zero
    /// confirmation — unlike VehiclesView's identical gesture, which got a
    /// confirmation dialog specifically because vehicles deserved that
    /// protection. A trip is the app's actual core record (GPS-measured,
    /// possibly already-classified for tax purposes) and is strictly
    /// harder to recreate than a vehicle entry, yet had LESS protection
    /// (round-2 UX review finding).
    @State private var deleteCandidate: Trip?
    /// Set once the syncing state has been on screen long enough that a
    /// bare spinner stops being reassuring — see `syncingState`.
    @State private var syncIsSlow = false

    var body: some View {
        NavigationStack {
            Group {
                if store.trips.isEmpty && store.tripsSyncFailed && !store.isSyncing {
                    syncFailedState
                } else if store.trips.isEmpty && store.isSyncing {
                    // A returning user restoring an account with months of
                    // history on a new phone, on a slow connection, would
                    // otherwise see the confident "No trips yet" empty
                    // state below while their actual history was still
                    // downloading — an alarming false signal for what's
                    // meant to be a defensible tax record (round-3 UX
                    // review finding).
                    syncingState
                } else if store.trips.isEmpty {
                    emptyState
                } else {
                    tripList
                }
            }
            .navigationTitle("Trips")
            .navigationBarTitleDisplayMode(.large)
        }
    }

    // MARK: - List

    private var tripList: some View {
        List {
            ForEach(store.monthSections, id: \.self) { section in
                Section {
                    ForEach(section.trips) { trip in
                        NavigationLink {
                            TripDetailView(trip: trip)
                        } label: {
                            TripCard(trip: trip)
                        }
                        .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                        // A locked trip is the exact record the locking
                        // feature exists to make tamper-evident for a tax
                        // audit — swipe-to-delete must not be able to
                        // remove one outright with no trace (round-7
                        // adversarial review finding).
                        .deleteDisabled(trip.isLocked)
                    }
                    .onDelete { offsets in
                        if let first = offsets.first {
                            deleteCandidate = section.trips[first]
                        }
                    }
                } header: {
                    MonthSectionHeader(section: section)
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(backgroundWash)
        // The app otherwise syncs exactly once, on sign-in — there was no
        // way at all to re-pull after a failure or to pick up changes made
        // on another device, short of force-quitting (round-5 UX review
        // finding).
        .refreshable { await store.retrySync() }
        .confirmationDialog(
            "Delete this trip?",
            isPresented: Binding(
                get: { deleteCandidate != nil },
                set: { if !$0 { deleteCandidate = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                // Re-fetch the LIVE trip by id rather than trusting the
                // snapshot captured at swipe time — `Store.deleteTrips`
                // refuses to delete a locked trip, but only by checking
                // whatever `Trip` value it's actually handed. If the trip
                // crossed the lockAfterDays threshold while this dialog
                // stayed open (e.g. the app was backgrounded/foregrounded,
                // re-running applyAutomaticLocks), the stale snapshot still
                // read isLocked == false, defeating the exact "refuse to
                // delete a locked trip" guarantee this same confirmation
                // exists to respect (round-3 UX review finding).
                if let candidate = deleteCandidate,
                   let live = store.trips.first(where: { $0.id == candidate.id }) {
                    store.deleteTrips([live], at: IndexSet(integer: 0))
                }
                deleteCandidate = nil
            }
            Button("Cancel", role: .cancel) { deleteCandidate = nil }
        } message: {
            Text("Its mileage and any classification will be permanently removed. This can't be undone.")
        }
    }

    private var backgroundWash: some View {
        LinearGradient(
            colors: [
                Theme.brandStart.opacity(0.05),
                Color(.systemBackground)
            ],
            startPoint: .top,
            endPoint: .center
        )
        .ignoresSafeArea()
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(Theme.brandGradient)
                    .frame(width: 120, height: 120)
                    .opacity(0.12)
                Image(systemName: "car.fill")
                    .font(.system(size: 56, weight: .light))
                    .foregroundStyle(Theme.brandGradient)
            }
            VStack(spacing: 6) {
                Text("No trips yet")
                    .font(.title3.bold())
                Text("Record your first trip from the Record tab — or pair your car's Bluetooth in Vehicles so auto-detect handles it for you.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(backgroundWash)
    }

    // MARK: - Sync-failed state

    /// Shown instead of the "No trips yet" empty state when the last sync
    /// couldn't reach the cloud — telling a user with years of records to
    /// "record your first trip" is the single most alarming thing this
    /// screen could say (round-5 UX review finding).
    private var syncFailedState: some View {
        VStack(spacing: 16) {
            Image(systemName: "icloud.slash")
                .font(.system(size: 48, weight: .light))
                .foregroundColor(.secondary)
            VStack(spacing: 6) {
                Text("Couldn't load your trips")
                    .font(.title3.bold())
                Text("We couldn't reach your saved trips. They're safe — check your connection and try again.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }
            Button {
                Task { await store.retrySync() }
            } label: {
                Label("Try again", systemImage: "arrow.clockwise")
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                    .background(Theme.brandGradient)
                    .clipShape(Capsule())
            }
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(backgroundWash)
    }

    // MARK: - Syncing state

    private var syncingState: some View {
        VStack(spacing: 16) {
            ProgressView()
                .controlSize(.large)
            Text("Syncing your trips…")
                .font(.subheadline)
                .foregroundColor(.secondary)
            // A slow-but-alive connection (very plausible for exactly the
            // user this state exists for — setting up a new phone, often
            // travelling) could otherwise leave a bare spinner running for
            // a long, indeterminate time with nothing acknowledging it
            // (round-4 UX review finding). This doesn't cancel anything;
            // the sync keeps retrying in the background.
            if syncIsSlow {
                Text("This is taking longer than usual — your connection may be slow. Your trips are safe and will appear once it finishes.")
                    .font(.footnote)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(backgroundWash)
        .task {
            syncIsSlow = false
            try? await Task.sleep(for: .seconds(12))
            if !Task.isCancelled { syncIsSlow = true }
        }
    }
}

// MARK: - Trip card row -----------------------------------------------------

struct TripCard: View {
    let trip: Trip
    @EnvironmentObject var store: Store

    var body: some View {
        HStack(spacing: 12) {
            // Colored left edge — instant visual signal for trip type
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(Theme.tripColor(trip.type))
                .frame(width: 4)

            VStack(alignment: .leading, spacing: 6) {
                // Title row: customer (or fallback to type) + lock badge
                HStack(spacing: 6) {
                    Text(titleText)
                        .font(.headline)
                        .lineLimit(1)
                    if trip.isLocked {
                        Image(systemName: "lock.fill")
                            .font(.caption2)
                            .foregroundColor(.orange)
                    }
                    Spacer(minLength: 4)
                    TripTypeChip(type: trip.type, compact: true)
                }

                // Route row: From → To
                if !trip.startAddress.isEmpty || !trip.endAddress.isEmpty {
                    HStack(spacing: 4) {
                        Text(trip.startAddress.isEmpty ? "—" : trip.startAddress)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Image(systemName: "arrow.right")
                            .font(.caption2.weight(.semibold))
                            .foregroundColor(.secondary)
                        Text(trip.endAddress.isEmpty ? "—" : trip.endAddress)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    .font(.caption)
                    .foregroundColor(.secondary)
                }

                // Meta row: date · vehicle · km
                HStack(spacing: 6) {
                    Text(trip.startedAt, format: .dateTime.day().month().year())
                    Text("·")
                    Text(store.vehicleName(trip.vehicleID))
                        .lineLimit(1)
                    Spacer()
                    Text(String(format: "%.1f km", trip.distanceKm))
                        .font(.subheadline.weight(.semibold).monospacedDigit())
                        .foregroundColor(.primary)
                }
                .font(.caption2)
                .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .background(Theme.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .shadow(color: Theme.cardShadow, radius: 4, x: 0, y: 1)
    }

    private var titleText: String {
        if !trip.customerName.isEmpty { return trip.customerName }
        if !trip.purpose.isEmpty      { return trip.purpose }
        return trip.type.label
    }
}

// MARK: - Month section header ---------------------------------------------

struct MonthSectionHeader: View {
    let section: MonthSection

    var body: some View {
        HStack {
            Text(section.title)
                .font(.headline)
                .foregroundColor(.primary)
            Spacer()
            Text(section.summary)
                .font(.caption.weight(.semibold))
                .foregroundColor(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(
                    Capsule().fill(Theme.brandGradient)
                )
        }
        .textCase(nil)
        .padding(.vertical, 4)
    }
}
