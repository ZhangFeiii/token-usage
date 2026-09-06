import Foundation

public struct DailyTokenUsage: Identifiable, Equatable, Sendable {
    public let date: Date
    public let tokens: Int64

    public var id: Date { date }

    public init(date: Date, tokens: Int64) {
        self.date = date
        self.tokens = tokens
    }
}

public struct ModelTokenUsage: Identifiable, Equatable, Sendable {
    public let model: String
    public let todayTokens: Int64
    public let sevenDayTokens: Int64
    public let fourteenDayTokens: Int64
    /// Cost reported by the source, represented in millionths of a USD.
    public let todayCostMicrosUSD: Int64
    public let sevenDayCostMicrosUSD: Int64
    public let fourteenDayCostMicrosUSD: Int64
    /// Estimated DeepSeek Harness cost, represented in millionths of a CNY.
    public let todayCostMicrosCNY: Int64
    public let sevenDayCostMicrosCNY: Int64
    public let fourteenDayCostMicrosCNY: Int64

    public var id: String { model }

    /// A compact label intended solely for UI presentation. `model` remains the
    /// original identifier used for persistence and stable SwiftUI identity.
    public var displayName: String {
        UsageModelDisplayNameFormatter.compact(model)
    }

    public init(model: String, todayTokens: Int64, sevenDayTokens: Int64) {
        self.init(
            model: model,
            todayTokens: todayTokens,
            sevenDayTokens: sevenDayTokens,
            fourteenDayTokens: sevenDayTokens,
            todayCostMicrosUSD: 0,
            sevenDayCostMicrosUSD: 0,
            fourteenDayCostMicrosUSD: 0,
            todayCostMicrosCNY: 0,
            sevenDayCostMicrosCNY: 0,
            fourteenDayCostMicrosCNY: 0
        )
    }

    public init(
        model: String,
        todayTokens: Int64,
        sevenDayTokens: Int64,
        fourteenDayTokens: Int64,
        todayCostMicrosUSD: Int64 = 0,
        sevenDayCostMicrosUSD: Int64 = 0,
        fourteenDayCostMicrosUSD: Int64 = 0,
        todayCostMicrosCNY: Int64 = 0,
        sevenDayCostMicrosCNY: Int64 = 0,
        fourteenDayCostMicrosCNY: Int64 = 0
    ) {
        self.model = model
        self.todayTokens = todayTokens
        self.sevenDayTokens = sevenDayTokens
        self.fourteenDayTokens = fourteenDayTokens
        self.todayCostMicrosUSD = todayCostMicrosUSD
        self.sevenDayCostMicrosUSD = sevenDayCostMicrosUSD
        self.fourteenDayCostMicrosUSD = fourteenDayCostMicrosUSD
        self.todayCostMicrosCNY = todayCostMicrosCNY
        self.sevenDayCostMicrosCNY = sevenDayCostMicrosCNY
        self.fourteenDayCostMicrosCNY = fourteenDayCostMicrosCNY
    }
}

public struct AgentUsage: Identifiable, Equatable, Sendable {
    public let id: String
    public let appType: String
    public let displayName: String
    public let todayTokens: Int64
    public let sevenDayTokens: Int64
    public let fourteenDayTokens: Int64
    public let dailyUsage: [DailyTokenUsage]
    public let models: [ModelTokenUsage]

    public init(
        id: String,
        appType: String,
        displayName: String,
        todayTokens: Int64,
        sevenDayTokens: Int64,
        dailyUsage: [DailyTokenUsage],
        models: [ModelTokenUsage]
    ) {
        self.init(
            id: id,
            appType: appType,
            displayName: displayName,
            todayTokens: todayTokens,
            sevenDayTokens: sevenDayTokens,
            fourteenDayTokens: sevenDayTokens,
            dailyUsage: dailyUsage,
            models: models
        )
    }

