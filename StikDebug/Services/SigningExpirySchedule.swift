import Foundation

enum SigningExpirySchedule {
    static let identifierPrefix = "stikdebugvn.signing-expiry."
    static let interval: TimeInterval = 3 * 3600
    static let window: TimeInterval = 24 * 3600

    static func dates(expiry: Date, enabledAt: Date, now: Date) -> [Date] {
        let first = max(expiry.addingTimeInterval(-window), enabledAt.addingTimeInterval(5))
        return (0..<8).compactMap { index in
            let date = first.addingTimeInterval(Double(index) * interval)
            return date > now && date < expiry ? date : nil
        }
    }
}
