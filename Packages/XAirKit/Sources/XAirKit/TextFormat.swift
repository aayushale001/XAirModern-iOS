import Foundation

/// Port of the original app's private printf (`myspf`, 0x100016fc4).
/// Differences from C printf that matter for X-Air text: `%f` defaults to 0
/// decimals, a `k` flag prints values >= 1000 as `1k97`, `%b` prints binary,
/// output digits are truncated after adding a fixed rounding offset.
public enum XAirPrintf {
    // myvspf::rndfi (0x1002d4c38), float32 in the binary.
    private static let roundOffset: [Double] = [0.5, 0.05, 0.005, 0.0005].map { Double(Float($0)) }

    public static func format(_ fmt: String, _ value: Double) -> String {
        var out = ""
        var it = Array(fmt.utf8)[...]
        while let c = it.popFirst() {
            guard c == UInt8(ascii: "%") else { out.unicodeScalars.append(Unicode.Scalar(c)); continue }
            var plus = false, zero = false, kflag = false, hasDot = false, widthGiven = false
            var width = 0, prec = 0
            var conv: UInt8 = 0
            parse: while let d = it.popFirst() {
                switch d {
                case UInt8(ascii: "%"): conv = d; break parse
                case UInt8(ascii: "+"): plus = true
                case UInt8(ascii: "0") where !hasDot && width == 0: zero = true
                case UInt8(ascii: "."): hasDot = true
                case UInt8(ascii: "k"): kflag = true; hasDot = true
                case UInt8(ascii: "0")...UInt8(ascii: "9"):
                    let n = Int(d - UInt8(ascii: "0"))
                    if hasDot { prec = prec * 10 + n } else { width = width * 10 + n; widthGiven = true }
                default: conv = d; break parse
                }
            }
            switch conv {
            case UInt8(ascii: "%"): out += "%"
            case UInt8(ascii: "f"): out += formatFloat(value, width: width, widthGiven: widthGiven, hasDot: hasDot, prec: prec, plus: plus, zero: zero, k: kflag)
            case UInt8(ascii: "d"): out += formatInt(Int(value), radix: 10, width: width, plus: plus, zero: zero)
            case UInt8(ascii: "b"): out += formatInt(Int(value), radix: 2, width: width, plus: false, zero: zero)
            case UInt8(ascii: "x"), UInt8(ascii: "X"): out += formatInt(Int(value), radix: 16, width: width, plus: false, zero: zero)
            default: out += "?"
            }
        }
        return out
    }

    /// Mirrors myspf's `%f` branch: with an explicit width, the decimals shown are
    /// whatever fits (width - dot - sign - integer digits), not the precision;
    /// when nothing fits after a dot, one fill character is written instead.
    static func formatFloat(_ v: Double, width: Int, widthGiven: Bool = false, hasDot: Bool = false,
                            prec p: Int, plus: Bool, zero: Bool, k: Bool) -> String {
        var prec = p
        let negative = v < 0
        var a = abs(v)
        if prec < 4 { a += roundOffset[prec] }
        var sep: Character = "."
        var kApplied = false
        if k && a >= 1000 { prec += 1; a /= 1000; sep = "k"; kApplied = true }
        var intDigits = 1
        var scale = 1.0
        while scale * 10 <= a { scale *= 10; intDigits += 1 }
        let showSign = negative || plus
        let room = width - (hasDot ? 1 : 0) - (showSign ? 1 : 0) - intDigits
        let fill: Character = zero ? "0" : " "
        var lead = ""
        var decimals = prec
        if widthGiven {
            if room == 0 && hasDot && !kApplied {
                lead = String(fill)
                decimals = 0
            } else if room > prec {
                lead = String(repeating: fill, count: room - prec)
                decimals = prec
            } else {
                decimals = max(room, 0)
            }
        }
        var digits = ""
        var rem = a
        for _ in 0..<intDigits {
            var d = Int(rem / scale)
            if d > 9 { d = 9 }
            if d < 0 { d = 0 }
            digits.append(Character(Unicode.Scalar(UInt8(48 + d))))
            rem -= Double(d) * scale
            scale /= 10
        }
        if decimals > 0 {
            digits.append(sep)
            for _ in 0..<decimals {
                rem *= 10
                var d = Int(rem)
                if d > 9 { d = 9 }
                if d < 0 { d = 0 }
                rem -= Double(d)
                digits.append(Character(Unicode.Scalar(UInt8(48 + d))))
            }
        }
        let sign = negative ? "-" : (plus ? "+" : "")
        return zero ? sign + lead + digits : lead + sign + digits
    }

    static func formatInt(_ v: Int, radix: Int, width: Int, plus: Bool, zero: Bool) -> String {
        let negative = v < 0
        let body = String(abs(v), radix: radix, uppercase: true)
        let sign = negative ? "-" : (plus ? "+" : "")
        return pad(sign: sign, body: body, width: width, zero: zero)
    }

    private static func pad(sign: String, body: String, width: Int, zero: Bool) -> String {
        let len = sign.count + body.count
        guard len < width else { return sign + body }
        let fill = String(repeating: zero ? "0" : " ", count: width - len)
        return zero ? sign + fill + body : fill + sign + body
    }
}

