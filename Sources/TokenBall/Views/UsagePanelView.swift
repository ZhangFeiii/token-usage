import SwiftUI
import TokenBallCore

private enum DashboardTextStyle {
    case sidebarTitle
    case navigation
    case status
    case sectionTitle
    case metricValue
    case metricSubtitle
    case body
    case bodyMedium
    case bodyStrong
    case small
    case smallMedium
    case smallStrong
    case badge
    case chart
    case sessionDate
    case donutValue
    case donutLabel
    case emptyIcon
    case emptyTitle
    case emptyBody

    var baseSize: CGFloat {
        switch self {
        case .sidebarTitle: 15
        case .navigation: 12.5
        case .status: 9.5
        case .sectionTitle: 11
        case .metricValue: 22
        case .metricSubtitle: 11
        case .body: 12
        case .bodyMedium: 12
        case .bodyStrong: 13
        case .small: 10
        case .smallMedium: 10
        case .smallStrong: 11
        case .badge: 9
        case .chart: 8
        case .sessionDate: 15
        case .donutValue: 20
        case .donutLabel: 11
        case .emptyIcon: 30
        case .emptyTitle: 16
        case .emptyBody: 11
        }
    }

    var weight: Font.Weight {
        switch self {
        case .sidebarTitle, .sectionTitle, .metricValue, .smallStrong, .sessionDate, .donutValue, .emptyTitle:
            .bold
        case .bodyMedium, .smallMedium, .badge:
            .medium
        case .bodyStrong:
            .semibold
        case .emptyIcon:
            .light
        default:
            .regular
        }
    }
}

/// All panel density decisions live here so the five dashboards stay in sync.
/// The panel is measured in AppKit points; `typographyScale` and `density` are
/// derived from that measured width and never assume a particular pixel count.
private struct DashboardLayoutMetrics: Equatable {
    let panelSize: CGSize
    let typographyScale: CGFloat
    let density: CGFloat

    init(size: CGSize) {
        let width = max(1, size.width)
        let normalizedWidth = (width - 430) / 170
        typographyScale = min(0.96, max(0.86, 0.86 + normalizedWidth * 0.10))
        density = min(0.96, max(0.80, 0.80 + normalizedWidth * 0.16))
        panelSize = CGSize(width: width, height: max(1, size.height))
    }

    static let fallback = DashboardLayoutMetrics(size: CGSize(width: 500, height: 700))

    var outerPadding: CGFloat { max(9, 12 * density) }
    var pageSpacing: CGFloat { max(7, 10 * density) }
    var cardInsets: CGFloat { max(10, 13 * density) }
    var compactCardInsets: CGFloat { max(9, 12 * density) }
    var cardRadius: CGFloat { max(13, 16 * density) }
    var panelCornerRadius: CGFloat { max(18, 24 * density) }
    var sidebarWidth: CGFloat { min(138, max(112, panelSize.width * 0.24)) }
    var sidebarTopPadding: CGFloat { max(14, 18 * density) }
    var sidebarTitleBottomPadding: CGFloat { max(14, 18 * density) }
    var navigationRowHeight: CGFloat { max(32, 38 * density) }
    var navigationCornerRadius: CGFloat { max(10, 12 * density) }
    var sidebarHorizontalPadding: CGFloat { max(10, 13 * density) }
    var sidebarNavigationPadding: CGFloat { max(5, 6 * density) }
    var contentWidth: CGFloat {
        max(1, panelSize.width - sidebarWidth - outerPadding * 2 - 1)
    }
    var donutSize: CGFloat { min(150, max(116, contentWidth * 0.40)) }
    var weeklyChartHeight: CGFloat { min(140, max(112, contentWidth * 0.37)) }
    var emptyMinHeight: CGFloat { max(180, 220 * density) }

    func font(_ style: DashboardTextStyle, design: Font.Design = .rounded) -> Font {
        .system(size: style.baseSize * typographyScale, weight: style.weight, design: design)
    }

    func iconFont(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size * typographyScale, weight: weight)
    }
}

private struct DashboardLayoutMetricsKey: EnvironmentKey {
    static let defaultValue = DashboardLayoutMetrics.fallback
}

private extension EnvironmentValues {
    var dashboardLayoutMetrics: DashboardLayoutMetrics {
        get { self[DashboardLayoutMetricsKey.self] }
        set { self[DashboardLayoutMetricsKey.self] = newValue }
    }
}

private enum DashboardTab: String, CaseIterable, Identifiable {
    case overview = "Overview"
    case activity = "Activity"
    case models = "Models"
    case projects = "Projects"
    case sessions = "Sessions"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .overview: "bolt"
        case .activity: "chart.bar"
        case .models: "cpu"
        case .projects: "folder"
        case .sessions: "list.bullet"
        }
    }
}

struct UsagePanelView: View {
    @ObservedObject var viewModel: UsageViewModel
    @State private var selectedTab: DashboardTab = .overview

