import Foundation

/// One local-calendar day in the dashboard activity view. Costs are stored in
/// millionths of CNY, matching `UsageRecord.costMicrosCNY`.
public struct DailyDashboardUsage: Identifiable, Equatable, Sendable {
    public let date: Date
    public let inputTokens: Int64
    public let outputTokens: Int64
    public let cacheWriteTokens: Int64
    public let cacheReadTokens: Int64
    public let requestCount: Int
    public let costMicrosCNY: Int64

    public var id: Date { date }
    public var freshInputTokens: Int64 { inputTokens }
    public var requests: Int { requestCount }
    public var totalTokens: Int64 {
        TokenArithmetic.addingWithoutOverflow(
            TokenArithmetic.addingWithoutOverflow(
                TokenArithmetic.addingWithoutOverflow(inputTokens, outputTokens),
                cacheWriteTokens
            ),
            cacheReadTokens
        )
    }
    public var tokens: Int64 { totalTokens }
    public var costCNY: Int64 { costMicrosCNY }

    public init(
        date: Date,
        inputTokens: Int64,
        outputTokens: Int64,
        cacheWriteTokens: Int64 = 0,
        cacheReadTokens: Int64 = 0,
        requestCount: Int = 0,
        costMicrosCNY: Int64 = 0
    ) {
        self.date = date
        self.inputTokens = max(0, inputTokens)
        self.outputTokens = max(0, outputTokens)
        self.cacheWriteTokens = max(0, cacheWriteTokens)
        self.cacheReadTokens = max(0, cacheReadTokens)
        self.requestCount = max(0, requestCount)
        self.costMicrosCNY = max(0, costMicrosCNY)
    }
}

/// Cost and token totals for one model/provider combination.
public struct DashboardModelUsage: Identifiable, Equatable, Sendable {
    public let model: String
    /// Raw source agent value, e.g. `codex`, `opencode`, or `deepseek-harness`.
    public let agent: String
    public let inputTokens: Int64
    public let outputTokens: Int64
    public let cacheWriteTokens: Int64
    public let cacheReadTokens: Int64
    public let requestCount: Int
    public let costMicrosCNY: Int64

    public var id: String { "\(agent):\(model)" }
    public var freshInputTokens: Int64 { inputTokens }
    public var requests: Int { requestCount }
    public var totalTokens: Int64 {
        TokenArithmetic.addingWithoutOverflow(
            TokenArithmetic.addingWithoutOverflow(
                TokenArithmetic.addingWithoutOverflow(inputTokens, outputTokens),
                cacheWriteTokens
            ),
            cacheReadTokens
        )
    }
    public var tokens: Int64 { totalTokens }
    public var costCNY: Int64 { costMicrosCNY }
    public var agentIdentity: AgentIdentity { AgentIdentity.resolve(agent) }
    public var agentDisplayName: String { agentIdentity.displayName }

    public init(
        model: String,
        agent: String,
        inputTokens: Int64,
        outputTokens: Int64,
        cacheWriteTokens: Int64 = 0,
        cacheReadTokens: Int64 = 0,
        requestCount: Int = 0,
        costMicrosCNY: Int64 = 0
    ) {
        self.model = model
        self.agent = agent
        self.inputTokens = max(0, inputTokens)
        self.outputTokens = max(0, outputTokens)
        self.cacheWriteTokens = max(0, cacheWriteTokens)
        self.cacheReadTokens = max(0, cacheReadTokens)
        self.requestCount = max(0, requestCount)
        self.costMicrosCNY = max(0, costMicrosCNY)
    }
}

/// Usage totals for one project and agent combination.
public struct DashboardProjectUsage: Identifiable, Equatable, Sendable {
    public let projectPath: String?
    public let agent: String
    public let inputTokens: Int64
    public let outputTokens: Int64
    public let cacheWriteTokens: Int64
    public let cacheReadTokens: Int64
    public let requestCount: Int
    public let activeDays: Int
    public let lastUsed: Date?
    public let costMicrosCNY: Int64

    public var id: String { "\(agent):\(projectPath ?? "")" }
    public var freshInputTokens: Int64 { inputTokens }
    public var requests: Int { requestCount }
    public var totalTokens: Int64 {
        TokenArithmetic.addingWithoutOverflow(
            TokenArithmetic.addingWithoutOverflow(
                TokenArithmetic.addingWithoutOverflow(inputTokens, outputTokens),
                cacheWriteTokens
            ),
            cacheReadTokens
        )
    }
    public var tokens: Int64 { totalTokens }
    public var costCNY: Int64 { costMicrosCNY }
    public var agentIdentity: AgentIdentity { AgentIdentity.resolve(agent) }
    public var agentDisplayName: String { agentIdentity.displayName }

