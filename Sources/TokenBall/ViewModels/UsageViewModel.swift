import Foundation
import TokenBallCore

@MainActor
final class UsageViewModel: ObservableObject {
    @Published private(set) var snapshot: UsageSnapshot = .empty()
    @Published private(set) var dashboard: DashboardSnapshot = .empty()
    @Published private(set) var selectedSessionDate = Calendar.autoupdatingCurrent.startOfDay(for: Date())
    @Published private(set) var isRefreshing = false
    @Published private(set) var hasLoaded = false
    @Published private(set) var lastSuccessfulRefresh: Date?
    @Published private(set) var errorMessage: String?
    @Published private(set) var recoverySuggestion: String?
    @Published private(set) var exchangeRateUpdatedAt: Date?
    @Published private(set) var isUsingFallbackExchangeRate = false

    private let repository: any UsageRepository
    private let collector: (any UsageCollecting)?
    private let exchangeRateProvider: any ExchangeRateProviding
    private var hasStarted = false
    private var autoRefreshTask: Task<Void, Never>?
    private var usdToCNYRate = 7.2

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
            self.collector = LocalUsageCollector(store: store)
        } else {
            self.collector = nil
        }
    }

    func startIfNeeded() async {
        guard !hasStarted else { return }
        hasStarted = true
        await refresh()

        autoRefreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard !Task.isCancelled, let self else { return }
                await self.refresh()
            }
        }
    }

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer {
            isRefreshing = false
            hasLoaded = true
        }

        let now = Date()
        let exchangeRate = await exchangeRateProvider.currentRate(now: now)
        usdToCNYRate = exchangeRate.rate
        exchangeRateUpdatedAt = exchangeRate.updatedAt
        isUsingFallbackExchangeRate = exchangeRate.isFallback

        // Collection is best-effort: each source reports its own failure and the
        // UI still fetches the last successfully imported TokenBall snapshot.
        if let collector {
            _ = await collector.collect()
        }

        do {
            snapshot = try await repository.fetchUsage(now: now, calendar: .current)
            dashboard = try await repository.fetchDashboard(
                now: now,
                sessionDate: selectedSessionDate,
                usdToCNYRate: usdToCNYRate,
                calendar: .autoupdatingCurrent
            )
            lastSuccessfulRefresh = snapshot.generatedAt
            errorMessage = nil
            recoverySuggestion = nil
        } catch {
            let localized = error as? LocalizedError
            errorMessage = localized?.errorDescription ?? error.localizedDescription
            recoverySuggestion = localized?.recoverySuggestion
        }
    }

    func selectSessionDate(_ date: Date) async {
        let normalized = Calendar.autoupdatingCurrent.startOfDay(for: date)
        guard normalized != selectedSessionDate else { return }
        selectedSessionDate = normalized
        await refresh()
    }
}