    var body: some View {
        GeometryReader { proxy in
            let metrics = DashboardLayoutMetrics(size: proxy.size)

            ZStack {
                Rectangle().fill(.ultraThinMaterial)
                LinearGradient(
                    colors: [
                        Color.white.opacity(0.18),
                        Color(red: 0.91, green: 0.93, blue: 0.96).opacity(0.20),
                        Color.white.opacity(0.08)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )

                HStack(spacing: 0) {
                    DashboardSidebar(selection: $selectedTab)
                        .frame(width: metrics.sidebarWidth)

                    Rectangle()
                        .fill(Color.tokenLine.opacity(0.75))
                        .frame(width: 1)

                    content
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding(metrics.outerPadding)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: metrics.panelCornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: metrics.panelCornerRadius, style: .continuous)
                    .stroke(Color.white.opacity(0.58), lineWidth: 1)
            }
            .environment(\.dashboardLayoutMetrics, metrics)
        }
        .task { await viewModel.startIfNeeded() }
    }

    @ViewBuilder
    private var content: some View {
        if !viewModel.hasLoaded {
            LoadingStateView()
        } else if viewModel.snapshot.agents.isEmpty, viewModel.dashboard.totalTokens == 0 {
            EmptyUsageView(refresh: { Task { await viewModel.refresh() } })
        } else {
            VStack(spacing: 10) {
                if let message = viewModel.errorMessage {
                    StaleDataBanner(message: message)
                }

                switch selectedTab {
                case .overview:
                    OverviewDashboard(snapshot: viewModel.dashboard)
                case .activity:
                    ActivityDashboard(snapshot: viewModel.dashboard)
                case .models:
                    ModelsDashboard(models: viewModel.dashboard.models)
                case .projects:
                    ProjectsDashboard(projects: viewModel.dashboard.projects)
                case .sessions:
                    SessionsDashboard(
                        snapshot: viewModel.dashboard,
                        selectedDate: viewModel.selectedSessionDate,
                        onSelectDate: { date in
                            Task { await viewModel.selectSessionDate(date) }
                        }
                    )
                }
            }
        }
    }
}

private struct DashboardSidebar: View {
    @Binding var selection: DashboardTab
    @Environment(\.dashboardLayoutMetrics) private var metrics

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                TokenOrbView(size: 24 * metrics.typographyScale)
                Text("Token\nUsage")
                    .font(metrics.font(.sidebarTitle))
                    .foregroundStyle(Color.tokenInk)
                    .lineSpacing(1)
            }
            .padding(.top, metrics.sidebarTopPadding)
            .padding(.horizontal, metrics.sidebarHorizontalPadding)
            .padding(.bottom, metrics.sidebarTitleBottomPadding)

            VStack(spacing: max(3, 4 * metrics.density)) {
                ForEach(DashboardTab.allCases) { tab in
                    Button {
                        selection = tab
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: tab.symbol)
                                .font(metrics.iconFont(size: 15))
                                .frame(width: 18 * metrics.typographyScale)
                            Text(tab.rawValue)
                                .font(metrics.font(.navigation))
                                .lineLimit(1)
                                .minimumScaleFactor(0.88)
                            Spacer(minLength: 0)
                        }
                        .foregroundStyle(selection == tab ? Color.dashboardCoral : Color.tokenMuted)
                        .padding(.horizontal, 10 * metrics.density)
                        .frame(height: metrics.navigationRowHeight)
                        .background {
                            if selection == tab {
                                RoundedRectangle(cornerRadius: metrics.navigationCornerRadius, style: .continuous)
                                    .fill(Color.dashboardCoral.opacity(0.075))
                                    .overlay {
                                        RoundedRectangle(cornerRadius: metrics.navigationCornerRadius, style: .continuous)
                                            .stroke(Color.dashboardCoral.opacity(0.30), lineWidth: 1)
                                    }
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, metrics.sidebarNavigationPadding)

            Spacer()

            HStack(spacing: 8) {
                Circle()
                    .fill(Color.dashboardGreen)
                    .frame(width: 7 * metrics.typographyScale, height: 7 * metrics.typographyScale)
                    .shadow(color: Color.dashboardGreen.opacity(0.55), radius: 4)
                Text("Live · \(version)")
                    .font(metrics.font(.status))
                    .foregroundStyle(Color.tokenMuted)
            }
            .padding(.horizontal, metrics.sidebarHorizontalPadding)
            .padding(.bottom, max(11, 14 * metrics.density))
        }
        .background(Color.white.opacity(0.045))
    }
}

// MARK: - Overview

private struct OverviewDashboard: View {
    let snapshot: DashboardSnapshot
    @Environment(\.dashboardLayoutMetrics) private var metrics

    private var today: DailyDashboardUsage {
        snapshot.today ?? DailyDashboardUsage(date: Date(), inputTokens: 0, outputTokens: 0)
    }

    private var totalInput: Int64 {
        TokenArithmetic.addingWithoutOverflow(
            TokenArithmetic.addingWithoutOverflow(today.inputTokens, today.cacheReadTokens),
            today.cacheWriteTokens
        )
    }

    private var cacheHit: Double {
        totalInput > 0 ? Double(today.cacheReadTokens) / Double(totalInput) : 0
    }

    private var estimatedTodayCost: Int64 {
        let estimate = Double(snapshot.currentHourCostMicrosCNY) * 24
        return estimate.isFinite ? Int64(min(Double(Int64.max), estimate.rounded())) : 0
    }

    var body: some View {
        ScrollView {
            VStack(spacing: metrics.pageSpacing) {
                HStack(spacing: metrics.pageSpacing) {
                    MetricCard(
                        title: "TODAY",
                        value: dashboardCNY(today.costMicrosCNY),
                        subtitle: "\(today.requestCount.formatted()) requests",
                        symbol: "chart.line.uptrend.xyaxis",
                        tint: .dashboardCoral
                    )
                    MetricCard(
                        title: "CACHE HIT",
                        value: dashboardPercent(cacheHit),
                        subtitle: "\(TokenFormatter.compact(today.cacheReadTokens)) read tokens",
                        symbol: "cylinder.split.1x2",
                        tint: .dashboardGreen
                    )
                }

                DashboardCard {
                    VStack(alignment: .leading, spacing: max(14, 18 * metrics.density)) {
                        HStack {
                            Text("TODAY'S TOKENS")
                                .dashboardSectionTitle()
                            Spacer()
                            Text(TokenFormatter.compact(today.totalTokens))
                                .font(metrics.font(.bodyStrong))
                                .foregroundStyle(Color.tokenMuted)
                                .monospacedDigit()
                        }

                        TokenBreakdownRows(
                            input: today.inputTokens,
                            output: today.outputTokens,
                            cacheWrite: today.cacheWriteTokens,
                            cacheRead: today.cacheReadTokens
                        )

                        VStack(alignment: .leading, spacing: max(10, 13 * metrics.density)) {
                            Text("PACE")
                                .dashboardSectionTitle()
                            PaceRow(title: "本小时速率", value: hourlyRateText)
                            PaceRow(title: "预计今日总额", value: dashboardCNY(estimatedTodayCost))
                            PaceRow(
                                title: "均次成本",
                                value: today.requestCount > 0
                                    ? dashboardCNY(today.costMicrosCNY / Int64(today.requestCount)) + "/req"
                                    : "¥0.00/req"
                            )
                        }
                        .padding(.top, max(3, 4 * metrics.density))
                    }
                }
            }
            .padding(.bottom, 2)
        }
        .scrollIndicators(.hidden)
    }

