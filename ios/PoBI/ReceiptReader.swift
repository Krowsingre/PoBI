import Foundation
import UIKit
import Vision

/// Reads the date printed on a receipt photo, on the phone, with Apple's text recognition.
/// The receipt must be dated within the last 7 days (D11). The photo itself is never stored.
enum ReceiptReader {
    enum Result: Equatable {
        /// A date within the allowed window was found.
        case valid(Date)
        /// Dates were found, but none in the window. Carries the most recent one.
        case tooOld(Date)
        /// Only dates after today were found.
        case inFuture(Date)
        /// No date could be read.
        case noDate
    }

    /// How many days back a receipt may be dated, counting today as day 0.
    static let maxAgeDays = 7

    static func check(_ image: UIImage, now: Date = .now) async -> Result {
        let lines = await recognizeText(in: image)
        let found = lines.flatMap { Self.dates(in: $0, now: now) }
        return evaluate(found, now: now)
    }

    static func evaluate(_ dates: [Date], now: Date) -> Result {
        let calendar = GameStore.calendar
        let today = calendar.startOfDay(for: now)
        guard let earliest = calendar.date(byAdding: .day, value: -maxAgeDays, to: today) else { return .noDate }
        let days = Set(dates.map { calendar.startOfDay(for: $0) })
        if let best = days.filter({ $0 >= earliest && $0 <= today }).max() {
            return .valid(best)
        }
        if let past = days.filter({ $0 < earliest }).max() {
            return .tooOld(past)
        }
        if let future = days.min() {
            return .inFuture(future)
        }
        return .noDate
    }

    // MARK: Text recognition

    private static func recognizeText(in photo: UIImage) async -> [String] {
        // Redrawing at a modest size also bakes in the camera's rotation.
        let image = ImageResizer.downscale(photo, maxSide: 2000)
        guard let cgImage = image.cgImage else { return [] }
        let imageOrientation = orientation(of: image)
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                request.usesLanguageCorrection = false
                let handler = VNImageRequestHandler(cgImage: cgImage, orientation: imageOrientation)
                try? handler.perform([request])
                let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
                continuation.resume(returning: lines)
            }
        }
    }

    private static func orientation(of image: UIImage) -> CGImagePropertyOrientation {
        switch image.imageOrientation {
        case .up: return .up
        case .down: return .down
        case .left: return .left
        case .right: return .right
        case .upMirrored: return .upMirrored
        case .downMirrored: return .downMirrored
        case .leftMirrored: return .leftMirrored
        case .rightMirrored: return .rightMirrored
        @unknown default: return .up
        }
    }

    // MARK: Date parsing

    private static let monthNames: [String: Int] = [
        "jan": 1, "feb": 2, "mar": 3, "apr": 4, "may": 5, "jun": 6,
        "jul": 7, "aug": 8, "sep": 9, "sept": 9, "oct": 10, "nov": 11, "dec": 12,
    ]

    /// Finds US-style receipt dates: 11/21/2026, 11-21-26, 2026-11-21, Nov 21, 2026, 21 Nov 2026.
    static func dates(in text: String, now: Date) -> [Date] {
        var found: [Date] = []
        let lower = text.lowercased()
        func match(_ pattern: String, _ build: ([String]) -> Date?) {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return }
            let range = NSRange(lower.startIndex..., in: lower)
            for result in regex.matches(in: lower, range: range) {
                let groups = (1..<result.numberOfRanges).map { index -> String in
                    guard let r = Range(result.range(at: index), in: lower) else { return "" }
                    return String(lower[r])
                }
                if let date = build(groups) { found.append(date) }
            }
        }
        // 11/21/2026, 11-21-26, 11.21.2026
        match(#"(?<!\d)(\d{1,2})[/\-.](\d{1,2})[/\-.](\d{2}|\d{4})(?!\d)"#) { g in
            make(year: g[2], month: Int(g[0]), day: Int(g[1]), now: now)
        }
        // 2026-11-21, 2026/11/21
        match(#"(?<!\d)(\d{4})[/\-.](\d{1,2})[/\-.](\d{1,2})(?!\d)"#) { g in
            make(year: g[0], month: Int(g[1]), day: Int(g[2]), now: now)
        }
        // Nov 21, 2026 / November 21 2026
        match(#"\b([a-z]{3,9})\.?\s+(\d{1,2}),?\s+(\d{4}|\d{2})\b"#) { g in
            make(year: g[2], month: month(g[0]), day: Int(g[1]), now: now)
        }
        // 21 Nov 2026
        match(#"\b(\d{1,2})\s+([a-z]{3,9})\.?,?\s+(\d{4}|\d{2})\b"#) { g in
            make(year: g[2], month: month(g[1]), day: Int(g[0]), now: now)
        }
        return found
    }

    private static let fullMonthNames = [
        "january", "february", "march", "april", "may", "june",
        "july", "august", "september", "october", "november", "december",
    ]

    /// Only real month names or their usual abbreviations, so words like "market" don't count.
    private static func month(_ word: String) -> Int? {
        if let short = monthNames[word] { return short }
        if let index = fullMonthNames.firstIndex(of: word) { return index + 1 }
        return nil
    }

    private static func make(year text: String, month: Int?, day: Int?, now: Date) -> Date? {
        guard let month, let day, (1...12).contains(month), (1...31).contains(day), var year = Int(text) else { return nil }
        if text.count == 2 { year += 2000 }
        let calendar = GameStore.calendar
        let thisYear = calendar.component(.year, from: now)
        guard abs(year - thisYear) <= 1 else { return nil }
        var parts = DateComponents()
        parts.year = year
        parts.month = month
        parts.day = day
        guard let date = calendar.date(from: parts),
              calendar.component(.day, from: date) == day else { return nil }
        return date
    }
}
