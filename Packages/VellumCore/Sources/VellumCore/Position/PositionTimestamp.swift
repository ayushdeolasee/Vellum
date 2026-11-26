import Foundation

public enum PositionTimestamp {
    public static func string(from date: Date) -> String { rfc3339Formatter.string(from: date) }

    private static let rfc3339Formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSSSS'+00:00'"
        return formatter
    }()

    /// Lenient parse for record timestamps: our writer's 6-digit-fraction
    /// RFC3339 first, then ISO8601 with/without fractional seconds (Tauri-era
    /// chrono emitted variable fraction widths).
    public static func parse(_ value: String?) -> Date? {
        guard let value, !value.isEmpty else { return nil }
        if let date = rfc3339Formatter.date(from: value) { return date }
        if let date = iso8601Fractional.date(from: value) { return date }
        return iso8601Plain.date(from: value)
    }

    private static let iso8601Fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let iso8601Plain: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}