    private var hourlyRateText: String {
        dashboardCNY(snapshot.currentHourCostMicrosCNY) + "/hr"
    }
}

private struct MetricCard: View {
    let title: String
    let value: String
    let subtitle: String
    let symbol: String
    let tint: Color
    @Environment(\.dashboardLayoutMetrics) private var metrics

    var body: some View {
        DashboardCard {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: max(4, 6 * metrics.density)) {
                    Text(title).dashboardSectionTitle()
                    Text(value)
                        .font(metrics.font(.metricValue))
                        .foregroundStyle(Color.tokenInk)
                        .monospacedDigit()
                    Text(subtitle)
                        .font(metrics.font(.metricSubtitle))
                        .foregroundStyle(Color.tokenMuted)
                }
                Spacer()
                Image(systemName: symbol)
                    .font(metrics.iconFont(size: 19, weight: .medium))
                    .foregroundStyle(tint)
            }
        }
        .frame(maxWidth: .infinity, minHeight: max(96, 112 * metrics.density))
    }
}

private struct PaceRow: View {
    let title: String
    let value: String
    @Environment(\.dashboardLayoutMetrics) private var metrics

    var body: some View {
        HStack {
            Text(title)
                .font(metrics.font(.body))
                .foregroundStyle(Color.tokenMuted)
            Spacer()
            Text(value)
                .font(metrics.font(.bodyStrong))
                .foregroundStyle(Color.tokenInk)
                .monospacedDigit()
        }
    }
}

// MARK: - Activity

private struct ActivityDashboard: View {
    let snapshot: DashboardSnapshot
    @Environment(\.dashboardLayoutMetrics) private var metrics

    private var last90: ArraySlice<DailyDashboardUsage> { snapshot.daily.suffix(90) }
    private var total90: Int64 { last90.reduce(0) { $0.saturatingAdd($1.costMicrosCNY) } }
    private var activeDays: Int { last90.filter { $0.totalTokens > 0 || $0.requestCount > 0 }.count }
    private var averageActiveDay: Int64 { activeDays > 0 ? total90 / Int64(activeDays) : 0 }
    private var peakDay: Int64 { last90.map(\.costMicrosCNY).max() ?? 0 }

    var body: some View {
        ScrollView {
            VStack(spacing: metrics.pageSpacing) {
                DashboardCard {
                    VStack(alignment: .leading, spacing: max(10, 12 * metrics.density)) {
                        Text("ACTIVITY · LAST 20 WEEKS")
                            .dashboardSectionTitle()
                        ActivityHeatmap(days: snapshot.daily)
                    }
                }

                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: metrics.pageSpacing) {
                    ActivityStatCard(title: "90天总费用", value: dashboardCNY(total90), symbol: "chart.line.uptrend.xyaxis", tint: .dashboardCoral)
                    ActivityStatCard(title: "活跃天数", value: "\(activeDays) 天", symbol: "calendar", tint: .dashboardBlue)
                    ActivityStatCard(title: "日均费用", value: dashboardCNY(averageActiveDay), symbol: "bolt", tint: .dashboardOrange)
                    ActivityStatCard(title: "峰值单日", value: dashboardCNY(peakDay), symbol: "chart.bar.fill", tint: .dashboardGreen)
                }

                DashboardCard {
                    VStack(alignment: .leading, spacing: max(10, 12 * metrics.density)) {
                        Text("WEEKLY TREND · LAST 12 WEEKS")
                            .dashboardSectionTitle()
                        WeeklyCostChart(days: Array(snapshot.daily.suffix(84)))
                            .frame(height: metrics.weeklyChartHeight)
                    }
                }
            }
            .padding(.bottom, 2)
        }
        .scrollIndicators(.hidden)
    }
}

private struct ActivityStatCard: View {
    let title: String
    let value: String
    let symbol: String
    let tint: Color
    @Environment(\.dashboardLayoutMetrics) private var metrics

    var body: some View {
        DashboardCard(insets: 12) {
            HStack(spacing: max(10, 14 * metrics.density)) {
                Image(systemName: symbol)
                    .font(metrics.iconFont(size: 16, weight: .medium))
                    .foregroundStyle(tint)
                    .frame(width: 32 * metrics.density, height: 32 * metrics.density)
                    .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: max(7, 9 * metrics.density), style: .continuous))
                VStack(alignment: .leading, spacing: max(1, 2 * metrics.density)) {
                    Text(title)
                        .font(metrics.font(.small))
                        .foregroundStyle(Color.tokenMuted)
                    Text(value)
                        .font(metrics.font(.smallStrong))
                        .foregroundStyle(Color.tokenInk)
                        .monospacedDigit()
                }
                Spacer()
            }
        }
    }
}

private struct ActivityHeatmap: View {
    let days: [DailyDashboardUsage]
    @Environment(\.dashboardLayoutMetrics) private var metrics

    private var values: [Int64] { gridDays.map(\.costMicrosCNY) }

    private var gridDays: [DailyDashboardUsage] {
        let calendar = Calendar.autoupdatingCurrent
        let today = calendar.startOfDay(for: Date())
        let weekday = calendar.component(.weekday, from: today)
        let thisWeekStart = calendar.date(byAdding: .day, value: -(weekday - 1), to: today) ?? today
        let gridStart = calendar.date(byAdding: .day, value: -(19 * 7), to: thisWeekStart) ?? thisWeekStart
        let lookup = Dictionary(uniqueKeysWithValues: days.map { (calendar.startOfDay(for: $0.date), $0) })
        return (0..<140).compactMap { offset in
            guard let date = calendar.date(byAdding: .day, value: offset, to: gridStart) else { return nil }
            return lookup[date] ?? DailyDashboardUsage(date: date, inputTokens: 0, outputTokens: 0)
        }
    }

