import SwiftUI
import WhirrCore

@main
struct WhirrApp: App {
    @State private var monitor = SystemMonitor()

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(monitor: monitor)
        } label: {
            MenuBarFanIcon(severity: monitor.worstSeverity)
        }
        .menuBarExtraStyle(.window)
    }
}

/// Menu bar label icon. The fan signals severity through color + fill +
/// a built-in SF Symbol pulse — *not* a SwiftUI animation. A continuous
/// SwiftUI animation here (TimelineView, withAnimation) forces the status
/// item to re-rasterize every frame and pegs CPU near 100%; the native
/// `.symbolEffect` runs inside the SF Symbols renderer instead and is
/// effectively free.
private struct MenuBarFanIcon: View {
    let severity: Severity

    var body: some View {
        Image(systemName: symbolName)
            .foregroundStyle(tint)
            .symbolEffect(
                .variableColor.iterative.reversing,
                options: .repeating,
                isActive: severity != .ok
            )
    }

    private var symbolName: String {
        severity == .critical ? "fanblades.fill" : "fanblades"
    }

    private var tint: Color {
        switch severity {
        case .ok:       return .primary
        case .warning:  return .yellow
        case .critical: return .red
        }
    }
}
