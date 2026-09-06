import SwiftUI
import TokenBallCore

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
                    .frame(width: 145)

                Rectangle()
                    .fill(Color.tokenLine.opacity(0.75))
                    .frame(width: 1)

                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(16)
            }
        }
        // The AppKit shell sizes the panel in points based on the display's
        // backing scale. Keep the SwiftUI ideal size in the same narrow
        // proportion, while allowing the view to shrink on short screens.
        .frame(minWidth: 0, idealWidth: 600, minHeight: 0, idealHeight: 810)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(Color.white.opacity(0.58), lineWidth: 1)
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

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                TokenOrbView(size: 28)
                Text("Token\nUsage")
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.tokenInk)
                    .lineSpacing(1)
            }
            .padding(.top, 24)
            .padding(.horizontal, 16)
            .padding(.bottom, 24)

            VStack(spacing: 6) {
                ForEach(DashboardTab.allCases) { tab in
                    Button {
                        selection = tab
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: tab.symbol)
                                .font(.system(size: 17, weight: .regular))
                                .frame(width: 20)
                            Text(tab.rawValue)
                                .font(.system(size: 16, weight: .regular, design: .rounded))
                            Spacer(minLength: 0)
                        }
                        .foregroundStyle(selection == tab ? Color.dashboardCoral : Color.tokenMuted)
                        .padding(.horizontal, 12)
                        .frame(height: 45)
                        .background {
                            if selection == tab {
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .fill(Color.dashboardCoral.opacity(0.075))
                                    .overlay {
                                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                                            .stroke(Color.dashboardCoral.opacity(0.30), lineWidth: 1)
                                    }
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)

            Spacer()

            HStack(spacing: 8) {
                Circle()
                    .fill(Color.dashboardGreen)
                    .frame(width: 8, height: 8)
                    .shadow(color: Color.dashboardGreen.opacity(0.55), radius: 4)
                Text("Live · \(version)")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(Color.tokenMuted)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 18)
        }
        .background(Color.white.opacity(0.045))
    }
}

// MARK: - Overview