    private var thresholds: [Int64] {
        let nonzero = values.filter { $0 > 0 }.sorted()
        guard !nonzero.isEmpty else { return [1, 2, 3, 4] }
        return [0.25, 0.50, 0.75, 0.90].map { quantile in
            let index = min(nonzero.count - 1, Int((Double(nonzero.count - 1) * quantile).rounded()))
            return nonzero[index]
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: max(8, 11 * metrics.density)) {
            HStack(spacing: max(6, 8 * metrics.density)) {
                Color.clear.frame(width: 13 * metrics.typographyScale, height: 12 * metrics.typographyScale)
                HStack(spacing: max(3, 4 * metrics.density)) {
                    ForEach(0..<20, id: \.self) { week in
                        Text(monthLabel(for: week))
                            .font(metrics.font(.smallMedium))
                            .foregroundStyle(Color.tokenMuted)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .lineLimit(1)
                    }
                }
            }

            HStack(alignment: .top, spacing: max(6, 8 * metrics.density)) {
                VStack(spacing: max(3, 4 * metrics.density)) {
                    ForEach(1...7, id: \.self) { weekday in
                        Text(weekday == 2 ? "M" : weekday == 4 ? "W" : weekday == 6 ? "F" : "")
                            .font(metrics.font(.smallMedium))
                            .foregroundStyle(Color.tokenMuted)
                            .frame(width: 13 * metrics.typographyScale, height: 15 * metrics.typographyScale)
                    }
                }

                HStack(alignment: .top, spacing: max(3, 4 * metrics.density)) {
                    ForEach(0..<20, id: \.self) { week in
                        VStack(spacing: max(3, 4 * metrics.density)) {
                            ForEach(0..<7, id: \.self) { day in
                                let point = gridDays[week * 7 + day]
                                RoundedRectangle(cornerRadius: max(2, 3 * metrics.density), style: .continuous)
                                    .fill(color(for: point.costMicrosCNY))
                                    .frame(maxWidth: .infinity)
                                    .aspectRatio(1, contentMode: .fit)
                                    .overlay {
                                        if Calendar.autoupdatingCurrent.isDateInToday(point.date) {
                                            RoundedRectangle(cornerRadius: max(3, 4 * metrics.density), style: .continuous)
                                                .stroke(Color.dashboardCoral, lineWidth: max(1, 2 * metrics.typographyScale))
                                                .padding(-2)
                                        }
                                    }
                                    .help("\(point.date.formatted(date: .abbreviated, time: .omitted)) · \(dashboardCNY(point.costMicrosCNY))")
                            }
                        }
                    }
                }
            }

            HStack(spacing: max(5, 7 * metrics.density)) {
                Text("Less")
                ForEach(0..<5, id: \.self) { level in
                    RoundedRectangle(cornerRadius: max(2, 3 * metrics.density), style: .continuous)
                        .fill(legendColor(level: level))
                        .frame(width: 15 * metrics.typographyScale, height: 15 * metrics.typographyScale)
                }
                Text("More")
            }
            .font(metrics.font(.body))
            .foregroundStyle(Color.tokenMuted)
            .padding(.leading, 21 * metrics.density)
        }
    }

    private func color(for value: Int64) -> Color {
        guard value > 0 else { return Color.primary.opacity(0.075) }
        if value <= thresholds[0] { return Color.dashboardCoral.opacity(0.25) }
        if value <= thresholds[1] { return Color.dashboardCoral.opacity(0.43) }
        if value <= thresholds[2] { return Color.dashboardCoral.opacity(0.64) }
        return Color.dashboardCoral.opacity(value <= thresholds[3] ? 0.82 : 1)
    }

    private func legendColor(level: Int) -> Color {
        switch level {
        case 0: Color.primary.opacity(0.075)
        case 1: Color.dashboardCoral.opacity(0.25)
        case 2: Color.dashboardCoral.opacity(0.43)
        case 3: Color.dashboardCoral.opacity(0.64)
        default: Color.dashboardCoral
        }
    }

    private func monthLabel(for week: Int) -> String {
        let calendar = Calendar.autoupdatingCurrent
        let index = week * 7
        guard gridDays.indices.contains(index) else { return "" }
        let current = gridDays[index].date
        if week > 0 {
            let previous = gridDays[(week - 1) * 7].date
            guard calendar.component(.month, from: current) != calendar.component(.month, from: previous) else {
                return ""
            }
        }
        return current.formatted(.dateTime.month(.abbreviated))
    }
}

private struct WeeklyCostChart: View {
    let days: [DailyDashboardUsage]
    @Environment(\.dashboardLayoutMetrics) private var metrics

    private var weeks: [[DailyDashboardUsage]] {
        stride(from: 0, to: days.count, by: 7).map { start in
            Array(days[start..<min(start + 7, days.count)])
        }
    }

    private var totals: [Int64] {
        weeks.map { $0.reduce(0) { $0.saturatingAdd($1.costMicrosCNY) } }
    }

    private var maximum: Double { max(1, Double(totals.max() ?? 0)) }

    var body: some View {
        GeometryReader { proxy in
            HStack(alignment: .bottom, spacing: max(7, 10 * metrics.density)) {
                ForEach(Array(weeks.enumerated()), id: \.offset) { index, week in
                    let total = totals[index]
                    let height = total == 0 ? 4 : max(8, (proxy.size.height - 34) * CGFloat(Double(total) / maximum))
                    VStack(spacing: max(4, 6 * metrics.density)) {
                        Spacer(minLength: 0)
                        if total > 0 {
                            Text(shortCNY(total))
                                .font(metrics.font(.chart))
                                .foregroundStyle(Color.tokenMuted)
                                .lineLimit(1)
                        }
                        RoundedRectangle(cornerRadius: max(4, 6 * metrics.density), style: .continuous)
                            .fill(total == 0 ? Color.primary.opacity(0.075) : Color.dashboardCoral.opacity(index == weeks.count - 1 ? 0.95 : 0.55))
                            .frame(height: height)
                        Text(week.first?.date.formatted(.dateTime.month().day()) ?? "")
                            .font(metrics.font(.chart))
                            .foregroundStyle(index == weeks.count - 1 ? Color.dashboardCoral : Color.tokenMuted)
                    }
                    .frame(maxWidth: .infinity)
                    .help("\(dashboardCNY(total))")
                }
            }
        }
    }
}

