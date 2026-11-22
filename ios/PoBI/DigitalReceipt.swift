import Foundation
import PDFKit
import UIKit
import UniformTypeIdentifiers

/// A receipt that arrived as a file: a PDF, a saved email (.eml), a web page or text, or a screenshot.
/// It's read on the phone like a paper receipt, and kept as an image for the review.
struct DigitalReceipt: Equatable {
    let lines: [String]
    /// What the reviewer sees: the first PDF page, the screenshot, or the email's text drawn as a page.
    let image: UIImage

    /// The kinds of file the app accepts (also listed in Info.plist so it shows in the share sheet).
    static let types: [UTType] = [.pdf, .image, .emailMessage, .html, .plainText]

    enum LoadError: LocalizedError {
        case unreadable
        var errorDescription: String? { "Couldn't open that file. Share a PDF, an email, or a screenshot of the receipt." }
    }

    static func load(_ url: URL) async throws -> DigitalReceipt {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let type = UTType(filenameExtension: url.pathExtension) ?? .data

        if type.conforms(to: .pdf) {
            guard let pdf = PDFDocument(url: url), let first = pdf.page(at: 0) else { throw LoadError.unreadable }
            let image = first.thumbnail(of: CGSize(width: 1600, height: 1600 * 1.5), for: .mediaBox)
            let text = (0..<min(pdf.pageCount, 3)).compactMap { pdf.page(at: $0)?.string }.joined(separator: "\n")
            // A scanned PDF has no text layer: read the page like a photo.
            let lines = clean(text)
            return DigitalReceipt(lines: lines.isEmpty ? await ReceiptReader.recognizeText(in: image) : lines, image: image)
        }
        if type.conforms(to: .image) {
            guard let data = try? Data(contentsOf: url), let image = UIImage(data: data) else { throw LoadError.unreadable }
            return DigitalReceipt(lines: await ReceiptReader.recognizeText(in: image), image: image)
        }
        guard let data = try? Data(contentsOf: url) else { throw LoadError.unreadable }
        let raw = String(decoding: data, as: UTF8.self)
        let text: String
        if type.conforms(to: .emailMessage) || url.pathExtension.lowercased() == "eml" {
            text = EmailText.readable(raw)
        } else if type.conforms(to: .html) {
            text = EmailText.stripHTML(raw)
        } else {
            text = raw
        }
        let lines = clean(text)
        guard !lines.isEmpty else { throw LoadError.unreadable }
        return DigitalReceipt(lines: lines, image: render(lines))
    }

    static func clean(_ text: String) -> [String] {
        text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Draws the text on a white page, so the reviewer sees what the app read.
    static func render(_ lines: [String]) -> UIImage {
        let shown = Array(lines.prefix(120))
        let font = UIFont.monospacedSystemFont(ofSize: 14, weight: .regular)
        let width: CGFloat = 900
        let text = shown.joined(separator: "\n") as NSString
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: UIColor.black]
        let bounds = text.boundingRect(with: CGSize(width: width - 40, height: .greatestFiniteMagnitude),
                                       options: .usesLineFragmentOrigin, attributes: attributes, context: nil)
        let size = CGSize(width: width, height: min(ceil(bounds.height) + 40, 4000))
        return UIGraphicsImageRenderer(size: size).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            text.draw(in: CGRect(x: 20, y: 20, width: width - 40, height: size.height - 40), withAttributes: attributes)
        }
    }
}

/// Just enough email parsing to get a receipt's text out of a saved .eml file.
enum EmailText {
    static func readable(_ raw: String) -> String {
        let message = raw.replacingOccurrences(of: "\r\n", with: "\n")
        let (headers, body) = split(message)
        var lines: [String] = []
        for name in ["From", "Subject", "Date"] {
            if let value = header(name, in: headers) { lines.append("\(name): \(value)") }
        }
        lines.append(text(of: headers, body: body))
        return lines.joined(separator: "\n")
    }

