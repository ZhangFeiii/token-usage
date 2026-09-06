import SwiftUI
import TokenBallCore

enum AgentAppearance {
    static func color(for agent: AgentUsage) -> Color {
        color(forID: agent.id)
    }

    static func color(forID id: String) -> Color {
        switch id {
        case "codex": return Color(red: 0.10, green: 0.69, blue: 0.54)
        case "opencode": return Color(red: 0.28, green: 0.55, blue: 0.88)
        case "claude": return Color(red: 0.89, green: 0.44, blue: 0.31)
        case "gemini": return Color(red: 0.48, green: 0.40, blue: 0.84)
        case "grok-build": return Color(red: 0.91, green: 0.65, blue: 0.20)
        default:
            let scalarSum = id.unicodeScalars.reduce(0) { $0 + Int($1.value) }
            let hue = Double(scalarSum % 360) / 360.0
            return Color(hue: hue, saturation: 0.54, brightness: 0.82)
        }
    }
}

extension Color {
    // Semantic ink keeps the translucent surfaces legible in both appearances.
    static let tokenInk = Color.primary.opacity(0.84)
    static let tokenMuted = Color.secondary.opacity(0.78)
    static let tokenLine = Color.primary.opacity(0.10)
    static let tokenSurface = Color.white.opacity(0.10)
    static let tokenSpecular = Color.white.opacity(0.56)
    static let tokenBlue = Color(red: 0.18, green: 0.49, blue: 0.94)
    static let tokenGreen = Color(red: 0.10, green: 0.73, blue: 0.54)
}