// MARK: - Models

private struct ModelsDashboard: View {
    let models: [DashboardModelUsage]
    @Environment(\.dashboardLayoutMetrics) private var metrics

    private var visibleModels: [DashboardModelUsage] {
        models.filter { $0.totalTokens > 0 || $0.costMicrosCNY > 0 }
    }

    private var totalCost: Int64 {
        visibleModels.reduce(0) { $0.saturatingAdd($1.costMicrosCNY) }
    }

    private var totalInput: Int64 {
        visibleModels.reduce(0) { $0.saturatingAdd($1.inputTokens).saturatingAdd($1.cacheReadTokens).saturatingAdd($1.cacheWriteTokens) }
    }

    private var totalOutput: Int64 { visibleModels.reduce(0) { $0.saturatingAdd($1.outputTokens) } }

    var body: some View {
        ScrollView {
            VStack(spacing: metrics.pageSpacing) {
                DashboardCard {
                    VStack(alignment: .leading, spacing: max(10, 12 * metrics.density)) {
                        Text("COST BY MODEL · LAST 90 DAYS")
                            .dashboardSectionTitle()
                        HStack(spacing: max(12, 16 * metrics.density)) {
                            DonutChart(models: Array(visibleModels.prefix(8)), totalCost: totalCost)
                                .frame(width: metrics.donutSize, height: metrics.donutSize)
                            VStack(alignment: .leading, spacing: max(6, 9 * metrics.density)) {
                                ForEach(Array(visibleModels.prefix(8).enumerated()), id: \.element.id) { index, model in
                                    ModelLegendRow(
                                        model: model,
                                        color: dashboardPalette[index % dashboardPalette.count],
                                        percent: fraction(model.costMicrosCNY, of: totalCost)
                                    )
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        Text("Total tokens: \(TokenFormatter.compact(totalInput)) input, \(TokenFormatter.compact(totalOutput)) output")
                            .font(metrics.font(.metricSubtitle))
                            .foregroundStyle(Color.tokenMuted)
                    }
                }

                DashboardCard {
                    VStack(alignment: .leading, spacing: max(6, 8 * metrics.density)) {
                        Text("BREAKDOWN")
                            .dashboardSectionTitle()
                            .padding(.bottom, max(4, 5 * metrics.density))
                        ForEach(Array(visibleModels.enumerated()), id: \.element.id) { index, model in
                            ModelBreakdownRow(
                                model: model,
                                color: dashboardPalette[index % dashboardPalette.count],
                                percent: fraction(model.costMicrosCNY, of: totalCost)
                            )
                            if index != visibleModels.indices.last {
                                Divider().opacity(0.38)
                            }
                        }
                    }
                }
            }
            .padding(.bottom, 2)
        }
        .scrollIndicators(.hidden)
    }
}

private struct DonutChart: View {
    let models: [DashboardModelUsage]
    let totalCost: Int64
    @Environment(\.dashboardLayoutMetrics) private var metrics

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.primary.opacity(0.06), lineWidth: 34 * metrics.density)
            ForEach(Array(models.enumerated()), id: \.element.id) { index, model in
                Circle()
                    .trim(
                        from: cumulativeFraction(before: index),
                        to: cumulativeFraction(before: index + 1)
                    )
                    .stroke(
                        dashboardPalette[index % dashboardPalette.count],
                        style: StrokeStyle(lineWidth: 34 * metrics.density, lineCap: .butt)
                    )
                    .rotationEffect(.degrees(-90))
            }
            VStack(spacing: max(3, 4 * metrics.density)) {
                Text(dashboardCNY(totalCost))
                    .font(metrics.font(.donutValue))
                    .foregroundStyle(Color.tokenInk)
                    .monospacedDigit()
                Text("total")
                    .font(metrics.font(.donutLabel))
                    .foregroundStyle(Color.tokenMuted)
            }
        }
        .padding(16 * metrics.density)
    }

    private func cumulativeFraction(before index: Int) -> CGFloat {
        guard totalCost > 0, index > 0 else { return 0 }
        let value = models.prefix(index).reduce(Int64.zero) { $0.saturatingAdd($1.costMicrosCNY) }
        return CGFloat(min(1, Double(value) / Double(totalCost)))
    }
}

private struct ModelLegendRow: View {
    let model: DashboardModelUsage
    let color: Color
    let percent: Double
    @Environment(\.dashboardLayoutMetrics) private var metrics

    var body: some View {
        HStack(spacing: max(6, 9 * metrics.density)) {
            Circle().fill(color).frame(width: 10 * metrics.typographyScale, height: 10 * metrics.typographyScale)
            Text(UsageModelDisplayNameFormatter.compact(model.model))
                .font(metrics.font(.bodyMedium))
                .foregroundStyle(Color.tokenInk)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 5)
            AgentBadge(agent: model.agent)
            Text(dashboardPercent(percent))
                .font(metrics.font(.smallMedium))
                .foregroundStyle(Color.tokenMuted)
                .monospacedDigit()
        }
    }
}

private struct ModelBreakdownRow: View {
    let model: DashboardModelUsage
    let color: Color
    let percent: Double
    @Environment(\.dashboardLayoutMetrics) private var metrics