    public init(
        projectPath: String?,
        agent: String,
        inputTokens: Int64,
        outputTokens: Int64,
        cacheWriteTokens: Int64 = 0,
        cacheReadTokens: Int64 = 0,
        requestCount: Int = 0,
        activeDays: Int = 0,
        lastUsed: Date? = nil,
        costMicrosCNY: Int64 = 0
    ) {
        self.projectPath = projectPath
        self.agent = agent
        self.inputTokens = max(0, inputTokens)
        self.outputTokens = max(0, outputTokens)
        self.cacheWriteTokens = max(0, cacheWriteTokens)
        self.cacheReadTokens = max(0, cacheReadTokens)
        self.requestCount = max(0, requestCount)
        self.activeDays = max(0, activeDays)
        self.lastUsed = lastUsed
        self.costMicrosCNY = max(0, costMicrosCNY)
    }
}

/// A session assembled from one or more normalized usage records.
public struct DashboardSessionUsage: Identifiable, Equatable, Sendable {
    public let sessionID: String
    public let sessionTitle: String?
    public let projectPath: String?
    public let agent: String
    public let model: String
    public let sessionStartedAt: Date?
    public let sessionEndedAt: Date?
    public let inputTokens: Int64
    public let outputTokens: Int64
    public let cacheWriteTokens: Int64
    public let cacheReadTokens: Int64
    public let requestCount: Int
    public let costMicrosCNY: Int64
    public let tokensPerSecond: Double?
    public let cacheHitRate: Double

    /// Source session IDs are not globally unique (Codex and OpenCode can
    /// legitimately emit the same value), so include the canonical source in
    /// SwiftUI identity as well as in repository grouping.
    public var id: String { "\(agentIdentity.id):\(sessionID)" }
    public var title: String? { sessionTitle }
    public var project: String? { projectPath }
    public var modelID: String { model }
    public var freshInputTokens: Int64 { inputTokens }
    public var requests: Int { requestCount }
    public var totalTokens: Int64 {
        TokenArithmetic.addingWithoutOverflow(
            TokenArithmetic.addingWithoutOverflow(
                TokenArithmetic.addingWithoutOverflow(inputTokens, outputTokens),
                cacheWriteTokens
            ),
            cacheReadTokens
        )
    }
    public var tokens: Int64 { totalTokens }
    public var costCNY: Int64 { costMicrosCNY }
    /// Alias useful to views that express a hit ratio as a fraction.
    public var cacheHit: Double { cacheHitRate }
    public var agentIdentity: AgentIdentity { AgentIdentity.resolve(agent) }
    public var agentDisplayName: String { agentIdentity.displayName }

    public init(
        sessionID: String,
        sessionTitle: String? = nil,
        projectPath: String? = nil,
        agent: String,
        model: String,
        sessionStartedAt: Date? = nil,
        sessionEndedAt: Date? = nil,
        inputTokens: Int64,
        outputTokens: Int64,
        cacheWriteTokens: Int64 = 0,
        cacheReadTokens: Int64 = 0,
        requestCount: Int = 0,
        costMicrosCNY: Int64 = 0,
        tokensPerSecond: Double? = nil,
        cacheHitRate: Double = 0
    ) {
        self.sessionID = sessionID
        self.sessionTitle = sessionTitle
        self.projectPath = projectPath
        self.agent = agent
        self.model = model
        self.sessionStartedAt = sessionStartedAt
        self.sessionEndedAt = sessionEndedAt
        self.inputTokens = max(0, inputTokens)
        self.outputTokens = max(0, outputTokens)
        self.cacheWriteTokens = max(0, cacheWriteTokens)
        self.cacheReadTokens = max(0, cacheReadTokens)
        self.requestCount = max(0, requestCount)
        self.costMicrosCNY = max(0, costMicrosCNY)
        self.tokensPerSecond = tokensPerSecond?.isFinite == true ? max(0, tokensPerSecond!) : nil
        self.cacheHitRate = min(1, max(0, cacheHitRate.isFinite ? cacheHitRate : 0))
    }
}

