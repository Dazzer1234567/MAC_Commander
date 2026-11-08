import Foundation

/// Reduces text to what ISO 8859-1 can hold. Pasting from a browser or a word processor
/// drags in curly quotes, long dashes, non-breaking spaces and invisible marks; this turns
/// them into their plain equivalents so what comes back out is ordinary text.
enum PlainText {
    /// The highest code point ISO 8859-1 can represent.
    private static let latin1Max: UInt32 = 0xFF

    /// Characters with an obvious plain spelling. Accented Latin letters are deliberately
    /// absent: they fit in ISO 8859-1 and should survive untouched. Written as code points
    /// because half of them are invisible.
    private static let equivalents: [UInt32: String] = [
        // quotes
        0x2018: "'", 0x2019: "'", 0x201A: "'", 0x201B: "'",
        0x2032: "'", 0x02BC: "'",
        0x201C: "\"", 0x201D: "\"", 0x201E: "\"", 0x201F: "\"",
        0x2033: "\"",

        // dashes and minus signs
        0x2010: "-", 0x2011: "-", 0x2012: "-", 0x2013: "-",
        0x2014: "-", 0x2015: "-", 0x2212: "-",

        // spaces that are not a plain space
        0x00A0: " ", 0x2000: " ", 0x2001: " ", 0x2002: " ",
        0x2003: " ", 0x2004: " ", 0x2005: " ", 0x2006: " ",
        0x2007: " ", 0x2008: " ", 0x2009: " ", 0x200A: " ",
        0x202F: " ", 0x205F: " ", 0x3000: " ",

        // marks that carry no meaning once the formatting is gone
        0x200B: "", 0x200C: "", 0x200D: "", 0xFEFF: "",
        0x00AD: "",

        // symbols a page is likely to contain
        0x2026: "...",
        0x2022: "*", 0x25CF: "*", 0x25AA: "*", 0x2043: "-",
        0x2122: "(TM)",
        0x20AC: "EUR",     // not in ISO 8859-1, despite appearances
        0x2192: "->", 0x2190: "<-",
        0x00BC: "1/4", 0x00BD: "1/2", 0x00BE: "3/4",
    ]

    /// Cleans a block of text: plain equivalents for typographic characters, accents kept
    /// where ISO 8859-1 allows them, anything else dropped, and line endings normalised.
    static func clean(_ text: String) -> String {
        if text.isEmpty { return "" }

        // Walked a code point at a time, not a Character at a time: Swift would glue an "e"
        // and a combining accent into one Character, and the accent has to be judged alone.
        var result = String.UnicodeScalarView()
        var previousWasCR = false

        for scalar in text.unicodeScalars {
            let value = scalar.value

            // "\r\n", a lone "\r" and "\n" all become one newline
            if value == 0x0D { result.append("\n"); previousWasCR = true; continue }
            if value == 0x0A {
                if !previousWasCR { result.append("\n") }
                previousWasCR = false
                continue
            }
            previousWasCR = false

            if value == 0x09 { result.append(scalar); continue }

            // other control characters carry formatting, not text
            if value < 0x20 || (0x7F...0x9F).contains(value) { continue }

            if let plain = equivalents[value] { result.append(contentsOf: plain.unicodeScalars); continue }
            if value <= latin1Max { result.append(scalar); continue }

            // Above U+FFFF - emoji and the like. There is nothing to fold it to.
            if value > 0xFFFF { continue }

            result.append(contentsOf: fold(scalar))
        }

        return String(result)
    }

    /// Last resort for a character ISO 8859-1 cannot hold: strip its accents and keep the
    /// base letter if that fits. Anything with no Latin form at all - CJK, emoji - is dropped
    /// rather than replaced with a row of question marks.
    private static func fold(_ scalar: Unicode.Scalar) -> [Unicode.Scalar] {
        let decomposed = String(scalar).decomposedStringWithCanonicalMapping
        return decomposed.unicodeScalars.filter {
            $0.properties.generalCategory != .nonspacingMark && $0.value <= latin1Max
        }
    }

    /// True when the text is already what `clean` would produce.
    static func isClean(_ text: String) -> Bool {
        // Compared as code points: Swift's == would call a decomposed "é" equal to the
        // composed one, and the cleaner treats them differently.
        Array(clean(text).unicodeScalars) == Array(text.unicodeScalars)
    }
}