private struct OverviewDashboard: View {
    let snapshot: DashboardSnapshot

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
            VStack(spacing: 14) {
                HStack(spacing: 14) {
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
                    VStack(alignment: .leading, spacing: 18) {
                        HStack {
                            Text("TODAY'S TOKENS")
                                .dashboardSectionTitle()
                            Spacer()
                            Text(TokenFormatter.compact(today.totalTokens))
                                .font(.system(size: 16, weight: .semibold, design: .rounded))
                                .foregroundStyle(Color.tokenMuted)
                                .monospacedDigit()
                        }

                        TokenBreakdownRows(
                            input: today.inputTokens,
                            output: today.outputTokens,
                            cacheWrite: today.cacheWriteTokens,
                            cacheRead: today.cacheReadTokens
                        )

                        VStack(alignment: .leading, spacing: 13) {
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
                        .padding(.top, 4)
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

    var body: some View {
        DashboardCard {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(title).dashboardSectionTitle()
                    Text(value)
                        .font(.system(size: 31, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.tokenInk)
                        .monospacedDigit()
                    Text(subtitle)
                        .font(.system(size: 14, weight: .regular, design: .rounded))
                        .foregroundStyle(Color.tokenMuted)
                }
                Spacer()
                Image(systemName: symbol)
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(tint)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 138)
    }
}

private struct PaceRow: View {
    let title: String
    let value: String

    var body: some View {
        HStack {
            Text(title)
                .font(.system(size: 15, weight: .regular, design: .rounded))
                .foregroundStyle(Color.tokenMuted)
            Spacer()
            Text(value)
                .font(.system(size: 16, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.tokenInk)
                .monospacedDigit()
        }
    }
}

// MARK: - Activity

private struct ActivityDashboard: View {
    let snapshot: DashboardSnapshot

    private var last90: ArraySlice<DailyDashboardUsage> { snapshot.daily.suffix(90) }
    private var total90: Int64 { last90.reduce(0) { $0.saturatingAdd($1.costMicrosCNY) } }
    private var activeDays: Int { last90.filter { $0.totalTokens > 0 || $0.requestCount > 0 }.count }
    private var averageActiveDay: Int64 { activeDays > 0 ? total90 / Int64(activeDays) : 0 }
    private var peakDay: Int64 { last90.map(\.costMicrosCNY).max() ?? 0 }

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                DashboardCard {
                    VStack(alignment: .leading, spacing: 17) {
                        Text("ACTIVITY · LAST 20 WEEKS")
                            .dashboardSectionTitle()
                        ActivityHeatmap(days: snapshot.daily)
                    }
                }

                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                    ActivityStatCard(title: "90天总费用", value: dashboardCNY(total90), symbol: "chart.line.uptrend.xyaxis", tint: .dashboardCoral)
                    ActivityStatCard(title: "活跃天数", value: "\(activeDays) 天", symbol: "calendar", tint: .dashboardBlue)
                    ActivityStatCard(title: "日均费用", value: dashboardCNY(averageActiveDay), symbol: "bolt", tint: .dashboardOrange)
                    ActivityStatCard(title: "峰值单日", value: dashboardCNY(peakDay), symbol: "chart.bar.fill", tint: .dashboardGreen)
                }

                DashboardCard {
                    VStack(alignment: .leading, spacing: 17) {
                        Text("WEEKLY TREND · LAST 12 WEEKS")
                            .dashboardSectionTitle()
                        WeeklyCostChart(days: Array(snapshot.daily.suffix(84)))
                            .frame(height: 180)
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

    var body: some View {
        DashboardCard(insets: 15) {
            HStack(spacing: 14) {
                Image(systemName: symbol)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(tint)
                    .frame(width: 38, height: 38)
                    .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 13, weight: .regular, design: .rounded))
                        .foregroundStyle(Color.tokenMuted)
                    Text(value)
                        .font(.system(size: 20, weight: .bold, design: .rounded))
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
        VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 8) {
                Color.clear.frame(width: 13, height: 12)
                HStack(spacing: 4) {
                    ForEach(0..<20, id: \.self) { week in
                        Text(monthLabel(for: week))
                            .font(.system(size: 9, weight: .medium, design: .rounded))
                            .foregroundStyle(Color.tokenMuted)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .lineLimit(1)
                    }
                }
            }

            HStack(alignment: .top, spacing: 8) {
                VStack(spacing: 4) {
                    ForEach(1...7, id: \.self) { weekday in
                        Text(weekday == 2 ? "M" : weekday == 4 ? "W" : weekday == 6 ? "F" : "")
                            .font(.system(size: 9, weight: .medium, design: .rounded))
                            .foregroundStyle(Color.tokenMuted)
                            .frame(width: 13, height: 15)
                    }
                }

                HStack(alignment: .top, spacing: 4) {
                    ForEach(0..<20, id: \.self) { week in
                        VStack(spacing: 4) {
                            ForEach(0..<7, id: \.self) { day in
                                let point = gridDays[week * 7 + day]
                                RoundedRectangle(cornerRadius: 3, style: .continuous)
                                    .fill(color(for: point.costMicrosCNY))
                                    .frame(maxWidth: .infinity)
                                    .aspectRatio(1, contentMode: .fit)
                                    .overlay {
                                        if Calendar.autoupdatingCurrent.isDateInToday(point.date) {
                                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                                .stroke(Color.dashboardCoral, lineWidth: 2)
                                                .padding(-2)
                                        }
                                    }
                                    .help("\(point.date.formatted(date: .abbreviated, time: .omitted)) · \(dashboardCNY(point.costMicrosCNY))")
                            }
                        }
                    }
                }
            }

            HStack(spacing: 7) {
                Text("Less")
                ForEach(0..<5, id: \.self) { level in
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(legendColor(level: level))
                        .frame(width: 15, height: 15)
                }
                Text("More")
            }
            .font(.system(size: 12, weight: .regular, design: .rounded))
            .foregroundStyle(Color.tokenMuted)
            .padding(.leading, 21)
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
            HStack(alignment: .bottom, spacing: 10) {
                ForEach(Array(weeks.enumerated()), id: \.offset) { index, week in
                    let total = totals[index]
                    let height = total == 0 ? 4 : max(8, (proxy.size.height - 34) * CGFloat(Double(total) / maximum))
                    VStack(spacing: 6) {
                        Spacer(minLength: 0)
                        if total > 0 {
                            Text(shortCNY(total))
                                .font(.system(size: 8, weight: .medium, design: .rounded))
                                .foregroundStyle(Color.tokenMuted)
                                .lineLimit(1)
                        }
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(total == 0 ? Color.primary.opacity(0.075) : Color.dashboardCoral.opacity(index == weeks.count - 1 ? 0.95 : 0.55))
                            .frame(height: height)
                        Text(week.first?.date.formatted(.dateTime.month().day()) ?? "")
                            .font(.system(size: 8, weight: .medium, design: .rounded))
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
            VStack(spacing: 14) {
                DashboardCard {
                    VStack(alignment: .leading, spacing: 18) {
                        Text("COST BY MODEL · LAST 90 DAYS")
                            .dashboardSectionTitle()
                        HStack(spacing: 16) {
                            DonutChart(models: Array(visibleModels.prefix(8)), totalCost: totalCost)
                                .frame(width: 170, height: 170)
                            VStack(alignment: .leading, spacing: 13) {
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
                            .font(.system(size: 14, weight: .regular, design: .rounded))
                            .foregroundStyle(Color.tokenMuted)
                    }
                }

                DashboardCard {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("BREAKDOWN")
                            .dashboardSectionTitle()
                            .padding(.bottom, 5)
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

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.primary.opacity(0.06), lineWidth: 34)
            ForEach(Array(models.enumerated()), id: \.element.id) { index, model in
                Circle()
                    .trim(
                        from: cumulativeFraction(before: index),
                        to: cumulativeFraction(before: index + 1)
                    )
                    .stroke(
                        dashboardPalette[index % dashboardPalette.count],
                        style: StrokeStyle(lineWidth: 34, lineCap: .butt)
                    )
                    .rotationEffect(.degrees(-90))
            }
            VStack(spacing: 4) {
                Text(dashboardCNY(totalCost))
                    .font(.system(size: 23, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.tokenInk)
                    .monospacedDigit()
                Text("total")
                    .font(.system(size: 13, weight: .regular, design: .rounded))
                    .foregroundStyle(Color.tokenMuted)
            }
        }
        .padding(26)
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

    var body: some View {
        HStack(spacing: 9) {
            Circle().fill(color).frame(width: 10, height: 10)
            Text(UsageModelDisplayNameFormatter.compact(model.model))
                .font(.system(size: 15, weight: .medium, design: .rounded))
                .foregroundStyle(Color.tokenInk)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 5)
            AgentBadge(agent: model.agent)
            Text(dashboardPercent(percent))
                .font(.system(size: 14, weight: .medium, design: .rounded))
                .foregroundStyle(Color.tokenMuted)
                .monospacedDigit()
        }
    }
}

private struct ModelBreakdownRow: View {
    let model: DashboardModelUsage
    let color: Color
    let percent: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Circle().fill(color).frame(width: 9, height: 9)
                Text(UsageModelDisplayNameFormatter.compact(model.model))
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.tokenInk)
                    .lineLimit(1)
                AgentBadge(agent: model.agent)
                Spacer()
                Text("\(dashboardCNY(model.costMicrosCNY)) · \(dashboardPercent(percent))")
                    .font(.system(size: 15, weight: .medium, design: .rounded))
                    .foregroundStyle(Color.tokenMuted)
                    .monospacedDigit()
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.07))
                    Capsule().fill(color).frame(width: proxy.size.width * max(0.006, percent))
                }
            }
            .frame(height: 7)
            Text("\(model.requestCount.formatted()) req   in \(TokenFormatter.compact(model.inputTokens))   out \(TokenFormatter.compact(model.outputTokens))   cache \(TokenFormatter.compact(model.cacheReadTokens))")
                .font(.system(size: 12, weight: .regular, design: .rounded))
                .foregroundStyle(Color.tokenMuted)
                .monospacedDigit()
        }
        .padding(.vertical, 10)
    }
}

// MARK: - Projects

private struct ProjectsDashboard: View {
    let projects: [DashboardProjectUsage]

    private var visibleProjects: [DashboardProjectUsage] {
        projects.filter { $0.projectPath != nil && ($0.totalTokens > 0 || $0.costMicrosCNY > 0) }
    }

    private var maximumCost: Double { max(1, Double(visibleProjects.map(\.costMicrosCNY).max() ?? 0)) }

    var body: some View {
        DashboardCard {
            VStack(alignment: .leading, spacing: 10) {
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

    private var name: String {
        guard let path = project.projectPath else { return "Unknown Project" }
        let value = URL(fileURLWithPath: path).lastPathComponent
        return value.isEmpty ? path : value
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 9) {
                Image(systemName: "folder")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Color.tokenMuted)
                Text(name)
                    .font(.system(size: 17, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.tokenInk)
                    .lineLimit(1)
                    .truncationMode(.middle)
                AgentBadge(agent: project.agent)
                Spacer()
                Text(dashboardCNY(project.costMicrosCNY))
                    .font(.system(size: 16, weight: .medium, design: .rounded))
                    .foregroundStyle(Color.tokenMuted)
                    .monospacedDigit()
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.07))
                    Capsule().fill(color).frame(width: proxy.size.width * max(0.006, fraction))
                }
            }
            .frame(height: 8)
            HStack(spacing: 15) {
                Text("\(project.requestCount.formatted()) req")
                Text("\(TokenFormatter.compact(project.totalTokens)) tokens")
                Text("\(project.activeDays) days")
                if let lastUsed = project.lastUsed {
                    Text("last \(lastUsed.formatted(.dateTime.year().month().day()))")
                }
            }
            .font(.system(size: 12, weight: .regular, design: .rounded))
            .foregroundStyle(Color.tokenMuted)
            .monospacedDigit()
        }
        .padding(.vertical, 14)
        .help(project.projectPath ?? "")
    }
}

// MARK: - Sessions

private struct SessionsDashboard: View {
    let snapshot: DashboardSnapshot
    let selectedDate: Date
    let onSelectDate: (Date) -> Void

    private var sessions: [DashboardSessionUsage] { snapshot.sessions }
    private var totalCost: Int64 { sessions.reduce(0) { $0.saturatingAdd($1.costMicrosCNY) } }
    private var totalTokens: Int64 { sessions.reduce(0) { $0.saturatingAdd($1.totalTokens) } }

    var body: some View {
        VStack(spacing: 14) {
            DashboardCard(insets: 14) {
                HStack {
                    dateButton(symbol: "chevron.left", offset: -1)
                    Spacer()
                    VStack(spacing: 5) {
                        Text(selectedDate.formatted(.dateTime.year().month(.twoDigits).day(.twoDigits)))
                            .font(.system(size: 20, weight: .bold, design: .rounded))
                            .foregroundStyle(Color.tokenInk)
                            .monospacedDigit()
                        Text("\(sessions.count) sessions · \(dashboardCNY(totalCost)) · \(TokenFormatter.compact(totalTokens)) tokens")
                            .font(.system(size: 14, weight: .regular, design: .rounded))
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
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Color.tokenInk)
                .frame(width: 46, height: 46)
                .background(Color.white.opacity(0.16), in: Circle())
                .overlay { Circle().stroke(Color.white.opacity(0.48), lineWidth: 1) }
        }
        .buttonStyle(.plain)
    }
}

private struct SessionRow: View {
    let session: DashboardSessionUsage

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
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(displayTitle)
                    .font(.system(size: 17, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.tokenInk)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(dashboardCNY(session.costMicrosCNY))
                    .font(.system(size: 17, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.dashboardCoral)
                    .monospacedDigit()
            }

            HStack(spacing: 8) {
                AgentBadge(agent: session.agent)
                Text(UsageModelDisplayNameFormatter.compact(session.model))
                Text(timeRange)
                Text(shortID)
                Spacer()
                Text("\(session.requestCount.formatted()) req")
            }
            .font(.system(size: 12, weight: .regular, design: .rounded))
            .foregroundStyle(Color.tokenMuted)
            .monospacedDigit()

            TokenCompositionBar(session: session)
                .frame(height: 6)

            HStack(spacing: 15) {
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
            .font(.system(size: 11.5, weight: .regular, design: .rounded))
            .foregroundStyle(Color.tokenMuted)
            .monospacedDigit()
        }
        .padding(.vertical, 15)
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
    let insets: CGFloat
    @ViewBuilder let content: Content

    init(insets: CGFloat = 16, @ViewBuilder content: () -> Content) {
        self.insets = insets
        self.content = content()
    }

    var body: some View {
        content
            .padding(insets)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.white.opacity(0.16), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(Color.white.opacity(0.56), lineWidth: 1)
            }
            .shadow(color: Color.black.opacity(0.035), radius: 15, y: 7)
    }
}

private struct AgentBadge: View {
    let agent: String

    private var identity: AgentIdentity { AgentIdentity.resolve(agent) }
    private var tint: Color { AgentAppearance.color(forID: identity.id) }

    var body: some View {
        Text(identity.displayName.uppercased())
            .font(.system(size: 10, weight: .bold, design: .rounded))
            .tracking(0.7)
            .foregroundStyle(tint)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(tint.opacity(0.11), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

private struct TokenBreakdownRows: View {
    let input: Int64
    let output: Int64
    let cacheWrite: Int64
    let cacheRead: Int64

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
        VStack(spacing: 13) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 12) {
                    Circle().fill(row.2).frame(width: 9, height: 9)
                    Text(row.0)
                        .font(.system(size: 15, weight: .regular, design: .rounded))
                        .foregroundStyle(Color.tokenMuted)
                        .frame(width: 90, alignment: .leading)
                    GeometryReader { proxy in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.primary.opacity(0.07))
                            Capsule().fill(row.2.opacity(0.72)).frame(width: proxy.size.width * CGFloat(Double(row.1) / maximum))
                        }
                    }
                    .frame(height: 6)
                    Text(TokenFormatter.compact(row.1))
                        .font(.system(size: 14, weight: .medium, design: .rounded))
                        .foregroundStyle(Color.tokenMuted)
                        .monospacedDigit()
                        .frame(width: 70, alignment: .trailing)
                }
            }
        }
    }
}

private struct InlineEmptyState: View {
    let text: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "tray")
                .font(.system(size: 28, weight: .light))
            Text(text)
                .font(.system(size: 14, weight: .medium, design: .rounded))
        }
        .foregroundStyle(Color.tokenMuted)
        .frame(maxWidth: .infinity, minHeight: 220)
    }
}

