import SwiftUI

/// Central visual identity for MileLog. Keep colors / gradients / spacing
/// here so refreshing the brand is a single-file change.
enum Theme {

    // MARK: - Brand colors

    /// Primary gradient used for the Record-tab hero badge and emphasis surfaces.
    /// Indigo → blue feels professional (business context) while being more
    /// distinctive than plain system blue.
    static let brandStart = Color(red: 0.30, green: 0.27, blue: 0.90)   // ≈ #4D45E5
    static let brandEnd   = Color(red: 0.00, green: 0.48, blue: 1.00)   // ≈ #007AFF

    static let brandGradient = LinearGradient(
        colors: [brandStart, brandEnd],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    /// Tab-bar / global accent. Used by .tint() on the root view.
    static let accent = Color(red: 0.30, green: 0.27, blue: 0.90)

    // MARK: - Trip type palette

    static func tripColor(_ type: TripType) -> Color {
        switch type {
        case .business:    return Color(red: 0.00, green: 0.48, blue: 1.00) // blue
        case .commute:     return Color(red: 1.00, green: 0.58, blue: 0.00) // orange
        case .privateTrip: return Color(red: 0.56, green: 0.56, blue: 0.58) // gray
        }
    }

    // MARK: - Card surfaces

    static let cardBackground = Color(.secondarySystemGroupedBackground)
    static let cardShadow = Color.black.opacity(0.06)
}
