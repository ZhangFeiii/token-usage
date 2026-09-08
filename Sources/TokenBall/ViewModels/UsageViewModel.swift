import Foundation
import TokenBallCore

@MainActor
final class UsageViewModel: ObservableObject {
    @Published private(set) var dashboard: DashboardSnapshot = .empty()
    @Published private(set) var selectedSessionDate = Calendar.autoupdatingCurrent.startOfDay(for: Date())
    @Published private(set) var isRefreshing = false
    @Published private(set) var hasLoaded = false
    @Published private(set) var lastSuccessfulRefresh: Date?
    @Published private(set) var errorMessage: String?
    @Published private(set) var recoverySuggestion: String?
    @Published private(set) var exchangeRateUpdatedAt: Date?
    @Published private(set) var isUsingFallbackExchangeRate = false
    @Published private(set) var collectionIssues: [UsageCollectionIssue] = []

    private let repository: any UsageRepository
    private let collector: (any UsageCollecting)?
    private let exchangeRateProvider: any ExchangeRateProviding
    private var hasStarted = false
    private var autoRefreshTask: Task<Void, Never>?
    /// `isRefreshing` is UI state; this separate flag prevents overlapping
    /// timer/manual work without publishing a spinner transition for every
    /// timer tick.
    private var refreshInProgress = false
    private var usdToCNYRate = 7.2
    private var lastDashboardDay: Date?
    private var lastTimeZoneIdentifier: String?
    private var sessionCache: [Date: [DashboardSessionUsage]] = [:]
    private var sessionLoadGeneration = 0

    var todayCostMicrosCNY: Int64 {
        dashboard.today?.costMicrosCNY ?? 0
    }

    init(
        repository: any UsageRepository = SQLiteUsageRepository(),
        collector: (any UsageCollecting)? = nil,
        exchangeRateProvider: any ExchangeRateProviding = DailyUSDToCNYRateProvider()
    ) {
        self.repository = repository
        self.exchangeRateProvider = exchangeRateProvider
        if let collector {
            self.collector = collector
        } else if let store = repository as? any UsageRecordStore {
            if let sqliteRepository = repository as? SQLiteUsageRepository {
                let cacheURL = sqliteRepository.databaseURL
                    .deletingLastPathComponent()
                    .appendingPathComponent("source-fingerprints.json", isDirectory: false)
                self.collector = LocalUsageCollector(
                    store: store,
                    fingerprintCacheURL: cacheURL,
                    fingerprintDatabaseURL: sqliteRepository.databaseURL
                )
            } else {
                self.collector = LocalUsageCollector(store: store)
            }
        } else {
            self.collector = nil
        }
    }

