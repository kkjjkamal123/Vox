import Foundation

/// Exact arithmetic and unit/currency conversion, so numbers never come from the language model.
enum Calc {
    // MARK: Arithmetic

    /// "25 times 4", "15 percent of 200", "square root of 144", "2 to the power of 10", "(3 + 4) * 2".
    static func evaluate(_ spoken: String) -> Double? {
        var s = " " + spoken.lowercased() + " "
        let replacements: [(String, String)] = [
            ("what's", ""), ("what is", ""), ("calculate", ""), ("how much is", ""), ("equals", ""), ("?", ""), (",", ""),
            ("multiplied by", "*"), ("times", "*"), (" x ", " * "), ("×", "*"), ("divided by", "/"), ("over", "/"), ("÷", "/"),
            ("plus", "+"), ("minus", "-"), ("to the power of", "^"), ("raised to", "^"), ("squared", "^2"), ("cubed", "^3"),
            ("square root of", "√"), ("sqrt", "√"), ("percent of", "%of"), ("% of", "%of"), ("percent", "%"),
            ("open bracket", "("), ("close bracket", ")"), ("point", "."), ("the", ""), ("and", ""),
        ]
        for (a, b) in replacements { s = s.replacingOccurrences(of: a, with: b) }
        s = s.replacingOccurrences(of: " ", with: "")
        guard s.contains(where: \.isNumber), s.contains(where: { "+-*/^√%".contains($0) }) || s.hasPrefix("√") else { return nil }
        guard s.allSatisfy({ $0.isNumber || "+-*/^√%.()of".contains($0) }) else { return nil }
        var p = MathParser(Array(s))
        guard let v = p.expression(), p.atEnd, v.isFinite else { return nil }
        return v
    }

    static func format(_ v: Double) -> String {
        if v == v.rounded(), abs(v) < 1e15 { return String(Int64(v)) }
        let f = NumberFormatter()
        f.maximumFractionDigits = 4
        f.minimumFractionDigits = 0
        return f.string(from: NSNumber(value: v)) ?? "\(v)"
    }

    private struct MathParser {
        let c: [Character]
        var i = 0
        init(_ c: [Character]) { self.c = c }
        var atEnd: Bool { i >= c.count }

        mutating func expression() -> Double? {
            guard var v = term() else { return nil }
            while i < c.count, c[i] == "+" || c[i] == "-" {
                let op = c[i]; i += 1
                guard let r = term() else { return nil }
                v = op == "+" ? v + r : v - r
            }
            return v
        }
        mutating func term() -> Double? {
            guard var v = power() else { return nil }
            while i < c.count {
                if c[i] == "*" || c[i] == "/" {
                    let op = c[i]; i += 1
                    guard let r = power() else { return nil }
                    v = op == "*" ? v * r : v / r
                } else if c[i] == "%", i + 2 < c.count, c[i + 1] == "o", c[i + 2] == "f" {
                    i += 3
                    guard let r = power() else { return nil }
                    v = v / 100 * r
                } else if c[i] == "%" {
                    i += 1; v /= 100
                } else { break }
            }
            return v
        }
        mutating func power() -> Double? {
            guard let base = unary() else { return nil }
            if i < c.count, c[i] == "^" {
                i += 1
                guard let e = power() else { return nil }
                return pow(base, e)
            }
            return base
        }
        mutating func unary() -> Double? {
            if i < c.count, c[i] == "-" { i += 1; return unary().map { -$0 } }
            if i < c.count, c[i] == "√" { i += 1; return unary().map { sqrt($0) } }
            return primary()
        }
        mutating func primary() -> Double? {
            if i < c.count, c[i] == "(" {
                i += 1
                let v = expression()
                guard i < c.count, c[i] == ")" else { return nil }
                i += 1
                return v
            }
            let start = i
            while i < c.count, c[i].isNumber || c[i] == "." { i += 1 }
            return i > start ? Double(String(c[start..<i])) : nil
        }
    }

    // MARK: Units