private struct LoadingStateView: View {
    var body: some View {
        VStack(spacing: 14) {
            ProgressView().controlSize(.regular)
            Text("正在读取本地用量…")
                .font(.system(size: 14, weight: .medium, design: .rounded))
                .foregroundStyle(Color.tokenMuted)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct EmptyUsageView: View {
    let refresh: () -> Void

    var body: some View {
        VStack(spacing: 15) {
            Image(systemName: "chart.bar.xaxis")
                .font(.system(size: 34, weight: .light))
            Text("还没有可显示的用量")
                .font(.system(size: 18, weight: .semibold, design: .rounded))
            Text("Token Usage 会自动读取本机 Agent 的会话记录。")
                .font(.system(size: 13, weight: .regular, design: .rounded))
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

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Color.orange)
            Text("刷新失败，当前显示上次数据：\(message)")
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(Color.tokenInk)
                .lineLimit(2)
            Spacer()
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 34)
        .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
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

private extension Text {
    func dashboardSectionTitle() -> some View {
        self
            .font(.system(size: 14, weight: .bold, design: .rounded))
            .tracking(1.0)
            .foregroundStyle(Color.tokenMuted)
    }
}

private extension Color {
    static let dashboardCoral = Color(red: 1.00, green: 0.31, blue: 0.36)
    static let dashboardOrange = Color(red: 0.98, green: 0.57, blue: 0.02)
    static let dashboardGreen = Color(red: 0.08, green: 0.74, blue: 0.43)
    static let dashboardBlue = Color(red: 0.21, green: 0.49, blue: 0.94)
    static let dashboardPurple = Color(red: 0.53, green: 0.31, blue: 0.97)
}