    var body: some View {
        VStack(alignment: .leading, spacing: max(6, 8 * metrics.density)) {
            HStack(spacing: max(6, 8 * metrics.density)) {
                Circle().fill(color).frame(width: 9 * metrics.typographyScale, height: 9 * metrics.typographyScale)
                Text(UsageModelDisplayNameFormatter.compact(model.model))
                    .font(metrics.font(.bodyStrong))
                    .foregroundStyle(Color.tokenInk)
                    .lineLimit(1)
                AgentBadge(agent: model.agent)
                Spacer()
                Text("\(dashboardCNY(model.costMicrosCNY)) · \(dashboardPercent(percent))")
                    .font(metrics.font(.bodyMedium))
                    .foregroundStyle(Color.tokenMuted)
                    .monospacedDigit()
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.07))
                    Capsule().fill(color).frame(width: proxy.size.width * max(0.006, percent))
                }
            }
            .frame(height: max(5, 7 * metrics.density))
            Text("\(model.requestCount.formatted()) req   in \(TokenFormatter.compact(model.inputTokens))   out \(TokenFormatter.compact(model.outputTokens))   cache \(TokenFormatter.compact(model.cacheReadTokens))")
                .font(metrics.font(.small))
                .foregroundStyle(Color.tokenMuted)
                .monospacedDigit()
        }
        .padding(.vertical, max(5, 7 * metrics.density))
    }
}

// MARK: - Projects

private struct ProjectsDashboard: View {
    let projects: [DashboardProjectUsage]
    @Environment(\.dashboardLayoutMetrics) private var metrics

    private var visibleProjects: [DashboardProjectUsage] {
        projects.filter { $0.projectPath != nil && ($0.totalTokens > 0 || $0.costMicrosCNY > 0) }
    }

    private var maximumCost: Double { max(1, Double(visibleProjects.map(\.costMicrosCNY).max() ?? 0)) }

    var body: some View {
        DashboardCard {
            VStack(alignment: .leading, spacing: metrics.pageSpacing) {
                Text("TOP PROJECTS · LAST 90 DAYS")
                    .dashboardSectionTitle()
                    .padding(.bottom, 4)
                if visibleProjects.isEmpty {
                    InlineEmptyState(text: "尚无可识别的项目数据")
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(visibleProjects.enumerated()), id: \.element.id) { index, project in
                                ProjectRow(project: project, fraction: Double(project.costMicrosCNY) / maximumCost, color: dashboardPalette[index % dashboardPalette.count])
                                if index != visibleProjects.indices.last {
                                    Divider().opacity(0.32)
                                }
                            }
                        }
                    }
                    .scrollIndicators(.hidden)
                }
            }
        }
    }
}

private struct ProjectRow: View {
    let project: DashboardProjectUsage
    let fraction: Double
    let color: Color
    @Environment(\.dashboardLayoutMetrics) private var metrics

    private var name: String {
        guard let path = project.projectPath else { return "Unknown Project" }
        let value = URL(fileURLWithPath: path).lastPathComponent
        return value.isEmpty ? path : value
    }

    var body: some View {
        VStack(alignment: .leading, spacing: max(6, 8 * metrics.density)) {
            HStack(spacing: max(6, 9 * metrics.density)) {
                Image(systemName: "folder")
                    .font(metrics.iconFont(size: 13, weight: .medium))
                    .foregroundStyle(Color.tokenMuted)
                Text(name)
                    .font(metrics.font(.bodyStrong))
                    .foregroundStyle(Color.tokenInk)
                    .lineLimit(1)
                    .truncationMode(.middle)
                AgentBadge(agent: project.agent)
                Spacer()
                Text(dashboardCNY(project.costMicrosCNY))
                    .font(metrics.font(.bodyMedium))
                    .foregroundStyle(Color.tokenMuted)
                    .monospacedDigit()
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.07))
                    Capsule().fill(color).frame(width: proxy.size.width * max(0.006, fraction))
                }
            }
            .frame(height: max(5, 6 * metrics.density))
            HStack(spacing: max(10, 15 * metrics.density)) {
                Text("\(project.requestCount.formatted()) req")
                Text("\(TokenFormatter.compact(project.totalTokens)) tokens")
                Text("\(project.activeDays) days")
                if let lastUsed = project.lastUsed {
                    Text("last \(lastUsed.formatted(.dateTime.year().month().day()))")
                }
            }
            .font(metrics.font(.small))
            .foregroundStyle(Color.tokenMuted)
            .monospacedDigit()
        }
        .padding(.vertical, max(8, 10 * metrics.density))
        .help(project.projectPath ?? "")
    }
}

// MARK: - Sessions

private struct SessionsDashboard: View {
    let snapshot: DashboardSnapshot
    let selectedDate: Date
    let onSelectDate: (Date) -> Void
    @Environment(\.dashboardLayoutMetrics) private var metrics

    private var sessions: [DashboardSessionUsage] { snapshot.sessions }
    private var totalCost: Int64 { sessions.reduce(0) { $0.saturatingAdd($1.costMicrosCNY) } }
    private var totalTokens: Int64 { sessions.reduce(0) { $0.saturatingAdd($1.totalTokens) } }

    var body: some View {
        VStack(spacing: metrics.pageSpacing) {
            DashboardCard(insets: 12) {
                HStack {
                    dateButton(symbol: "chevron.left", offset: -1)
                    Spacer()
                    VStack(spacing: max(4, 5 * metrics.density)) {
                        Text(selectedDate.formatted(.dateTime.year().month(.twoDigits).day(.twoDigits)))
                            .font(metrics.font(.sessionDate))
                            .foregroundStyle(Color.tokenInk)
                            .monospacedDigit()
                        Text("\(sessions.count) sessions · \(dashboardCNY(totalCost)) · \(TokenFormatter.compact(totalTokens)) tokens")
                            .font(metrics.font(.metricSubtitle))
                            .foregroundStyle(Color.tokenMuted)
                            .monospacedDigit()
                    }
                    Spacer()
                    dateButton(symbol: "chevron.right", offset: 1)
                        .disabled(Calendar.autoupdatingCurrent.isDateInToday(selectedDate))
                        .opacity(Calendar.autoupdatingCurrent.isDateInToday(selectedDate) ? 0.35 : 1)
                }
            }

            DashboardCard {
                if sessions.isEmpty {
                    InlineEmptyState(text: "这一天没有 Session 记录")
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(sessions.enumerated()), id: \.element.id) { index, session in
                                SessionRow(session: session)
                                if index != sessions.indices.last {
                                    Divider().opacity(0.38)
                                }
                            }
                        }
                    }
                    .scrollIndicators(.hidden)
                }
            }
        }
    }

    private func dateButton(symbol: String, offset: Int) -> some View {
        Button {
            if let date = Calendar.autoupdatingCurrent.date(byAdding: .day, value: offset, to: selectedDate) {
                onSelectDate(date)
            }
        } label: {
            Image(systemName: symbol)
                .font(metrics.iconFont(size: 15, weight: .semibold))
                .foregroundStyle(Color.tokenInk)
                .frame(width: 38 * metrics.density, height: 38 * metrics.density)
                .background(Color.white.opacity(0.16), in: Circle())
                .overlay { Circle().stroke(Color.white.opacity(0.48), lineWidth: 1) }
        }
        .buttonStyle(.plain)
    }
}

