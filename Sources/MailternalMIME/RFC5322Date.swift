import Foundation

func parseRFC5322Date(_ input: String) -> Date? {
    let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty { return nil }
    if let rfc = parseRFC5322Tokens(trimmed) { return rfc }
    if let iso = parseISO8601Date(trimmed) { return iso }
    if let slash = parseSlashDate(trimmed) { return slash }
    return nil
}

private let weekdays: Set<String> = [
    "sun", "sunday", "mon", "monday", "tue", "tues", "tuesday",
    "wed", "wednesday", "thu", "thur", "thurs", "thursday",
    "fri", "friday", "sat", "saturday",
]

private let months: [String: Int] = [
    "jan": 1, "january": 1,
    "feb": 2, "february": 2,
    "mar": 3, "march": 3,
    "apr": 4, "april": 4,
    "may": 5,
    "jun": 6, "june": 6,
    "jul": 7, "july": 7,
    "aug": 8, "august": 8,
    "sep": 9, "sept": 9, "september": 9,
    "oct": 10, "october": 10,
    "nov": 11, "november": 11,
    "dec": 12, "december": 12,
]

private let namedZones: [String: Int] = [
    "ut": 0, "utc": 0, "gmt": 0, "z": 0,
    "est": -5 * 3600, "edt": -4 * 3600,
    "cst": -6 * 3600, "cdt": -5 * 3600,
    "mst": -7 * 3600, "mdt": -6 * 3600,
    "pst": -8 * 3600, "pdt": -7 * 3600,
    "a": 1 * 3600, "b": 2 * 3600, "c": 3 * 3600, "d": 4 * 3600,
    "e": 5 * 3600, "f": 6 * 3600, "g": 7 * 3600, "h": 8 * 3600,
    "i": 9 * 3600, "k": 10 * 3600, "l": 11 * 3600, "m": 12 * 3600,
    "n": -1 * 3600, "o": -2 * 3600, "p": -3 * 3600, "q": -4 * 3600,
    "r": -5 * 3600, "s": -6 * 3600, "t": -7 * 3600, "u": -8 * 3600,
    "v": -9 * 3600, "w": -10 * 3600, "x": -11 * 3600, "y": -12 * 3600,
]

private func parseRFC5322Tokens(_ input: String) -> Date? {
    var cleaned = input
    cleaned = cleaned.replacingOccurrences(of: "(", with: " ")
    cleaned = cleaned.replacingOccurrences(of: ")", with: " ")
    cleaned = cleaned.replacingOccurrences(of: ",", with: " ")

    let tokens = cleaned.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "\r" })
        .map(String.init)
        .filter { !$0.isEmpty }
    guard !tokens.isEmpty else { return nil }

    var idx = 0
    if idx < tokens.count, weekdays.contains(tokens[idx].lowercased()) {
        idx += 1
    }

    var day: Int?
    var month: Int?
    var year: Int?

    if idx < tokens.count, let m = months[tokens[idx].lowercased()] {
        // asctime: Mon Jan  2 15:04:05 2006 / Aug 31 2026 16:22:00
        month = m
        idx += 1
        if idx < tokens.count, let d = Int(tokens[idx]) {
            day = d
            idx += 1
        }
        // year may follow time (asctime) — handled below
    } else {
        if idx < tokens.count, let d = Int(tokens[idx].trimmingCharacters(in: CharacterSet(charactersIn: "."))) {
            day = d
            idx += 1
        }
        if idx < tokens.count, let m = months[tokens[idx].lowercased()] {
            month = m
            idx += 1
        }
        if idx < tokens.count, let y = parseYearToken(tokens[idx]) {
            year = y
            idx += 1
        }
    }

    guard let day, let month, day >= 1, day <= 31, month >= 1, month <= 12 else { return nil }

    var hour = 0, minute = 0, second = 0
    func consumeTime(at i: Int) -> Int? {
        guard i < tokens.count, tokens[i].contains(":") else { return nil }
        let parts = tokens[i].split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count >= 2, let h = Int(parts[0]), let mi = Int(parts[1]) else { return nil }
        hour = h
        minute = mi
        if parts.count >= 3 {
            second = Int(parts[2].prefix(while: { $0.isNumber })) ?? 0
        }
        return i + 1
    }
    if let next = consumeTime(at: idx) {
        idx = next
    } else if year == nil, idx < tokens.count, let y = parseYearToken(tokens[idx]) {
        year = y
        idx += 1
        if let next = consumeTime(at: idx) {
            idx = next
        }
    }
    if year == nil, idx < tokens.count, let y = parseYearToken(tokens[idx]) {
        year = y
        idx += 1
    }


    var offset = 0
    var sawZone = false
    if idx < tokens.count, let z = parseZoneToken(tokens[idx]) {
        offset = z
        sawZone = true
        idx += 1
    }
    if !sawZone {
        // Common broken form: Date without zone — treat as UTC.
        offset = 0
    }

    guard let year else { return nil }
    return dateComponentsUTC(year: year, month: month, day: day, hour: hour, minute: minute, second: second, offset: offset)
}