    private static let units: [String: Dimension] = [
        "km": UnitLength.kilometers, "kilometer": UnitLength.kilometers, "kilometre": UnitLength.kilometers,
        "mile": UnitLength.miles, "m": UnitLength.meters, "meter": UnitLength.meters, "metre": UnitLength.meters,
        "cm": UnitLength.centimeters, "centimeter": UnitLength.centimeters, "centimetre": UnitLength.centimeters,
        "mm": UnitLength.millimeters, "millimeter": UnitLength.millimeters, "foot": UnitLength.feet, "feet": UnitLength.feet,
        "ft": UnitLength.feet, "inch": UnitLength.inches, "inches": UnitLength.inches, "yard": UnitLength.yards,
        "kg": UnitMass.kilograms, "kilogram": UnitMass.kilograms, "kilo": UnitMass.kilograms, "gram": UnitMass.grams, "g": UnitMass.grams,
        "pound": UnitMass.pounds, "lb": UnitMass.pounds, "lbs": UnitMass.pounds, "ounce": UnitMass.ounces, "oz": UnitMass.ounces,
        "celsius": UnitTemperature.celsius, "centigrade": UnitTemperature.celsius, "fahrenheit": UnitTemperature.fahrenheit,
        "kelvin": UnitTemperature.kelvin, "degree": UnitTemperature.celsius,
        "liter": UnitVolume.liters, "litre": UnitVolume.liters, "l": UnitVolume.liters, "ml": UnitVolume.milliliters,
        "milliliter": UnitVolume.milliliters, "millilitre": UnitVolume.milliliters, "gallon": UnitVolume.gallons,
        "cup": UnitVolume.cups, "teaspoon": UnitVolume.teaspoons, "tablespoon": UnitVolume.tablespoons,
        "mph": UnitSpeed.milesPerHour, "kmh": UnitSpeed.kilometersPerHour, "kph": UnitSpeed.kilometersPerHour,
        "hour": UnitDuration.hours, "minute": UnitDuration.minutes, "second": UnitDuration.seconds,
        "gb": UnitInformationStorage.gigabytes, "gigabyte": UnitInformationStorage.gigabytes, "mb": UnitInformationStorage.megabytes,
        "megabyte": UnitInformationStorage.megabytes, "tb": UnitInformationStorage.terabytes, "terabyte": UnitInformationStorage.terabytes,
    ]

    static let currencies: [String: String] = [
        "dollar": "USD", "usd": "USD", "buck": "USD", "rupee": "INR", "inr": "INR", "rs": "INR", "euro": "EUR", "eur": "EUR",
        "pound": "GBP", "gbp": "GBP", "sterling": "GBP", "yen": "JPY", "yuan": "CNY", "dirham": "AED", "aed": "AED",
        "riyal": "SAR", "ringgit": "MYR", "singapore dollar": "SGD", "canadian dollar": "CAD", "australian dollar": "AUD",
        "franc": "CHF", "won": "KRW", "baht": "THB", "taka": "BDT", "bitcoin": "BTC",
    ]

    private static func singular(_ w: String) -> String {
        let w = w.lowercased().trimmingCharacters(in: .punctuationCharacters)
        if w == "feet" || w == "inches" || w == "lbs" || w == "celsius" || w == "degrees" { return w == "degrees" ? "degree" : w }
        return w.hasSuffix("s") && w.count > 3 ? String(w.dropLast()) : w
    }

    /// "convert 10 km to miles", "100 dollars in rupees", "how many grams in 2 pounds".
    struct Conversion { let amount: Double; let from: String; let to: String; let isCurrency: Bool }

    static func parseConversion(_ words: [String]) -> Conversion? {
        let text = words.map { $0.lowercased() }.joined(separator: " ")
        // amount + unit (to|in|into) unit
        let pattern = #/(?:convert\s+|what(?:'s| is)\s+|how much is\s+)?([\d.,]+)\s+([a-z ]+?)\s+(?:to|in|into)\s+([a-z ]+)$/#
        guard let m = text.firstMatch(of: pattern),
              let amount = Double(m.1.replacingOccurrences(of: ",", with: "")) else { return nil }
        let fromWord = String(m.2), toWord = String(m.3)
        let fromKey = singular(fromWord), toKey = singular(toWord)
        if let f = currencies[fromKey] ?? currencies[fromWord], let t = currencies[toKey] ?? currencies[toWord] {
            return Conversion(amount: amount, from: f, to: t, isCurrency: true)
        }
        guard units[fromKey] != nil, units[toKey] != nil else { return nil }
        return Conversion(amount: amount, from: fromKey, to: toKey, isCurrency: false)
    }

    static func convertUnits(_ c: Conversion) -> String? {
        guard let f = units[c.from], let t = units[c.to], type(of: f) == type(of: t) else { return nil }
        let v = Measurement(value: c.amount, unit: f).converted(to: t).value
        return "\(format(c.amount)) \(f.symbol) is \(format((v * 100).rounded() / 100)) \(t.symbol)"
    }

    static func convertCurrency(_ c: Conversion) async -> String {
        guard let url = URL(string: "https://open.er-api.com/v6/latest/\(c.from)"),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rate = ((json["rates"] as? [String: Any])?[c.to] as? NSNumber)?.doubleValue else {
            return "I couldn't get exchange rates right now."
        }
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.maximumFractionDigits = 2
        f.currencyCode = c.from
        let a = f.string(from: NSNumber(value: c.amount)) ?? "\(c.amount) \(c.from)"
        f.currencyCode = c.to
        let b = f.string(from: NSNumber(value: c.amount * rate)) ?? "\(c.amount * rate) \(c.to)"
        return "\(a) is about \(b)"
    }
}