private struct SessionRow: View {
    let session: DashboardSessionUsage
    @Environment(\.dashboardLayoutMetrics) private var metrics

    private var displayTitle: String {
        if let title = session.sessionTitle, !title.isEmpty { return title }
        if let path = session.projectPath {
            let name = URL(fileURLWithPath: path).lastPathComponent
            if !name.isEmpty { return name }
        }
        return "Untitled Session"
    }

    private var shortID: String {
        let raw = session.sessionID.replacingOccurrences(of: "session-", with: "")
        return "sess_" + String(raw.suffix(6))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: max(5, 7 * metrics.density)) {
            HStack(alignment: .firstTextBaseline, spacing: max(7, 10 * metrics.density)) {
                Text(displayTitle)
                    .font(metrics.font(.bodyStrong))
                    .foregroundStyle(Color.tokenInk)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(dashboardCNY(session.costMicrosCNY))
                    .font(metrics.font(.smallStrong))
                    .foregroundStyle(Color.dashboardCoral)
                    .monospacedDigit()
            }

            HStack(spacing: max(6, 8 * metrics.density)) {
                AgentBadge(agent: session.agent)
                Text(UsageModelDisplayNameFormatter.compact(session.model))
                Text(timeRange)
                Text(shortID)
                Spacer()
                Text("\(session.requestCount.formatted()) req")
            }
            .font(metrics.font(.small))
            .foregroundStyle(Color.tokenMuted)
            .monospacedDigit()

            TokenCompositionBar(session: session)
                .frame(height: max(5, 6 * metrics.density))

            HStack(spacing: max(7, 10 * metrics.density)) {
                Text("in \(TokenFormatter.compact(session.inputTokens))")
                Text("out \(TokenFormatter.compact(session.outputTokens))")
                Text("cw \(TokenFormatter.compact(session.cacheWriteTokens))")
                Text("cr \(TokenFormatter.compact(session.cacheReadTokens))")
                if let speed = session.tokensPerSecond {
                    Text(String(format: "%.1f tok/s", speed))
                        .foregroundStyle(Color.dashboardPurple)
                        .fontWeight(.semibold)
                } else {
                    Text("— tok/s")
                        .foregroundStyle(Color.dashboardPurple)
                }
                Spacer(minLength: 6)
                Text("cache \(dashboardPercent(session.cacheHitRate)) hit")
            }
            .font(metrics.font(.small))
            .foregroundStyle(Color.tokenMuted)
            .monospacedDigit()
        }
        .padding(.vertical, max(8, 11 * metrics.density))
        .help(session.projectPath ?? session.sessionID)
    }

    private var timeRange: String {
        guard let start = session.sessionStartedAt, let end = session.sessionEndedAt else { return "—" }
        let format = Date.FormatStyle.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits)
        return "\(start.formatted(format))–\(end.formatted(format))"
    }
}

private struct TokenCompositionBar: View {
    let session: DashboardSessionUsage

    var body: some View {
        GeometryReader { proxy in
            let total = max(1, Double(session.totalTokens))
            HStack(spacing: 2) {
                Rectangle().fill(Color.dashboardGreen).frame(width: proxy.size.width * CGFloat(Double(session.inputTokens) / total))
                Rectangle().fill(Color.dashboardOrange).frame(width: proxy.size.width * CGFloat(Double(session.cacheWriteTokens) / total))
                Rectangle().fill(Color.dashboardPurple).frame(width: proxy.size.width * CGFloat(Double(session.outputTokens) / total))
                Rectangle().fill(Color.dashboardBlue).frame(width: proxy.size.width * CGFloat(Double(session.cacheReadTokens) / total))
            }
            .clipShape(Capsule())
            .background(Color.primary.opacity(0.07), in: Capsule())
        }
    }
}

// MARK: - Shared components

private struct DashboardCard<Content: View>: View {
    let insets: CGFloat?
    @ViewBuilder let content: Content
    @Environment(\.dashboardLayoutMetrics) private var metrics

    init(insets: CGFloat? = nil, @ViewBuilder content: () -> Content) {
        self.insets = insets
        self.content = content()
    }

    var body: some View {
        content
            .padding(insets.map { $0 * metrics.density } ?? metrics.cardInsets)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.white.opacity(0.16), in: RoundedRectangle(cornerRadius: metrics.cardRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: metrics.cardRadius, style: .continuous)
                    .stroke(Color.white.opacity(0.56), lineWidth: 1)
            }
            .shadow(color: Color.black.opacity(0.035), radius: max(7, 10 * metrics.density), y: max(3, 5 * metrics.density))
    }
}

private struct AgentBadge: View {
    let agent: String
    @Environment(\.dashboardLayoutMetrics) private var metrics

    private var identity: AgentIdentity { AgentIdentity.resolve(agent) }
    private var tint: Color { AgentAppearance.color(forID: identity.id) }

    var body: some View {
        Text(identity.displayName.uppercased())
            .font(metrics.font(.badge))
            .tracking(0.7 * metrics.typographyScale)
            .foregroundStyle(tint)
            .padding(.horizontal, 7 * metrics.density)
            .padding(.vertical, 3 * metrics.density)
            .background(tint.opacity(0.11), in: RoundedRectangle(cornerRadius: max(5, 6 * metrics.density), style: .continuous))
    }
}

private struct TokenBreakdownRows: View {
    let input: Int64
    let output: Int64
    let cacheWrite: Int64
    let cacheRead: Int64
    @Environment(\.dashboardLayoutMetrics) private var metrics

