import Foundation

/// Formatting only: all quantities, levels and remainders are server-confirmed.
enum AccountDisplay {
    static func amount(_ value: String?, locale: Locale = .current) -> String {
        guard let value = value, let number = APIAccountSummary.amount(value) else { return "Unavailable" }
        return number.formatted(.number.locale(locale))
    }

    static func amount(_ value: Int64, locale: Locale = .current) -> String {
        amount(String(value), locale: locale)
    }

    static func date(_ value: Date, timezone: String, includesTime: Bool = false) -> String {
        let formatter = DateFormatter()
        formatter.timeZone = TimeZone(identifier: timezone)
        formatter.dateStyle = .medium
        formatter.timeStyle = includesTime ? .short : .none
        return formatter.string(from: value)
    }

    static func gemBalance(_ wallet: APIAccountWallet?) -> String {
        guard let wallet = wallet else { return "Unavailable" }
        return wallet.initialized ? amount(wallet.gemBalance) : "Preparing"
    }
}

struct AccountProgressDisplay {
    let progression: APIAccountProgression
    var level: String { "Level \(AccountDisplay.amount(progression.level))" }
    var nextLevel: String { "Level \(AccountDisplay.amount(progression.level + 1))" }
    var xp: String { "\(AccountDisplay.amount(progression.xpIntoLevel)) / \(AccountDisplay.amount(progression.xpForNextLevel)) XP" }
    var gemSteps: String { "\(AccountDisplay.amount(progression.stepsIntoNextGem)) / \(AccountDisplay.amount(progression.stepsPerGem)) steps" }
    var gemRemaining: String { "\(AccountDisplay.amount(progression.stepsToNextGem)) steps to your next gem" }
    var xpFraction: Double {
        Self.fraction(APIAccountSummary.amount(progression.xpIntoLevel), APIAccountSummary.amount(progression.xpForNextLevel))
    }
    var gemFraction: Double { Self.fraction(progression.stepsIntoNextGem, progression.stepsPerGem) }

    private static func fraction(_ value: Int64?, _ total: Int64?) -> Double {
        guard let value = value, let total = total, value >= 0, total > 0 else { return 0 }
        return min(1, max(0, Double(value) / Double(total)))
    }
}

enum ProfileSection: String, Hashable {
    case overview, currency
}
