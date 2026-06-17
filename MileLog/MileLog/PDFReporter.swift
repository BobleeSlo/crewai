import Foundation
import UIKit

/// PDF reports for bookkeeping and the SI "potni nalog" logbook.
///
/// Two reports:
///  • `generateMonthlyOwnCar` — for monthly own-car reimbursement claims.
///    Filters to vehicles of type .own, splits business vs commute totals,
///    omits private trips and any company-car trips.
///  • `generateCompanyCarLogbook` — Slovenian "potni nalog" layout for a
///    chosen company car + month. Auto-fills date / times / from / to / km,
///    leaves odometer-start, odometer-end and signature columns blank for
///    handwriting.
enum PDFReporter {

    private static let pageSize = CGSize(width: 595, height: 842)      // A4 @ 72dpi
    private static let margin: CGFloat = 36
    private static let rowHeight: CGFloat = 22
    private static let headerHeight: CGFloat = 24

    struct Result {
        let url: URL
        let tripCount: Int
        /// Headline number for the share-link label (business km for the monthly,
        /// total km for the logbook).
        let headlineKm: Double
    }

    // MARK: - Candidate filters (callable by the selection screen) ---------

    /// Trips eligible for the own-car monthly reimbursement report:
    /// vehicles of type .own, business or commute, within the chosen month.
    static func ownCarCandidates(
        trips: [Trip],
        vehicleLookup: (UUID) -> Vehicle?,
        year: Int, month: Int
    ) -> [Trip] {
        let cal = Calendar.current
        return trips
            .filter {
                let c = cal.dateComponents([.year, .month], from: $0.startedAt)
                guard c.year == year && c.month == month else { return false }
                guard vehicleLookup($0.vehicleID)?.type == .own else { return false }
                return $0.type == .business || $0.type == .commute
            }
            .sorted { $0.startedAt < $1.startedAt }
    }

    /// Trips eligible for the company-car potni nalog: a single chosen
    /// company vehicle, within the chosen month.
    static func companyLogbookCandidates(
        trips: [Trip],
        vehicle: Vehicle,
        year: Int, month: Int
    ) -> [Trip] {
        let cal = Calendar.current
        return trips
            .filter {
                let c = cal.dateComponents([.year, .month], from: $0.startedAt)
                return c.year == year && c.month == month && $0.vehicleID == vehicle.id
            }
            .sorted { $0.startedAt < $1.startedAt }
    }

    // MARK: - Monthly own-car report ----------------------------------------

    private static let ownCarColumnWidths: [CGFloat] = [60, 80, 70, 100, 100, 50, 60]
    private static var ownCarColumnTitles: [String] {
        [
            String(localized: "Date"),
            String(localized: "Vehicle"),
            String(localized: "Type"),
            String(localized: "From"),
            String(localized: "To"),
            "km",
            "€"
        ]
    }

    /// Generates the monthly own-car PDF for the already-filtered `trips`.
    /// The caller (typically the report-selection screen) decides which
    /// candidate trips are included.
    static func generateMonthlyOwnCar(
        trips: [Trip],
        vehicleLookup: (UUID) -> Vehicle?,
        businessRate: Double,
        commuteRate: Double,
        year: Int,
        month: Int
    ) -> Result? {
        let monthly = trips.sorted { $0.startedAt < $1.startedAt }

        let businessTrips = monthly.filter { $0.type == .business }
        let commuteTrips = monthly.filter { $0.type == .commute }

        let businessKm = businessTrips.reduce(0) { $0 + $1.distanceKm }
        let commuteKm  = commuteTrips.reduce(0) { $0 + $1.distanceKm }
        let businessEur = businessKm * businessRate
        let commuteEur  = commuteKm * commuteRate

        let monthLabel = monthName(year: year, month: month)

        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(origin: .zero, size: pageSize))
        let data = renderer.pdfData { ctx in
            var rowIndex = 0
            var page = 1
            ctx.beginPage()
            drawMonthlyHeader(
                month: monthLabel,
                tripCount: monthly.count,
                businessKm: businessKm, businessEur: businessEur,
                commuteKm: commuteKm, commuteEur: commuteEur
            )
            var y = headerTopOffset(extra: 14)
            drawTableHeader(titles: ownCarColumnTitles, widths: ownCarColumnWidths, at: y)
            y += headerHeight

            for trip in monthly {
                if y + rowHeight > pageSize.height - margin {
                    ctx.beginPage()
                    page += 1
                    drawPageFooter(page: page, month: monthLabel)
                    y = margin
                    drawTableHeader(titles: ownCarColumnTitles, widths: ownCarColumnWidths, at: y)
                    y += headerHeight
                }
                drawOwnCarRow(
                    trip: trip,
                    vehicle: vehicleLookup(trip.vehicleID),
                    businessRate: businessRate,
                    commuteRate: commuteRate,
                    at: y,
                    zebra: rowIndex.isMultiple(of: 2)
                )
                y += rowHeight
                rowIndex += 1
            }

            if monthly.isEmpty {
                let note = String(localized: "No trips recorded for \(monthLabel).")
                note.draw(at: CGPoint(x: margin, y: y + 8),
                          withAttributes: [
                            .font: UIFont.italicSystemFont(ofSize: 11),
                            .foregroundColor: UIColor.gray
                          ])
            }
        }