    private var rows: [(String, Int64, Color)] {
        [
            ("Cache Read", cacheRead, .dashboardGreen),
            ("Cache Write", cacheWrite, .dashboardOrange),
            ("Output", output, .dashboardPurple),
            ("Input", input, .dashboardBlue)
        ]
    }

    private var maximum: Double { max(1, Double(rows.map(\.1).max() ?? 0)) }

    var body: some View {
        VStack(spacing: max(10, 13 * metrics.density)) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: max(9, 12 * metrics.density)) {
                    Circle().fill(row.2).frame(width: 9 * metrics.typographyScale, height: 9 * metrics.typographyScale)
                    Text(row.0)
                        .font(metrics.font(.body))
                        .foregroundStyle(Color.tokenMuted)
                        .frame(width: 90 * metrics.density, alignment: .leading)
                    GeometryReader { proxy in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.primary.opacity(0.07))
                            Capsule().fill(row.2.opacity(0.72)).frame(width: proxy.size.width * CGFloat(Double(row.1) / maximum))
                        }
                    }
                    .frame(height: max(5, 6 * metrics.density))
                    Text(TokenFormatter.compact(row.1))
                        .font(metrics.font(.smallMedium))
                        .foregroundStyle(Color.tokenMuted)
                        .monospacedDigit()
                        .frame(width: 70 * metrics.density, alignment: .trailing)
                }
            }
        }
    }
}

private struct InlineEmptyState: View {
    let text: String
    @Environment(\.dashboardLayoutMetrics) private var metrics

    var body: some View {
        VStack(spacing: max(9, 12 * metrics.density)) {
            Image(systemName: "tray")
                .font(metrics.iconFont(size: 28, weight: .light))
            Text(text)
                .font(metrics.font(.bodyMedium))
        }
        .foregroundStyle(Color.tokenMuted)
        .frame(maxWidth: .infinity, minHeight: metrics.emptyMinHeight)
    }
}

private struct LoadingStateView: View {
    @Environment(\.dashboardLayoutMetrics) private var metrics

    var body: some View {
        VStack(spacing: max(10, 14 * metrics.density)) {
            ProgressView().controlSize(.regular)
            Text("正在读取本地用量…")
                .font(metrics.font(.bodyMedium))
                .foregroundStyle(Color.tokenMuted)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct EmptyUsageView: View {
    let refresh: () -> Void
    @Environment(\.dashboardLayoutMetrics) private var metrics

    var body: some View {
        VStack(spacing: max(11, 15 * metrics.density)) {
            Image(systemName: "chart.bar.xaxis")
                .font(metrics.font(.emptyIcon))
            Text("还没有可显示的用量")
                .font(metrics.font(.emptyTitle))
            Text("Token Usage 会自动读取本机 Agent 的会话记录。")
                .font(metrics.font(.emptyBody))
            Button("重新读取", action: refresh)
                .buttonStyle(.borderedProminent)
                .tint(.dashboardCoral)
        }
        .foregroundStyle(Color.tokenMuted)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct StaleDataBanner: View {
    let message: String
    @Environment(\.dashboardLayoutMetrics) private var metrics

    var body: some View {
        HStack(spacing: max(6, 8 * metrics.density)) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Color.orange)
            Text("刷新失败，当前显示上次数据：\(message)")
                .font(metrics.font(.smallMedium))
                .foregroundStyle(Color.tokenInk)
                .lineLimit(2)
            Spacer()
        }
        .padding(.horizontal, metrics.compactCardInsets)
        .frame(minHeight: max(30, 34 * metrics.density))
        .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: max(8, 10 * metrics.density), style: .continuous))
    }
}

private let dashboardPalette: [Color] = [
    .dashboardCoral,
    .dashboardOrange,
    Color(red: 0.94, green: 0.69, blue: 0.02),
    .dashboardGreen,
    Color(red: 0.09, green: 0.68, blue: 0.64),
    .dashboardBlue,
    .dashboardPurple,
    Color(red: 0.84, green: 0.30, blue: 0.68)
]

private func dashboardCNY(_ micros: Int64) -> String {
    TokenFormatter.cny(micros: max(0, micros))
}

private func shortCNY(_ micros: Int64) -> String {
    let amount = Double(max(0, micros)) / 1_000_000
    if amount >= 1_000 { return String(format: "¥%.1fk", amount / 1_000) }
    if amount >= 100 { return String(format: "¥%.0f", amount) }
    return String(format: "¥%.1f", amount)
}

private func fraction(_ value: Int64, of total: Int64) -> Double {
    guard total > 0 else { return 0 }
    return min(1, max(0, Double(value) / Double(total)))
}

private func dashboardPercent(_ value: Double) -> String {
    let safe = value.isFinite ? min(1, max(0, value)) : 0
    let percentage = safe * 100
    return percentage >= 10 ? String(format: "%.0f%%", percentage) : String(format: "%.1f%%", percentage)
}

private extension Int64 {
    func saturatingAdd(_ other: Int64) -> Int64 {
        TokenArithmetic.addingWithoutOverflow(self, other)
    }
}

private struct DashboardSectionTitleModifier: ViewModifier {
    @Environment(\.dashboardLayoutMetrics) private var metrics

    func body(content: Content) -> some View {
        content
            .font(metrics.font(.sectionTitle))
            .tracking(1.0 * metrics.typographyScale)
            .foregroundStyle(Color.tokenMuted)
    }
}

private extension View {
    func dashboardSectionTitle() -> some View {
        modifier(DashboardSectionTitleModifier())
    }
}

private extension Color {
    static let dashboardCoral = Color(red: 1.00, green: 0.31, blue: 0.36)
    static let dashboardOrange = Color(red: 0.98, green: 0.57, blue: 0.02)
    static let dashboardGreen = Color(red: 0.08, green: 0.74, blue: 0.43)
    static let dashboardBlue = Color(red: 0.21, green: 0.49, blue: 0.94)
    static let dashboardPurple = Color(red: 0.53, green: 0.31, blue: 0.97)
}