    /// Splits a message or MIME part at the first blank line.
    static func split(_ part: String) -> (headers: String, body: String) {
        guard let range = part.range(of: "\n\n") else { return (part, "") }
        return (String(part[..<range.lowerBound]), String(part[range.upperBound...]))
    }

    static func header(_ name: String, in headers: String) -> String? {
        // Unfold continuation lines first.
        let unfolded = headers.replacingOccurrences(of: "\n ", with: " ").replacingOccurrences(of: "\n\t", with: " ")
        for line in unfolded.components(separatedBy: "\n") {
            let parts = line.split(separator: ":", maxSplits: 1)
            if parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(name) == .orderedSame {
                return parts[1].trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    /// The readable text of a part: plain text preferred, HTML stripped, multiparts searched.
    static func text(of headers: String, body: String) -> String {
        let contentType = header("Content-Type", in: headers)?.lowercased() ?? "text/plain"
        if contentType.hasPrefix("multipart/"), let boundary = parameter("boundary", in: header("Content-Type", in: headers) ?? "") {
            let parts = body.components(separatedBy: "--" + boundary).dropFirst()
                .filter { !$0.hasPrefix("--") }
                .map { split($0.hasPrefix("\n") ? String($0.dropFirst()) : $0) }
            // Prefer a plain-text part; otherwise take the first part that yields text.
            if let plain = parts.first(where: { (header("Content-Type", in: $0.headers)?.lowercased() ?? "").hasPrefix("text/plain") }) {
                return text(of: plain.headers, body: plain.body)
            }
            for part in parts {
                let found = text(of: part.headers, body: part.body)
                if !found.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return found }
            }
            return ""
        }
        guard contentType.hasPrefix("text/") else { return "" }
        let decoded = decode(body, encoding: header("Content-Transfer-Encoding", in: headers)?.lowercased() ?? "")
        return contentType.hasPrefix("text/html") ? stripHTML(decoded) : decoded
    }

    static func parameter(_ name: String, in value: String) -> String? {
        for piece in value.components(separatedBy: ";") {
            let pair = piece.split(separator: "=", maxSplits: 1)
            if pair.count == 2, pair[0].trimmingCharacters(in: .whitespaces).lowercased() == name {
                return pair[1].trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            }
        }
        return nil
    }

    static func decode(_ body: String, encoding: String) -> String {
        if encoding == "base64" {
            let compact = body.components(separatedBy: .whitespacesAndNewlines).joined()
            return Data(base64Encoded: compact).map { String(decoding: $0, as: UTF8.self) } ?? body
        }
        if encoding == "quoted-printable" {
            var bytes: [UInt8] = []
            let text = body.replacingOccurrences(of: "=\n", with: "")
            let utf8 = Array(text.utf8)
            var i = 0
            while i < utf8.count {
                if utf8[i] == UInt8(ascii: "="), i + 2 < utf8.count,
                   let byte = UInt8(String(decoding: utf8[(i + 1)...(i + 2)], as: UTF8.self), radix: 16) {
                    bytes.append(byte)
                    i += 3
                } else {
                    bytes.append(utf8[i])
                    i += 1
                }
            }
            return String(decoding: bytes, as: UTF8.self)
        }
        return body
    }

    static func stripHTML(_ html: String) -> String {
        var text = html
        for (pattern, replacement) in [
            ("(?is)<(script|style)[^>]*>.*?</\\1>", ""),
            ("(?i)<br\\s*/?>", "\n"),
            ("(?i)</(p|div|tr|li|h[1-6]|table)>", "\n"),
            ("(?i)</t[dh]>", "  "),
            ("<[^>]+>", ""),
        ] {
            text = text.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
        }
        for (entity, character) in [("&nbsp;", " "), ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&#x27;", "'")] {
            text = text.replacingOccurrences(of: entity, with: character)
        }
        return text
    }
}
