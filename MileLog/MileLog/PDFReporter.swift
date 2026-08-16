import Foundation
import UIKit

/// PDF reports for bookkeeping and the SI "potni nalog" logbook.
///
/// Two reports:
///  • `generateMonthlyOwnCar` — for monthly own-car reimbursement claims.
///    Filters to vehicles of type .own, splits business vs commute totals,
///    omits private trips and any company-car trips.
///  • `generateCompanyCarLogbook` — Slovenian "potni nalog" layout for a
///    chosen company car + month, matching a real reference logbook the
///    user provided: one row PER CALENDAR DAY (not per trip), with same-day
///    trips joined into one route/km figure, plus a company/driver/vehicle
///    header block from `UserSettings` + `Vehicle`. Odometer and signature
///    fields are left blank for handwriting — the app has no way to know
///    the physical odometer reading.
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
                guard $0.distanceKm > 0 else { return false }   // skip zero-km junk
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
                guard c.year == year && c.month == month else { return false }
                guard $0.distanceKm > 0 else { return false }   // skip zero-km junk
                return $0.vehicleID == vehicle.id
            }
            .sorted { $0.startedAt < $1.startedAt }
    }

    // MARK: - Monthly own-car report ----------------------------------------

    // Date · Vehicle · Type · Customer / Purpose · From · To · km · €
    // Widths sum to ~500 — well within page width minus 2 * 36pt margin (523).
    private static let ownCarColumnWidths: [CGFloat] = [55, 65, 55, 100, 75, 75, 35, 50]
    private static var ownCarColumnTitles: [String] {
        [
            String(localized: "Date"),
            String(localized: "Vehicle"),
            String(localized: "Type"),
            String(localized: "Customer / Purpose"),
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
            drawPageFooter(page: page, month: monthLabel)
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
        // A write failure (low storage, sandbox hiccup) previously still
        // returned a "successful" Result, so ReportSelectionView showed a
        // normal-looking "Share PDF" button pointing at a missing/corrupt
        // file — for what's often the actual tax deliverable the user is
        // about to hand an accountant, with no error path at all (round-2
        // UX review finding).
        guard (try? data.write(to: url)) != nil else { return nil }
        return Result(url: url, tripCount: monthly.count, headlineKm: businessKm + commuteKm)
    }

    // MARK: - Company car logbook (Slovenian "potni nalog") -----------------
    //
    // One row PER CALENDAR DAY of the month, not per trip — matches the
    // user's actual paper/Excel logbook (a real reference file was provided
    // and checked against): a day with several trips joins their routes
    // with " / " and sums the distance into one row; a day with none just
    // shows the date and weekday name. The header block carries
    // company/driver/vehicle metadata from UserSettings + the chosen
    // Vehicle. Odometer and signature fields are left blank for handwriting,
    // matching the rest of this app's paper-logbook philosophy — the app
    // has no way to know the physical odometer reading.

    // Relacija gets the lion's share of the width — real multi-trip days can
    // read like "MS - Gornja Radgona - MS / Murska Sobota - Lek - Murska
    // Sobota" (confirmed against the user's own reference logbook), and
    // there's no multi-line cell support in this simple single-line-per-row
    // renderer.
    // Ten columns, matching the reference workbook exactly: Odhod and
    // Prihod each split into ura/min sub-columns under a spanning header,
    // and a Stanje števca (odometer) column the app cannot fill — it has no
    // way to read the car's odometer, so that column is left blank for
    // handwriting, as the reference sheet leaves it too.
    // Widths sum to 523 = 595pt A4 minus two 36pt margins.
    private static let potniNalogColumnWidths: [CGFloat] =
        [26, 54, 175, 26, 26, 26, 26, 44, 54, 66]

    /// Spanning row, then the sub-labels underneath it. An empty string
    /// means the cell above/below covers this column.
    private static let potniNalogHeaderTop =
        ["Zap.", "Datum", "Relacija  od - do", "Odhod", "", "Prihod", "",
         "Prevoženi", "Stanje", "Dan v tednu"]
    private static let potniNalogHeaderBottom =
        ["štev:", "", "", "ura", "min", "ura", "min", "km", "števca", ""]

    /// Two stacked rows rather than one.
    private static let potniNalogHeaderHeight: CGFloat = 30

    /// Generates the potni nalog for the already-filtered `trips`. Caller
    /// is responsible for filtering to a single vehicle + period.
    static func generateCompanyCarLogbook(
        trips: [Trip],
        vehicle: Vehicle,
        settings: UserSettings,
        year: Int,
        month: Int
    ) -> Result? {
        let cal = Calendar.current
        guard let firstOfMonth = cal.date(from: DateComponents(year: year, month: month, day: 1)),
              let dayRange = cal.range(of: .day, in: .month, for: firstOfMonth)
        else { return nil }

        let monthly = trips.sorted { $0.startedAt < $1.startedAt }
        let monthLabel = monthName(year: year, month: month)

        var tripsByDay: [Int: [Trip]] = [:]
        for trip in monthly {
            let day = cal.component(.day, from: trip.startedAt)
            tripsByDay[day, default: []].append(trip)
        }
        // Round per day, then total the rounded values — see drawPotniNalogRow.
        let kmByDay = tripsByDay.mapValues { dayTrips in
            Int(dayTrips.reduce(0) { $0 + $1.distanceKm }.rounded())
        }
        let totalKm = kmByDay.values.reduce(0, +)

        let dayFormatter = DateFormatter()
        dayFormatter.dateFormat = "dd.MM.yyyy"
        // Slovenian weekday names regardless of the device's own locale,
        // matching the reference logbook's "Dan v tednu" column exactly.
        let weekdayFormatter = DateFormatter()
        weekdayFormatter.locale = Locale(identifier: "sl_SI")
        weekdayFormatter.dateFormat = "EEEE"
        // Separate ura / min columns, as in the reference workbook.
        let hourFormatter = DateFormatter()
        hourFormatter.dateFormat = "HH"
        let minuteFormatter = DateFormatter()
        minuteFormatter.dateFormat = "mm"

        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(origin: .zero, size: pageSize))
        let data = renderer.pdfData { ctx in
            var page = 1
            ctx.beginPage()
            drawPageFooter(page: page, month: monthLabel)
            drawPotniNalogHeader(settings: settings, vehicle: vehicle, firstOfMonth: firstOfMonth)
            var y = headerTopOffset(extra: 96)
            drawPotniNalogTableHeader(at: y)
            y += potniNalogHeaderHeight

            for day in 1...dayRange.count {
                guard let date = cal.date(byAdding: .day, value: day - 1, to: firstOfMonth) else { continue }
                if y + rowHeight > pageSize.height - 130 {   // leave room for totals/signature
                    ctx.beginPage()
                    page += 1
                    drawPageFooter(page: page, month: monthLabel)
                    y = margin
                    drawPotniNalogTableHeader(at: y)
                    y += potniNalogHeaderHeight
                }
                let dayTrips = (tripsByDay[day] ?? []).sorted { $0.startedAt < $1.startedAt }
                drawPotniNalogRow(
                    day: day, date: date, trips: dayTrips,
                    dayKmRounded: kmByDay[day] ?? 0,
                    dayFormatter: dayFormatter, weekdayFormatter: weekdayFormatter,
                    hourFormatter: hourFormatter, minuteFormatter: minuteFormatter,
                    at: y, zebra: (day - 1).isMultiple(of: 2)
                )
                y += rowHeight
            }

            y += 14
            if y + 90 > pageSize.height - margin {
                ctx.beginPage()
                page += 1
                drawPageFooter(page: page, month: monthLabel)
                y = margin
            }
            drawPotniNalogFooter(totalKm: totalKm, at: y)
        }

        let filename = String(format: "MileLog-PotniNalog-%@-%04d-%02d.pdf",
                              vehicle.licensePlate.isEmpty ? vehicle.name : vehicle.licensePlate,
                              year, month)
            .replacingOccurrences(of: " ", with: "-")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
        // See generateMonthlyOwnCar's identical guard: a silent write
        // failure previously still returned a "successful" Result (round-2
        // UX review finding).
        guard (try? data.write(to: url)) != nil else { return nil }
        // totalKm is whole kilometres here (summed from the rounded per-day
        // values so the printed column reconciles); Result reports km as a
        // Double for the own-car report, which does carry decimals.
        return Result(url: url, tripCount: monthly.count, headlineKm: Double(totalKm))
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

    /// Replicates the reference "potni nalog" spreadsheet's header block:
    /// company name/address/location, transport type, vehicle registration,
    /// driver name, vehicle type + seat count, beneficiary, and area —
    /// pulled from `UserSettings` (company/driver/beneficiary/area) and the
    /// chosen `Vehicle` (registration, type description, seat count).
    /// "Vrsta prevoza" (transport type) is a fixed "SLUŽBENA POT" — this
    /// report exists specifically for logging business trips, so there's
    /// nothing else it would say.
    private static func drawPotniNalogHeader(
        settings: UserSettings, vehicle: Vehicle, firstOfMonth: Date
    ) {
        let titleAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 15, weight: .bold),
            .foregroundColor: UIColor.black
        ]
        let valueAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 10),
            .foregroundColor: UIColor.black
        ]
        let placeholder = "_______________"

        // Capped so a long free-text company name (bold, 15pt, unbounded in
        // Settings) can't run into the date line drawn on the same row on
        // the right — `.draw(at:)` doesn't clip or wrap (round-6
        // adversarial review finding).
        let companyName = settings.companyName.isEmpty
            ? String(localized: "(Company name — set in Settings)")
            : truncate(settings.companyName, length: 35)
        companyName.draw(at: CGPoint(x: margin, y: margin), withAttributes: titleAttrs)
        "POTNI NALOG za prevoz oseb".draw(at: CGPoint(x: margin, y: margin + 20), withAttributes: titleAttrs)

        let df = DateFormatter()
        df.dateFormat = "dd.MM.yyyy"
        let dateLine = [settings.companyLocation, "datum: \(df.string(from: firstOfMonth))"]
            .filter { !$0.isEmpty }.joined(separator: ", ")
        dateLine.draw(at: CGPoint(x: pageSize.width - margin - 180, y: margin), withAttributes: valueAttrs)

        if !settings.companyAddress.isEmpty {
            truncate(settings.companyAddress, length: 70).draw(at: CGPoint(x: margin, y: margin + 40), withAttributes: valueAttrs)
        }

        var y = margin + 58
        // Rows with a second field at a fixed right-hand offset need their
        // LEFT value length-capped, or a long free-text value (vehicle type
        // description, in practice — everything else on the right-hand
        // column is short by nature) can run into it with nothing to stop
        // the overlap, since `.draw(at:)` doesn't clip or wrap (round-6
        // adversarial review finding).
        func field(_ label: String, _ value: String, x: CGFloat, maxValueLength: Int? = nil) {
            let shown = maxValueLength.map { truncate(value, length: $0) } ?? value
            "\(label) \(shown)".draw(at: CGPoint(x: x, y: y), withAttributes: valueAttrs)
        }
        field("Vrsta prevoza:", "SLUŽBENA POT", x: margin)
        field("Reg. številka:", vehicle.licensePlate.isEmpty ? placeholder : vehicle.licensePlate,
              x: margin + 280, maxValueLength: 20)
        y += 16
        field("Priimek in ime voznika:", settings.driverName.isEmpty ? placeholder : settings.driverName,
              x: margin, maxValueLength: 40)
        y += 16
        field("Vrsta in tip vozila:", vehicle.vehicleTypeDescription.isEmpty ? placeholder : vehicle.vehicleTypeDescription,
              x: margin, maxValueLength: 32)
        field("Število sedežev:", "\(vehicle.seatCount)", x: margin + 280)
        y += 16
        field("Koristnik po nalogu:", settings.tripBeneficiary.isEmpty ? placeholder : settings.tripBeneficiary,
              x: margin, maxValueLength: 40)
        y += 16
        field("Na relaciji:", settings.tripArea.isEmpty ? placeholder : settings.tripArea, x: margin, maxValueLength: 60)

        // Both present on the reference form and both left blank there:
        // the travel-order number is assigned by bookkeeping, and the
        // approval signature is written by hand.
        "Štev. pot.n.:".draw(at: CGPoint(x: pageSize.width - margin - 180, y: margin + 20),
                             withAttributes: valueAttrs)
        "Podpis odg. osebe: \(placeholder)".draw(
            at: CGPoint(x: pageSize.width - margin - 180, y: y + 16),
            withAttributes: valueAttrs)
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

        // Prefer customer; fall back to purpose; never show "—" inside a PDF cell.
        let customerOrPurpose: String = {
            if !trip.customerName.isEmpty { return trip.customerName }
            if !trip.purpose.isEmpty      { return trip.purpose }
            return ""
        }()

        let cells = [
            df.string(from: trip.startedAt),
            truncate(vehicle?.name ?? "—", length: 14),
            trip.type.label,
            truncate(customerOrPurpose, length: 22),
            truncate(trip.startAddress, length: 16),
            truncate(trip.endAddress, length: 16),
            String(format: "%.1f", trip.distanceKm),
            eur
        ]

        var x = margin + 4
        for (i, text) in cells.enumerated() {
            text.draw(at: CGPoint(x: x, y: y + 6), withAttributes: cellAttrs)
            x += ownCarColumnWidths[i]
        }
    }

    /// One row per calendar day. `trips` is every trip that started on this
    /// day (already sorted by start time), possibly empty. Multiple trips
    /// join their "from - to" routes with " / " and sum into one km figure,
    /// matching the reference logbook's own convention for a day with
    /// several separate drives.
    /// The two-row table header: "Odhod" and "Prihod" span their ura/min
    /// pairs, everything else is a single title sitting across both rows.
    private static func drawPotniNalogTableHeader(at y: CGFloat) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 8, weight: .semibold),
            .foregroundColor: UIColor.white
        ]
        let width = pageSize.width - 2 * margin
        UIColor.darkGray.setFill()
        UIBezierPath(rect: CGRect(x: margin, y: y, width: width,
                                  height: potniNalogHeaderHeight)).fill()

        // Column edges, so spanning titles can be centred over their pair
        // and separators drawn on the real boundaries.
        var edges: [CGFloat] = [margin]
        for w in potniNalogColumnWidths { edges.append(edges[edges.count - 1] + w) }

        let separators = UIBezierPath()
        for i in 1..<edges.count - 1 {
            separators.move(to: CGPoint(x: edges[i], y: y))
            separators.addLine(to: CGPoint(x: edges[i], y: y + potniNalogHeaderHeight))
        }
        UIColor(white: 1, alpha: 0.35).setStroke()
        separators.lineWidth = 0.5
        separators.stroke()

        func centred(_ text: String, from: Int, to: Int, atY: CGFloat) {
            guard !text.isEmpty else { return }
            let box = CGRect(x: edges[from], y: atY,
                             width: edges[to + 1] - edges[from], height: 12)
            let size = (text as NSString).size(withAttributes: attrs)
            text.draw(at: CGPoint(x: box.midX - size.width / 2, y: atY),
                      withAttributes: attrs)
        }

        // Odhod spans columns 3-4, Prihod spans 5-6; the rest stand alone.
        let spans: [Int: Int] = [3: 4, 5: 6]
        for i in potniNalogHeaderTop.indices {
            centred(potniNalogHeaderTop[i], from: i, to: spans[i] ?? i, atY: y + 4)
        }
        for i in potniNalogHeaderBottom.indices {
            centred(potniNalogHeaderBottom[i], from: i, to: i, atY: y + 17)
        }
    }

    private static func drawPotniNalogRow(
        day: Int, date: Date, trips: [Trip],
        dayKmRounded: Int,
        dayFormatter: DateFormatter, weekdayFormatter: DateFormatter,
        hourFormatter: DateFormatter, minuteFormatter: DateFormatter,
        at y: CGFloat, zebra: Bool
    ) {
        if zebra {
            UIColor(white: 0.95, alpha: 1).setFill()
            UIBezierPath(rect: CGRect(x: margin, y: y, width: pageSize.width - 2 * margin, height: rowHeight)).fill()
        }

        let cellAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 8),
            .foregroundColor: UIColor.black
        ]

        let relacija = trips.map { trip -> String in
            let from = trip.startAddress.isEmpty ? "?" : trip.startAddress
            let to = trip.endAddress.isEmpty ? "?" : trip.endAddress
            return "\(from) - \(to)"
        }.joined(separator: " / ")

        // Departure of the day's first trip, arrival of its last — the
        // reference logbook doesn't track exact times per leg on a
        // multi-trip day either, just a single departure/return pair.
        let odhodHour = trips.first.map { hourFormatter.string(from: $0.startedAt) } ?? ""
        let odhodMinute = trips.first.map { minuteFormatter.string(from: $0.startedAt) } ?? ""
        // Rows are grouped by startedAt's calendar day, but a trip can end
        // after midnight — printing a bare "00:15" under a row dated the
        // day before reads as arriving before departing. Flag it rather
        // than silently rendering an internally-inconsistent pair on an
        // official travel-order document (round-15 adversarial review
        // finding).
        let prihodHour = trips.last.map { trip -> String in
            let hour = hourFormatter.string(from: trip.endedAt)
            // A trip can end after midnight. Printing a bare "00" under a
            // row dated the previous day reads as arriving before departing,
            // so mark it rather than render an internally inconsistent pair
            // on an official travel order (round-15 adversarial review).
            return Calendar.current.isDate(trip.endedAt, inSameDayAs: date) ? hour : "\(hour)+"
        } ?? ""
        let prihodMinute = trips.last.map { minuteFormatter.string(from: $0.endedAt) } ?? ""

        // Whole kilometres, like the reference workbook. Rounded per day and
        // the month total summed from these rounded values, so the printed
        // column actually adds up to the printed total — summing the raw
        // decimals instead leaves an official document whose figures do not
        // reconcile when someone checks them with a calculator.
        let cells = [
            "\(day)",
            dayFormatter.string(from: date),
            truncate(relacija, length: 42),
            odhodHour,
            odhodMinute,
            prihodHour,
            prihodMinute,
            dayKmRounded > 0 ? "\(dayKmRounded)" : "",
            "",                                  // Stanje števca — handwritten
            weekdayFormatter.string(from: date)
        ]

        // Right-align the numeric columns (index 7), centre the ura/min
        // pairs, left-align the rest — as in the reference sheet.
        var edges: [CGFloat] = [margin]
        for w in potniNalogColumnWidths { edges.append(edges[edges.count - 1] + w) }
        let centredColumns: Set<Int> = [0, 3, 4, 5, 6]
        for (i, text) in cells.enumerated() where !text.isEmpty {
            let size = (text as NSString).size(withAttributes: cellAttrs)
            let x: CGFloat
            if centredColumns.contains(i) {
                x = (edges[i] + edges[i + 1]) / 2 - size.width / 2
            } else if i == 7 {
                x = edges[i + 1] - size.width - 6
            } else {
                x = edges[i] + 4
            }
            text.draw(at: CGPoint(x: x, y: y + 6), withAttributes: cellAttrs)
        }
    }

    private static func drawPotniNalogFooter(totalKm: Int, at y: CGFloat) {
        let totalAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: UIColor.black
        ]
        let labelAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 10),
            .foregroundColor: UIColor.black
        ]

        String(format: "SKUPAJ PREVOŽENIH KILOMETROV : %ld", totalKm)
            .draw(at: CGPoint(x: margin, y: y), withAttributes: totalAttrs)
        "Stanje km števca: _______________".draw(at: CGPoint(x: margin, y: y + 20), withAttributes: labelAttrs)
        "Razlika v km: _______________".draw(at: CGPoint(x: margin, y: y + 36), withAttributes: labelAttrs)

        let signatureY = y + 66
        let line = UIBezierPath()
        line.move(to: CGPoint(x: margin, y: signatureY))
        line.addLine(to: CGPoint(x: margin + 200, y: signatureY))
        line.move(to: CGPoint(x: pageSize.width - margin - 200, y: signatureY))
        line.addLine(to: CGPoint(x: pageSize.width - margin, y: signatureY))
        UIColor.darkGray.setStroke()
        line.lineWidth = 0.5
        line.stroke()

        "Odobril:".draw(at: CGPoint(x: margin, y: signatureY + 4), withAttributes: labelAttrs)
        "Podpis uporabnika:".draw(
            at: CGPoint(x: pageSize.width - margin - 200, y: signatureY + 4),
            withAttributes: labelAttrs
        )
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