        let filename = String(format: "MileLog-OwnCar-%04d-%02d.pdf", year, month)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
        try? data.write(to: url)
        return Result(url: url, tripCount: monthly.count, headlineKm: businessKm + commuteKm)
    }

    // MARK: - Company car logbook (Slovenian "potni nalog") -----------------
    //
    // Columns mirror a standard SI paper logbook so the user can transcribe.
    // | # | Datum | Ura od | Ura do | Od | Do | Namen | km zač. | km kon. | km |
    // The km-start / km-end columns are intentionally left blank for the
    // user to fill in by hand from the actual car odometer.

    private static let logbookColumnWidths: [CGFloat] = [22, 56, 42, 42, 80, 80, 80, 50, 50, 40]
    private static var logbookColumnTitles: [String] {
        ["#", "Datum", "Ura od", "Ura do", "Od", "Do", "Namen", "km zač.", "km kon.", "km"]
    }

    /// Generates the potni nalog for the already-filtered `trips`. Caller
    /// is responsible for filtering to a single vehicle + period.
    static func generateCompanyCarLogbook(
        trips: [Trip],
        vehicle: Vehicle,
        year: Int,
        month: Int
    ) -> Result? {
        let monthly = trips.sorted { $0.startedAt < $1.startedAt }

        let totalKm = monthly.reduce(0) { $0 + $1.distanceKm }
        let monthLabel = monthName(year: year, month: month)

        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(origin: .zero, size: pageSize))
        let data = renderer.pdfData { ctx in
            var page = 1
            ctx.beginPage()
            drawLogbookHeader(vehicle: vehicle, month: monthLabel, totalKm: totalKm, tripCount: monthly.count)
            var y = headerTopOffset(extra: 32)
            drawTableHeader(titles: logbookColumnTitles, widths: logbookColumnWidths, at: y)
            y += headerHeight

            for (index, trip) in monthly.enumerated() {
                if y + rowHeight > pageSize.height - 120 {       // leave room for signature
                    drawSignatureBlock(at: pageSize.height - 100)
                    ctx.beginPage()
                    page += 1
                    drawPageFooter(page: page, month: monthLabel)
                    y = margin
                    drawTableHeader(titles: logbookColumnTitles, widths: logbookColumnWidths, at: y)
                    y += headerHeight
                }
                drawLogbookRow(index: index + 1, trip: trip, at: y, zebra: index.isMultiple(of: 2))
                y += rowHeight
            }

            if monthly.isEmpty {
                let note = String(localized: "No trips recorded for \(monthLabel).")
                note.draw(at: CGPoint(x: margin, y: y + 8),
                          withAttributes: [
                            .font: UIFont.italicSystemFont(ofSize: 11),
                            .foregroundColor: UIColor.gray
                          ])
            }
            drawSignatureBlock(at: pageSize.height - 100)
        }

        let filename = String(format: "MileLog-Logbook-%@-%04d-%02d.pdf",
                              vehicle.licensePlate.isEmpty ? vehicle.name : vehicle.licensePlate,
                              year, month)
            .replacingOccurrences(of: " ", with: "-")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
        try? data.write(to: url)
        return Result(url: url, tripCount: monthly.count, headlineKm: totalKm)
    }

    // MARK: - Header / footer drawing ---------------------------------------

    private static func drawMonthlyHeader(
        month: String, tripCount: Int,
        businessKm: Double, businessEur: Double,
        commuteKm: Double, commuteEur: Double
    ) {
        let titleAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 22, weight: .bold),
            .foregroundColor: UIColor.black
        ]
        let subAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 11),
            .foregroundColor: UIColor.darkGray
        ]
        let totalAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: UIColor.black
        ]

        String(localized: "MileLog · \(month)").draw(
            at: CGPoint(x: margin, y: margin),
            withAttributes: titleAttrs
        )

        let stamp = DateFormatter.localizedString(from: Date(), dateStyle: .medium, timeStyle: .short)
        let _ = tripCount  // referenced via summary line below
        String(localized: "Generated \(stamp)").draw(
            at: CGPoint(x: margin, y: margin + 30),
            withAttributes: subAttrs
        )

        let summary = String(format: "%d trips · %.1f km total",
                             tripCount, businessKm + commuteKm)
        summary.draw(at: CGPoint(x: margin, y: margin + 48), withAttributes: subAttrs)

        let business = String(format: "Business · %.1f km · € %.2f", businessKm, businessEur)
        business.draw(at: CGPoint(x: margin, y: margin + 66), withAttributes: totalAttrs)

        let commute = String(format: "Commute  · %.1f km · € %.2f", commuteKm, commuteEur)
        commute.draw(at: CGPoint(x: margin, y: margin + 82), withAttributes: totalAttrs)

        let total = String(format: "Total reimbursement · € %.2f", businessEur + commuteEur)
        total.draw(at: CGPoint(x: margin, y: margin + 102), withAttributes: totalAttrs)
    }

    private static func drawLogbookHeader(
        vehicle: Vehicle, month: String, totalKm: Double, tripCount: Int
    ) {
        let titleAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 22, weight: .bold),
            .foregroundColor: UIColor.black
        ]
        let subAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 11),
            .foregroundColor: UIColor.darkGray
        ]
        let labelAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: UIColor.black
        ]

        "Potni nalog · \(month)".draw(
            at: CGPoint(x: margin, y: margin),
            withAttributes: titleAttrs
        )

        let vehicleLine = "Vozilo: \(vehicle.name) · Registracija: \(vehicle.licensePlate.isEmpty ? "_______________" : vehicle.licensePlate)"
        vehicleLine.draw(at: CGPoint(x: margin, y: margin + 30), withAttributes: labelAttrs)

        let summary = String(format: "Število voženj: %d · Skupaj km: %.1f", tripCount, totalKm)
        summary.draw(at: CGPoint(x: margin, y: margin + 48), withAttributes: subAttrs)

        let stamp = DateFormatter.localizedString(from: Date(), dateStyle: .medium, timeStyle: .short)
        "Ustvarjeno: \(stamp)".draw(at: CGPoint(x: margin, y: margin + 64), withAttributes: subAttrs)
    }

    private static func drawSignatureBlock(at y: CGFloat) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 10),
            .foregroundColor: UIColor.black
        ]
        let line = UIBezierPath()
        line.move(to: CGPoint(x: margin, y: y))
        line.addLine(to: CGPoint(x: margin + 200, y: y))
        line.move(to: CGPoint(x: pageSize.width - margin - 200, y: y))
        line.addLine(to: CGPoint(x: pageSize.width - margin, y: y))
        UIColor.darkGray.setStroke()
        line.lineWidth = 0.5
        line.stroke()

        "Podpis voznika".draw(at: CGPoint(x: margin, y: y + 4), withAttributes: attrs)
        "Podpis odgovorne osebe".draw(
            at: CGPoint(x: pageSize.width - margin - 200, y: y + 4),
            withAttributes: attrs
        )
    }

    private static func headerTopOffset(extra: CGFloat = 0) -> CGFloat {
        margin + 90 + extra
    }

    private static func drawTableHeader(titles: [String], widths: [CGFloat], at y: CGFloat) {
        let headerAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 10, weight: .semibold),
            .foregroundColor: UIColor.white
        ]
        let bg = UIBezierPath(rect: CGRect(x: margin, y: y, width: pageSize.width - 2 * margin, height: headerHeight))
        UIColor.darkGray.setFill()
        bg.fill()

        var x = margin + 4
        for (i, title) in titles.enumerated() {
            title.draw(at: CGPoint(x: x, y: y + 6), withAttributes: headerAttrs)
            x += widths[i]
        }
    }

    private static func drawOwnCarRow(
        trip: Trip, vehicle: Vehicle?,
        businessRate: Double, commuteRate: Double,
        at y: CGFloat, zebra: Bool
    ) {
        if zebra {
            UIColor(white: 0.95, alpha: 1).setFill()
            UIBezierPath(rect: CGRect(x: margin, y: y, width: pageSize.width - 2 * margin, height: rowHeight)).fill()
        }

        let cellAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 9),
            .foregroundColor: UIColor.black
        ]
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"

        let eur = String(format: "%.2f", trip.reimbursement(
            businessRate: businessRate, commuteRate: commuteRate
        ))

        let cells = [
            df.string(from: trip.startedAt),
            vehicle?.name ?? "—",
            trip.type.label,
            truncate(trip.startAddress, length: 22),
            truncate(trip.endAddress, length: 22),
            String(format: "%.1f", trip.distanceKm),
            eur
        ]

        var x = margin + 4
        for (i, text) in cells.enumerated() {
            text.draw(at: CGPoint(x: x, y: y + 6), withAttributes: cellAttrs)
            x += ownCarColumnWidths[i]
        }
    }

    private static func drawLogbookRow(index: Int, trip: Trip, at y: CGFloat, zebra: Bool) {
        if zebra {
            UIColor(white: 0.95, alpha: 1).setFill()
            UIBezierPath(rect: CGRect(x: margin, y: y, width: pageSize.width - 2 * margin, height: rowHeight)).fill()
        }

        let cellAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 9),
            .foregroundColor: UIColor.black
        ]
        let df = DateFormatter()
        df.dateFormat = "dd.MM.yyyy"
        let tf = DateFormatter()
        tf.dateFormat = "HH:mm"

        let cells = [
            "\(index)",
            df.string(from: trip.startedAt),
            tf.string(from: trip.startedAt),
            tf.string(from: trip.endedAt),
            truncate(trip.startAddress, length: 18),
            truncate(trip.endAddress, length: 18),
            truncate(trip.customerName.isEmpty ? trip.purpose : trip.customerName, length: 18),
            "",                                              // odometer start — handwritten
            "",                                              // odometer end   — handwritten
            String(format: "%.1f", trip.distanceKm)
        ]

        var x = margin + 4
        for (i, text) in cells.enumerated() {
            text.draw(at: CGPoint(x: x, y: y + 6), withAttributes: cellAttrs)
            x += logbookColumnWidths[i]
        }

        // Draw underline in the two blank columns to make handwriting easier.
        let startX = margin + ownLogbookOdometerOffset()
        let line = UIBezierPath()
        line.move(to: CGPoint(x: startX, y: y + 18))
        line.addLine(to: CGPoint(x: startX + logbookColumnWidths[7] - 6, y: y + 18))
        line.move(to: CGPoint(x: startX + logbookColumnWidths[7], y: y + 18))
        line.addLine(to: CGPoint(x: startX + logbookColumnWidths[7] + logbookColumnWidths[8] - 6, y: y + 18))
        UIColor.gray.setStroke()
        line.lineWidth = 0.3
        line.stroke()
    }

    private static func ownLogbookOdometerOffset() -> CGFloat {
        logbookColumnWidths.prefix(7).reduce(0, +) + 4
    }

    private static func drawPageFooter(page: Int, month: String) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 9),
            .foregroundColor: UIColor.gray
        ]
        let text = "MileLog · \(month) · page \(page)"
        text.draw(at: CGPoint(x: margin, y: pageSize.height - margin + 8), withAttributes: attrs)
    }

    // MARK: - Helpers -------------------------------------------------------

    private static func truncate(_ s: String, length: Int) -> String {
        if s.count <= length { return s }
        return String(s.prefix(length - 1)) + "…"
    }

    private static func monthName(year: Int, month: Int) -> String {
        let cal = Calendar.current
        let date = cal.date(from: DateComponents(year: year, month: month, day: 1)) ?? Date()
        let df = DateFormatter()
        df.dateFormat = "LLLL yyyy"
        return df.string(from: date)
    }
}
