import Foundation

public enum TokenFormatter {
    public static func compact(_ value: Int64) -> String {
        let absolute = value == Int64.min ? Double(Int64.max) : Double(Swift.abs(value))
        let sign = value < 0 ? "−" : ""

        let divisor: Double
        let suffix: String
        switch absolute {
        case 1_000_000_000...:
            divisor = 1_000_000_000
            suffix = "B"
        case 1_000_000...:
            divisor = 1_000_000
            suffix = "M"
        case 1_000...:
            divisor = 1_000
            suffix = "K"
        default:
            return "\(value)"
        }

        let scaled = absolute / divisor
        let decimals = scaled < 100 ? 1 : 0
        let format = decimals == 1 ? "%.1f" : "%.0f"
        var number = String(format: format, locale: Locale(identifier: "en_US_POSIX"), scaled)
        if number.hasSuffix(".0") {
            number.removeLast(2)
        }
        return "\(sign)\(number)\(suffix)"
    }

    public static func exact(_ value: Int64, locale: Locale = .current) -> String {
        value.formatted(.number.locale(locale))
    }

    /// Formats a USD amount stored as millionths of a dollar. Zero is shown
    /// as "$0.00" because it is an actual source-reported cost, not a token
    /// estimate invented by TokenBall.
    public static func usd(micros: Int64) -> String {
        let amount = Double(micros) / 1_000_000.0
        return String(
            format: "$%.2f",
            locale: Locale(identifier: "en_US_POSIX"),
            amount
        )
    }

    /// Formats a CNY amount stored as millionths of a yuan.
    public static func cny(micros: Int64) -> String {
        let amount = Double(micros) / 1_000_000.0
        return String(
            format: "¥%.2f",
            locale: Locale(identifier: "en_US_POSIX"),
            amount
        )
    }
}