/// All aggregate data required by the Overview, Activity, Models, Projects,
/// and Sessions tabs. Date ranges are represented by the caller's calendar.
public struct DashboardSnapshot: Equatable, Sendable {
    public let generatedAt: Date
    public let sessionDate: Date
    public let dailyUsage: [DailyDashboardUsage]
    public let modelUsage: [DashboardModelUsage]
    public let projectUsage: [DashboardProjectUsage]
    public let sessions: [DashboardSessionUsage]
    public let usdToCNYRate: Double
    /// Cost observed during the local clock hour containing `generatedAt`.
    public let currentHourCostMicrosCNY: Int64
    /// Cost observed in the rolling 60-minute window ending at `generatedAt`.
    /// This is the value used for the dashboard's per-hour pace.
    public let rollingHourCostMicrosCNY: Int64

    public var daily: [DailyDashboardUsage] { dailyUsage }
    public var models: [DashboardModelUsage] { modelUsage }
    public var projects: [DashboardProjectUsage] { projectUsage }
    public var today: DailyDashboardUsage? { dailyUsage.last }
    public var hourlyCostMicrosCNY: Int64 { currentHourCostMicrosCNY }
    public var totalCostMicrosCNY: Int64 {
        dailyUsage.reduce(0) { TokenArithmetic.addingWithoutOverflow($0, $1.costMicrosCNY) }
    }
    public var totalTokens: Int64 {
        dailyUsage.reduce(0) { TokenArithmetic.addingWithoutOverflow($0, $1.totalTokens) }
    }

    public init(
        generatedAt: Date,
        sessionDate: Date,
        dailyUsage: [DailyDashboardUsage],
        modelUsage: [DashboardModelUsage],
        projectUsage: [DashboardProjectUsage],
        sessions: [DashboardSessionUsage],
        usdToCNYRate: Double,
        currentHourCostMicrosCNY: Int64 = 0,
        rollingHourCostMicrosCNY: Int64 = 0
    ) {
        self.generatedAt = generatedAt
        self.sessionDate = sessionDate
        self.dailyUsage = dailyUsage
        self.modelUsage = modelUsage
        self.projectUsage = projectUsage
        self.sessions = sessions
        self.usdToCNYRate = usdToCNYRate
        self.currentHourCostMicrosCNY = max(0, currentHourCostMicrosCNY)
        self.rollingHourCostMicrosCNY = max(0, rollingHourCostMicrosCNY)
    }

    /// Replaces only the selected-day session payload. Activity, model and
    /// project aggregates stay cached while the Sessions tab changes dates.
    public func replacingSessions(
        _ sessions: [DashboardSessionUsage],
        sessionDate: Date,
        generatedAt: Date = Date()
    ) -> DashboardSnapshot {
        DashboardSnapshot(
            generatedAt: generatedAt,
            sessionDate: sessionDate,
            dailyUsage: dailyUsage,
            modelUsage: modelUsage,
            projectUsage: projectUsage,
            sessions: sessions,
            usdToCNYRate: usdToCNYRate,
            currentHourCostMicrosCNY: currentHourCostMicrosCNY,
            rollingHourCostMicrosCNY: rollingHourCostMicrosCNY
        )
    }

    public func updatingRollingHourCost(
        _ costMicrosCNY: Int64,
        generatedAt: Date
    ) -> DashboardSnapshot {
        DashboardSnapshot(
            generatedAt: generatedAt,
            sessionDate: sessionDate,
            dailyUsage: dailyUsage,
            modelUsage: modelUsage,
            projectUsage: projectUsage,
            sessions: sessions,
            usdToCNYRate: usdToCNYRate,
            currentHourCostMicrosCNY: currentHourCostMicrosCNY,
            rollingHourCostMicrosCNY: costMicrosCNY
        )
    }

    public static func empty(
        now: Date = Date(),
        sessionDate: Date = Date(),
        calendar: Calendar = .current,
        usdToCNYRate: Double = 7.2
    ) -> DashboardSnapshot {
        let today = calendar.startOfDay(for: now)
        let days = (-139...0).compactMap { calendar.date(byAdding: .day, value: $0, to: today) }
        return DashboardSnapshot(
            generatedAt: now,
            sessionDate: calendar.startOfDay(for: sessionDate),
            dailyUsage: days.map { DailyDashboardUsage(date: $0, inputTokens: 0, outputTokens: 0) },
            modelUsage: [],
            projectUsage: [],
            sessions: [],
            usdToCNYRate: usdToCNYRate
        )
    }
}

// Short aliases keep the API pleasant for clients while retaining the
// descriptive names above for source compatibility and generated docs.
public typealias DashboardDailyUsage = DailyDashboardUsage
public typealias DashboardModel = DashboardModelUsage
public typealias DashboardProject = DashboardProjectUsage
public typealias DashboardSession = DashboardSessionUsage