private func parseYearToken(_ tok: String) -> Int? {
    let digits = tok.prefix(while: { $0.isNumber })
    guard let y = Int(digits) else { return nil }
    if digits.count == 2 {
        return y < 50 ? 2000 + y : 1900 + y
    }
    if digits.count == 3 {
        return 1900 + y
    }
    if digits.count >= 4 {
        return y
    }
    return nil
}

private func parseZoneToken(_ raw: String) -> Int? {
    var t = raw
    let upper = t.uppercased()
    if upper.hasPrefix("GMT") { t = String(t.dropFirst(3)) }
    else if upper.hasPrefix("UTC") { t = String(t.dropFirst(3)) }
    if t.isEmpty { return 0 }
    if t == "+" || t == "-" { return 0 }

    if let named = namedZones[t.lowercased()] { return named }

    var sign = 1
    var rest = t
    if rest.hasPrefix("+") {
        rest = String(rest.dropFirst())
    } else if rest.hasPrefix("-") {
        sign = -1
        rest = String(rest.dropFirst())
    }

    rest = rest.replacingOccurrences(of: ":", with: "")
    let digits = rest.filter(\.isNumber)


    if digits.count == 2, let h = Int(digits) {
        return sign * h * 3600
    }
    let hh = Int(digits.prefix(2)) ?? 0
    let mm = Int(digits.dropFirst(2).prefix(2)) ?? 0
    return sign * (hh * 3600 + mm * 60)
}

private func parseISO8601Date(_ input: String) -> Date? {
    // yyyy-MM-dd[T| ]HH:mm:ss[.frac][Z|±HH:MM]
    let s = input.trimmingCharacters(in: .whitespacesAndNewlines)
    guard s.count >= 10, s[s.index(s.startIndex, offsetBy: 4)] == "-" else { return nil }
    let chars = Array(s)
    guard chars.count >= 10 else { return nil }
    guard let year = Int(String(chars[0..<4])),
          let month = Int(String(chars[5..<7])),
          let day = Int(String(chars[8..<10])) else { return nil }

    var hour = 0, minute = 0, second = 0, offset = 0
    if chars.count >= 19, chars[10] == "T" || chars[10] == " " || chars[10] == "t" {
        guard let h = Int(String(chars[11..<13])),
              let mi = Int(String(chars[14..<16])),
              let se = Int(String(chars[17..<19])) else { return nil }
        hour = h
        minute = mi
        second = se
        var i = 19
        if i < chars.count && chars[i] == "." {
            i += 1
            while i < chars.count && chars[i].isNumber { i += 1 }
        }
        if i < chars.count {
            let zone = String(chars[i...])
            if zone == "Z" || zone == "z" {
                offset = 0
            } else if let z = parseZoneToken(zone) {
                offset = z
            }
        }
    }
    return dateComponentsUTC(year: year, month: month, day: day, hour: hour, minute: minute, second: second, offset: offset)
}

private func parseSlashDate(_ input: String) -> Date? {
    // 31/08/2026 [HH:mm[:ss]] or 2026/08/31
    let parts = input.split(whereSeparator: { $0 == " " || $0 == "T" || $0 == "t" })
    guard let datePart = parts.first else { return nil }
    let nums = datePart.split(separator: "/").compactMap { Int($0) }
    guard nums.count == 3 else { return nil }
    let year: Int
    let month: Int
    let day: Int
    if nums[0] > 31 {
        year = nums[0]
        month = nums[1]
        day = nums[2]
    } else if nums[2] > 31 {
        day = nums[0]
        month = nums[1]
        year = nums[2]
    } else {
        return nil
    }
    var hour = 0, minute = 0, second = 0
    if parts.count >= 2 {
        let t = parts[1].split(separator: ":")
        if t.count >= 2 {
            hour = Int(t[0]) ?? 0
            minute = Int(t[1]) ?? 0
            if t.count >= 3 { second = Int(t[2].prefix(while: \.isNumber)) ?? 0 }
        }
    }
    return dateComponentsUTC(year: year, month: month, day: day, hour: hour, minute: minute, second: second, offset: 0)
}

private func dateComponentsUTC(
    year: Int, month: Int, day: Int, hour: Int, minute: Int, second: Int, offset: Int
) -> Date? {
    var dc = DateComponents()
    dc.calendar = Calendar(identifier: .gregorian)
    dc.timeZone = TimeZone(secondsFromGMT: offset)
    dc.year = year
    dc.month = month
    dc.day = day
    dc.hour = hour
    dc.minute = minute
    dc.second = second
    return dc.date
}