    public init(
        id: String,
        appType: String,
        displayName: String,
        todayTokens: Int64,
        sevenDayTokens: Int64,
        fourteenDayTokens: Int64,
        dailyUsage: [DailyTokenUsage],
        models: [ModelTokenUsage]
    ) {
        self.id = id
        self.appType = appType
        self.displayName = displayName
        self.todayTokens = todayTokens
        self.sevenDayTokens = sevenDayTokens
        self.fourteenDayTokens = fourteenDayTokens
        self.dailyUsage = dailyUsage
        self.models = models
    }
}

public struct UsageSnapshot: Equatable, Sendable {
    public let generatedAt: Date
    public let days: [Date]
    public let agents: [AgentUsage]

    public var todayTotal: Int64 {
        agents.reduce(0) { TokenArithmetic.addingWithoutOverflow($0, $1.todayTokens) }
    }

    public var sevenDayTotal: Int64 {
        agents.reduce(0) { TokenArithmetic.addingWithoutOverflow($0, $1.sevenDayTokens) }
    }

    public var fourteenDayTotal: Int64 {
        agents.reduce(0) { TokenArithmetic.addingWithoutOverflow($0, $1.fourteenDayTokens) }
    }

    /// Average usage across the latest 14 local calendar days, including today.
    public var fourteenDayAverage: Int64 {
        fourteenDayTotal / 14
    }

    public init(generatedAt: Date, days: [Date], agents: [AgentUsage]) {
        self.generatedAt = generatedAt
        self.days = days
        self.agents = agents
    }

    public static func empty(now: Date = Date(), calendar: Calendar = .current) -> UsageSnapshot {
        let today = calendar.startOfDay(for: now)
        let days = (-13...0).compactMap { offset in
            calendar.date(byAdding: .day, value: offset, to: today)
        }
        return UsageSnapshot(generatedAt: now, days: days, agents: [])
    }
}

public enum TokenArithmetic {
    public static func addingWithoutOverflow(_ lhs: Int64, _ rhs: Int64) -> Int64 {
        let (value, overflow) = lhs.addingReportingOverflow(rhs)
        guard overflow else { return value }
        return rhs >= 0 ? Int64.max : Int64.min
    }
}

public enum UsageModelDisplayNameFormatter {
    /// Shortens known DeepSeek V4 model identifiers for constrained UI layouts.
    /// All other identifiers are returned unchanged.
    public static func compact(_ modelID: String) -> String {
        if modelID == "deepseek-v4-flash-vision-exp" {
            return "dsv4-vision-exp"
        }
        guard modelID.hasPrefix("deepseek-v4-") else { return modelID }
        return "dsv4-" + modelID.dropFirst("deepseek-v4-".count)
    }
}

public struct AgentIdentity: Equatable, Sendable {
    public let id: String
    public let appType: String
    public let displayName: String
    public let sortPriority: Int

    public static func resolve(_ rawValue: String) -> AgentIdentity {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallback = trimmed.isEmpty ? "Unknown" : trimmed
        let normalized = fallback
            .lowercased()
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: " ", with: "")

        switch normalized {
        case "codex", "openai", "openaicodex":
            return AgentIdentity(id: "codex", appType: fallback, displayName: "Codex", sortPriority: 0)
        case "opencode", "opencodeai":
            return AgentIdentity(id: "opencode", appType: fallback, displayName: "OpenCode", sortPriority: 1)
        case "claude", "claudecode", "claudedesktop", "anthropic":
            return AgentIdentity(id: "claude", appType: fallback, displayName: "Claude", sortPriority: 2)
        case "gemini", "geminicli", "google":
            return AgentIdentity(id: "gemini", appType: fallback, displayName: "Gemini", sortPriority: 3)
        case "grok", "grokbuild":
            return AgentIdentity(id: "grok-build", appType: fallback, displayName: "Grok Build", sortPriority: 4)
        case "deepseek", "deepseekharness", "dsh":
            return AgentIdentity(id: "deepseek", appType: fallback, displayName: "DSH", sortPriority: 5)
        default:
            return AgentIdentity(
                id: "other:\(fallback.lowercased())",
                appType: fallback,
                displayName: fallback,
                sortPriority: 100
            )
        }
    }
}