    func startIfNeeded() async {
        guard !hasStarted else { return }
        hasStarted = true
        // The first load must always populate both snapshots, even when the
        // collector has no new records yet.
        await refresh(forceRead: true)

        autoRefreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard !Task.isCancelled, let self else { return }
                await self.refresh(forceRead: false)
            }
        }
    }

    func refresh() async {
        await refresh(forceRead: true)
    }

    /// Refreshes source data and, when needed, re-reads the aggregate
    /// snapshots. Timer-driven refreshes pass `false` so a quiet minute does
    /// not repeat the dashboard's full 140-day SQLite aggregation; explicit
    /// user refreshes always pass `true`.
    private func refresh(forceRead: Bool) async {
        guard !refreshInProgress else { return }
        refreshInProgress = true
        // Automatic collection is intentionally silent. A timer tick that
        // discovers no data/rate change should not cause a view-wide redraw.
        if forceRead, !isRefreshing {
            isRefreshing = true
        }
        defer {
            refreshInProgress = false
            if isRefreshing {
                isRefreshing = false
            }
            if !hasLoaded {
                hasLoaded = true
            }
        }

        let now = Date()
        let calendar = Calendar.autoupdatingCurrent
        let currentDay = calendar.startOfDay(for: now)
        let currentTimeZoneIdentifier = calendar.timeZone.identifier
        let dayChanged = lastDashboardDay.map { !calendar.isDate($0, inSameDayAs: currentDay) } ?? true
        let timeZoneChanged = lastTimeZoneIdentifier.map { $0 != currentTimeZoneIdentifier } ?? false
        let exchangeRate = await exchangeRateProvider.currentRate(now: now)
        let exchangeRateChanged = exchangeRate.rate != usdToCNYRate
            || exchangeRate.isFallback != isUsingFallbackExchangeRate
        if usdToCNYRate != exchangeRate.rate {
            usdToCNYRate = exchangeRate.rate
        }
        if exchangeRateUpdatedAt != exchangeRate.updatedAt {
            exchangeRateUpdatedAt = exchangeRate.updatedAt
        }
        if isUsingFallbackExchangeRate != exchangeRate.isFallback {
            isUsingFallbackExchangeRate = exchangeRate.isFallback
        }

        // Collection is best-effort: each source reports its own failure and the
        // UI still fetches the last successfully imported TokenBall snapshot.
        // A repository without a collector remains externally mutable, so it
        // retains the previous always-refresh behavior for timer ticks.
        let dataChanged: Bool
        if let collector {
            let report = await collector.collect()
            dataChanged = report.dataChanged
            if collectionIssues != report.issues {
                collectionIssues = report.issues
            }
        } else {
            dataChanged = true
            if !collectionIssues.isEmpty {
                collectionIssues = []
            }
        }

        let requiresFullRead = forceRead || !hasLoaded || dataChanged
            || exchangeRateChanged || dayChanged || timeZoneChanged
        guard requiresFullRead else {
            do {
                let rollingCost = try await repository.fetchRollingHourCost(
                    now: now,
                    usdToCNYRate: usdToCNYRate
                )
                if rollingCost != dashboard.rollingHourCostMicrosCNY {
                    dashboard = dashboard.updatingRollingHourCost(rollingCost, generatedAt: now)
                }
            } catch {
                // Keep the last good dashboard. The next full refresh will
                // surface a repository error with recovery guidance.
            }
            return
        }

        if dataChanged || exchangeRateChanged || dayChanged || timeZoneChanged {
            sessionCache.removeAll(keepingCapacity: true)
        }
        if let lastDashboardDay,
           (dayChanged || timeZoneChanged),
           calendar.isDate(selectedSessionDate, inSameDayAs: lastDashboardDay) {
            selectedSessionDate = currentDay
        }

        do {
            let newDashboard = try await repository.fetchDashboard(
                now: now,
                sessionDate: selectedSessionDate,
                usdToCNYRate: usdToCNYRate,
                calendar: .autoupdatingCurrent
            )
            if dashboard != newDashboard {
                dashboard = newDashboard
            }
            sessionCache[newDashboard.sessionDate] = newDashboard.sessions
            lastDashboardDay = currentDay
            lastTimeZoneIdentifier = currentTimeZoneIdentifier
            let generatedAt = newDashboard.generatedAt
            if lastSuccessfulRefresh != generatedAt {
                lastSuccessfulRefresh = generatedAt
            }
            if errorMessage != nil {
                errorMessage = nil
            }
            if recoverySuggestion != nil {
                recoverySuggestion = nil
            }
        } catch {
            let localized = error as? LocalizedError
            let nextErrorMessage = localized?.errorDescription ?? error.localizedDescription
            let nextRecoverySuggestion = localized?.recoverySuggestion
            if errorMessage != nextErrorMessage {
                errorMessage = nextErrorMessage
            }
            if recoverySuggestion != nextRecoverySuggestion {
                recoverySuggestion = nextRecoverySuggestion
            }
        }
    }

    func selectSessionDate(_ date: Date) async {
        let calendar = Calendar.autoupdatingCurrent
        let normalized = calendar.startOfDay(for: date)
        guard normalized != selectedSessionDate else { return }
        selectedSessionDate = normalized
        sessionLoadGeneration += 1
        let generation = sessionLoadGeneration

        if let cached = sessionCache[normalized] {
            dashboard = dashboard.replacingSessions(cached, sessionDate: normalized)
            return
        }

        isRefreshing = true
        defer {
            if generation == sessionLoadGeneration {
                isRefreshing = false
            }
        }
        do {
            let sessions = try await repository.fetchSessions(
                sessionDate: normalized,
                usdToCNYRate: usdToCNYRate,
                calendar: calendar
            )
            guard generation == sessionLoadGeneration, normalized == selectedSessionDate else { return }
            sessionCache[normalized] = sessions
            dashboard = dashboard.replacingSessions(sessions, sessionDate: normalized)
            errorMessage = nil
            recoverySuggestion = nil
        } catch {
            guard generation == sessionLoadGeneration else { return }
            let localized = error as? LocalizedError
            errorMessage = localized?.errorDescription ?? error.localizedDescription
            recoverySuggestion = localized?.recoverySuggestion
        }
    }
}