public enum ValueText {
    /// Cparam::getString — the token the app writes into scene files and node text.
    public static func text(spec: ParamSpec, index: Int, string: String = "") -> String {
        switch spec.kind {
        case .string: return string
        case .int(_, _, let fmt): return XAirPrintf.format(fmt, Double(index))
        case .enumeration(let items): return index >= 0 && index < items.count ? items[index] : "?"
        case .linear(_, _, _, let fmt), .log(_, _, _, let fmt):
            return XAirPrintf.format(fmt, Double(spec.value(forIndex: index)))
        case .fader, .sendLevel:
            let v = spec.value(forIndex: index)
            if v > -0.01 && v < 0.01 { return "  0.0" }
            if v > -90 { return XAirPrintf.format("%+5.1f", Double(v)) }
            return "  -oo"
        }
    }

    /// Display string for UI (trimmed, with `-∞` for off levels).
    public static func display(spec: ParamSpec, index: Int, string: String = "") -> String {
        let t = text(spec: spec, index: index, string: string).trimmingCharacters(in: .whitespaces)
        return t == "-oo" ? "-∞" : t
    }

    /// Cparam::setString — parses one token. Returns the new index (or string) or nil if rejected.
    public static func parse(spec: ParamSpec, token raw: String) -> (index: Int, string: String)? {
        let token = raw
        guard let first = token.utf8.first else { return spec.isString ? (0, "") : nil }
        if first == UInt8(ascii: "\\") { return nil } // "unchanged" marker
        switch spec.kind {
        case .string(let maxLen):
            return (0, String(token.prefix(maxLen)))
        case .int:
            guard let v = parseInteger(token) else { return nil }
            return (spec.clamp(v), "")
        case .enumeration(let items):
            if first == UInt8(ascii: "#") {
                guard let v = parseInteger(String(token.dropFirst())) else { return nil }
                return (spec.clamp(v), "")
            }
            guard let i = items.firstIndex(of: token) else { return nil }
            return (i, "")
        case .fader, .sendLevel:
            if token.hasPrefix("-oo") { return (0, "") }
            guard let v = parseNumber(token) else { return nil }
            return (spec.index(forValue: v), "")
        case .linear, .log:
            guard let v = parseNumber(token) else { return nil }
            return (spec.index(forValue: v), "")
        }
    }

    /// Integer with optional sign, or `%` binary.
    static func parseInteger(_ s: String) -> Int? {
        var bytes = Array(s.utf8)[...]
        guard let f = bytes.first else { return nil }
        var radix = 10, negative = false
        if f == UInt8(ascii: "-") { negative = true; bytes = bytes.dropFirst() }
        else if f == UInt8(ascii: "+") { bytes = bytes.dropFirst() }
        else if f == UInt8(ascii: "%") { radix = 2; bytes = bytes.dropFirst() }
        var v = 0, any = false
        for b in bytes {
            let d = Int(b) - 48
            guard d >= 0, d < radix else { break }
            guard v <= (Int.max - d) / radix else { return nil }
            v = v * radix + d; any = true
        }
        guard any else { return nil }
        return negative ? -v : v
    }

    /// Decimal with `.` or `k` (`1k97` = 1970).
    static func parseNumber(_ s: String) -> Float? {
        var bytes = Array(s.utf8)[...]
        guard let f = bytes.first else { return nil }
        var negative = false
        if f == UInt8(ascii: "-") { negative = true; bytes = bytes.dropFirst() }
        else if f == UInt8(ascii: "+") { bytes = bytes.dropFirst() }
        var value: Float = 0, frac: Float = 0.1, inFrac = false, any = false
        for b in bytes {
            if b == UInt8(ascii: ".") {
                if inFrac { break }
                inFrac = true
            } else if b == UInt8(ascii: "k") {
                if inFrac { break }
                value *= 1000; inFrac = true; frac = 100
            } else if b >= 48, b <= 57 {
                let d = Float(Int(b) - 48)
                if inFrac { value += d * frac; frac /= 10 } else { value = value * 10 + d }
                any = true
            } else { break }
        }
        guard any, value.isFinite else { return nil }
        return negative ? -value : value
    }
}

/// Node text lines, as written to scene/preset files and carried in `node ,s` replies:
/// `path tok tok ...` with strings in double quotes (Cnode::getAllParams / processLine).
public enum NodeText {
    public static func tokenize(_ line: String) -> [String] {
        var tokens: [String] = []
        var cur = ""
        var inQuote = false, hadQuote = false
        for ch in line {
            if inQuote {
                if ch == "\"" { inQuote = false } else { cur.append(ch) }
            } else if ch == "\"" {
                inQuote = true; hadQuote = true
            } else if ch == " " || ch == "\t" || ch == "\r" || ch == "\n" {
                if !cur.isEmpty || hadQuote { tokens.append(cur); cur = ""; hadQuote = false }
            } else {
                cur.append(ch)
            }
        }
        if !cur.isEmpty || hadQuote { tokens.append(cur) }
        return tokens
    }

    public static func encodeToken(spec: ParamSpec, index: Int, string: String) -> String {
        if spec.isString { return "\"" + string.replacingOccurrences(of: "\"", with: "'") + "\"" }
        return ValueText.text(spec: spec, index: index)
    }
}
