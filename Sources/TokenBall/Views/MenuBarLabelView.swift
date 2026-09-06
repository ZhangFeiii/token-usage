import SwiftUI
import TokenBallCore

struct MenuBarLabelView: View {
    @ObservedObject var viewModel: UsageViewModel

    /// An optional presentation hook for a future ViewModel cost formatter.
    /// When omitted, the ViewModel's CNY total is formatted locally. Keeping
    /// this hook makes the menu-bar shell independent from presentation details
    /// if the formatter later moves into the model.
    private let suppliedTodayCostText: String?

    init(viewModel: UsageViewModel, todayCostText: String? = nil) {
        self.viewModel = viewModel
        self.suppliedTodayCostText = todayCostText
    }

    private var todayCostMicrosCNY: Int64 {
        viewModel.todayCostMicrosCNY
    }

    private var todayCostText: String {
        suppliedTodayCostText ?? TokenFormatter.cny(micros: todayCostMicrosCNY)
    }

    var body: some View {
        HStack(spacing: 4) {
            TokenOrbView(size: 15)
            Text(todayCostText)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .monospacedDigit()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Token Usage 今日成本 \(todayCostText)")
    }
}

struct TokenOrbView: View {
    let size: CGFloat

    var body: some View {
        ZStack {
            Circle()
                .fill(
                    AngularGradient(
                        colors: [
                            Color(red: 0.96, green: 0.35, blue: 0.37),
                            Color(red: 0.93, green: 0.68, blue: 0.22),
                            Color(red: 0.15, green: 0.71, blue: 0.56),
                            Color(red: 0.29, green: 0.56, blue: 0.92),
                            Color(red: 0.55, green: 0.37, blue: 0.87),
                            Color(red: 0.96, green: 0.35, blue: 0.37)
                        ],
                        center: .center
                    )
                )
            Circle()
                .fill(
                    RadialGradient(
                        colors: [.white.opacity(0.9), .white.opacity(0)],
                        center: UnitPoint(x: 0.32, y: 0.24),
                        startRadius: 0,
                        endRadius: size * 0.48
                    )
                )
                .blendMode(.screen)
            Circle()
                .stroke(.white.opacity(0.58), lineWidth: 0.7)
        }
        .frame(width: size, height: size)
        .shadow(color: Color.indigo.opacity(0.25), radius: 1.5, y: 1)
    }
}
