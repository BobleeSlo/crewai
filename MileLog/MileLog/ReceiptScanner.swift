import Foundation
import UIKit
import Vision

/// On-device receipt OCR using Apple's Vision framework. No network calls,
/// no third-party model — VNRecognizeTextRequest ships with iOS and is
/// fast enough to scan a typical receipt in well under a second.
///
/// Strategy for extracting the receipt total:
///   1. Recognize all text lines with high accuracy.
///   2. Find every numeric pattern that looks like a monetary amount
///      (e.g. "12,34", "12.34", "€ 12.34", "1.234,56").
///   3. Bias the result toward lines that contain a "total" keyword in
///      Slovenian or English. If no keyword line matches, fall back to
///      the largest amount on the receipt (almost always the total).
enum ReceiptScanner {

    /// Lowercase keywords that mark the receipt grand total — Slovenian first
    /// (the primary target market) then English fallbacks.
    private static let totalKeywords: [String] = [
        "skupaj", "skupaj za plačilo", "za plačilo", "znesek", "končni znesek",
        "total", "amount", "balance", "to pay"
    ]

    /// Run OCR on a receipt photo and return the best-guess total amount in EUR.
    /// Returns `nil` if no plausible amount is found.
    static func extractAmount(from image: UIImage) async -> Double? {
        guard let cgImage = image.cgImage else { return nil }

        let lines = await recognizedLines(in: cgImage)
        guard !lines.isEmpty else { return nil }

        return bestAmount(from: lines)
    }

    // MARK: - OCR

    private static func recognizedLines(in cgImage: CGImage) async -> [String] {
        await withCheckedContinuation { continuation in
            let request = VNRecognizeTextRequest { request, _ in
                let observations = (request.results as? [VNRecognizedTextObservation]) ?? []
                let lines = observations.compactMap { $0.topCandidates(1).first?.string }
                continuation.resume(returning: lines)
            }
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = false   // numbers shouldn't be "corrected"
            request.recognitionLanguages = ["sl-SI", "en-US"]

            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            DispatchQueue.global(qos: .userInitiated).async {
                do { try handler.perform([request]) }
                catch { continuation.resume(returning: []) }
            }
        }
    }

    // MARK: - Amount parsing

    /// Matches things like 12,34 / 12.34 / 1.234,56 / 1,234.56
    private static let amountRegex = try? NSRegularExpression(
        pattern: #"(\d{1,3}(?:[.,]\d{3})*[.,]\d{2})"#
    )

    private static func bestAmount(from lines: [String]) -> Double? {
        var keywordHits: [Double] = []
        var allAmounts: [Double] = []

        for line in lines {
            let lower = line.lowercased()
            let isTotalLine = totalKeywords.contains { lower.contains($0) }

            for amount in amounts(in: line) {
                allAmounts.append(amount)
                if isTotalLine { keywordHits.append(amount) }
            }
        }

        // Prefer amounts that appear on lines containing a "total" keyword;
        // tie-break by largest value (the total dominates line items).
        if let best = keywordHits.max() { return best }
        return allAmounts.max()
    }

    private static func amounts(in text: String) -> [Double] {
        guard let regex = amountRegex else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        var results: [Double] = []
        regex.enumerateMatches(in: text, options: [], range: range) { match, _, _ in
            guard let match, let r = Range(match.range, in: text) else { return }
            if let value = normalize(String(text[r])) {
                // Reject obvious junk (PINs, dates, huge numbers).
                if value > 0.10 && value < 99_999 {
                    results.append(value)
                }
            }
        }
        return results
    }

    /// Convert a localized money string into a Double.
    ///  "12,34"    -> 12.34
    ///  "1.234,56" -> 1234.56
    ///  "1,234.56" -> 1234.56
    ///  "12.34"    -> 12.34
    private static func normalize(_ raw: String) -> Double? {
        // Detect which separator is the decimal: whichever appears last.
        let lastComma = raw.lastIndex(of: ",")
        let lastDot   = raw.lastIndex(of: ".")

        switch (lastComma, lastDot) {
        case let (c?, d?):
            if c > d {
                // European style "1.234,56"
                return Double(raw.replacingOccurrences(of: ".", with: "")
                                 .replacingOccurrences(of: ",", with: "."))
            } else {
                // US style "1,234.56"
                return Double(raw.replacingOccurrences(of: ",", with: ""))
            }
        case (.some, .none):
            // Only comma — treat as decimal separator
            return Double(raw.replacingOccurrences(of: ",", with: "."))
        case (.none, .some):
            // Only dot — already parseable
            return Double(raw)
        default:
            return Double(raw)
        }
    }
}
