import Foundation
import UIKit

/// Generates an A4 portrait PDF logbook for a single month.
/// Layout: title block with totals, then a single-row-per-trip table that
/// flows to extra pages as needed.
enum PDFReporter {

    private static let pageSize = CGSize(width: 595, height: 842)      // A4 @ 72dpi
    private static let margin: CGFloat = 36
    private static let rowHeight: CGFloat = 22
    private static let headerHeight: CGFloat = 24

    /// Column widths (sum must equal page width minus 2 * margin = 523).
    private static let columnWidths: [CGFloat] = [60, 80, 60, 95, 110, 50, 50, 18]
    private static let columnTitles  = ["Date", "Vehicle", "Type", "From", "To", "km", "€", ""]

    struct Result {
        let url: URL
        let tripCount: Int
        let businessKm: Double
    }

    static func generateMonthly(
        trips: [Trip],
        vehicleLookup: (UUID) -> Vehicle?,
        rate: Double,
        year: Int,
        month: Int
    ) -> Result? {
        let cal = Calendar.current
        let monthly = trips
            .filter {
                let c = cal.dateComponents([.year, .month], from: $0.startedAt)
                return c.year == year && c.month == month
            }
            .sorted { $0.startedAt < $1.startedAt }

        let totalKm = monthly.reduce(0) { $0 + $1.distanceKm }
        let businessKm = monthly.filter { $0.type == .business }.reduce(0) { $0 + $1.distanceKm }
        let businessEur = monthly.filter { $0.type == .business }.reduce(0) { $0 + $1.reimbursement(rate: rate) }

        let monthLabel = monthName(year: year, month: month)

        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(origin: .zero, size: pageSize))
        let data = renderer.pdfData { ctx in
            var rowIndex = 0
            var pageNumber = 1
            ctx.beginPage()
            drawHeader(month: monthLabel, totalKm: totalKm,
                       businessKm: businessKm, businessEur: businessEur,
                       tripCount: monthly.count, page: pageNumber)
            var y = headerTopOffset()
            drawTableHeader(at: y)
            y += headerHeight

            for trip in monthly {
                if y + rowHeight > pageSize.height - margin {
                    ctx.beginPage()
                    pageNumber += 1
                    drawPageFooter(page: pageNumber, month: monthLabel)
                    y = margin
                    drawTableHeader(at: y)
                    y += headerHeight
                }
                drawRow(trip: trip,
                        vehicle: vehicleLookup(trip.vehicleID),
                        rate: rate,
                        at: y,
                        zebra: rowIndex.isMultiple(of: 2))
                y += rowHeight
                rowIndex += 1
            }

            if monthly.isEmpty {
                let note = "No trips recorded for \(monthLabel)."
                note.draw(at: CGPoint(x: margin, y: y + 8),
                          withAttributes: [
                            .font: UIFont.italicSystemFont(ofSize: 11),
                            .foregroundColor: UIColor.gray
                          ])
            }
        }

        let filename = String(format: "MileLog-%04d-%02d.pdf", year, month)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
        try? data.write(to: url)
        return Result(url: url, tripCount: monthly.count, businessKm: businessKm)
    }

    // MARK: - Drawing

    private static func drawHeader(
        month: String, totalKm: Double, businessKm: Double,
        businessEur: Double, tripCount: Int, page: Int
    ) {
        let titleAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 22, weight: .bold),
            .foregroundColor: UIColor.black
        ]
        let subAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 11),
            .foregroundColor: UIColor.darkGray
        ]

        "MileLog · \(month)".draw(at: CGPoint(x: margin, y: margin), withAttributes: titleAttrs)

        let summary = String(format: "%d trips · %.1f km total · %.1f km business · € %.2f reimbursement",
                             tripCount, totalKm, businessKm, businessEur)
        summary.draw(at: CGPoint(x: margin, y: margin + 30), withAttributes: subAttrs)

        let generated = "Generated " + DateFormatter.localizedString(from: Date(), dateStyle: .medium, timeStyle: .short)
        generated.draw(at: CGPoint(x: margin, y: margin + 46), withAttributes: subAttrs)
    }

    private static func headerTopOffset() -> CGFloat { margin + 72 }

    private static func drawTableHeader(at y: CGFloat) {
        let headerAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 10, weight: .semibold),
            .foregroundColor: UIColor.white
        ]
        let bg = UIBezierPath(rect: CGRect(x: margin, y: y, width: pageSize.width - 2 * margin, height: headerHeight))
        UIColor.darkGray.setFill()
        bg.fill()

        var x = margin + 4
        for (i, title) in columnTitles.enumerated() {
            title.draw(at: CGPoint(x: x, y: y + 6), withAttributes: headerAttrs)
            x += columnWidths[i]
        }
    }

    private static func drawRow(trip: Trip, vehicle: Vehicle?, rate: Double, at y: CGFloat, zebra: Bool) {
        if zebra {
            UIColor(white: 0.95, alpha: 1).setFill()
            UIBezierPath(rect: CGRect(x: margin, y: y, width: pageSize.width - 2 * margin, height: rowHeight)).fill()
        }

        let cellAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 9),
            .foregroundColor: UIColor.black
        ]
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"

        let eur = trip.type == .business
            ? String(format: "%.2f", trip.reimbursement(rate: rate))
            : "—"

        let cells = [
            formatter.string(from: trip.startedAt),
            vehicle?.name ?? "—",
            trip.type.label,
            truncate(trip.startAddress, length: 18),
            truncate(trip.endAddress, length: 20),
            String(format: "%.1f", trip.distanceKm),
            eur,
            ""
        ]

        var x = margin + 4
        for (i, text) in cells.enumerated() {
            text.draw(at: CGPoint(x: x, y: y + 6), withAttributes: cellAttrs)
            x += columnWidths[i]
        }
    }

    private static func drawPageFooter(page: Int, month: String) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 9),
            .foregroundColor: UIColor.gray
        ]
        let text = "MileLog · \(month) · page \(page)"
        text.draw(at: CGPoint(x: margin, y: pageSize.height - margin + 8), withAttributes: attrs)
    }

    // MARK: - Helpers

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
