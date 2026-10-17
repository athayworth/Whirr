import AppKit
import Observation
import WhirrCore

/// The connection side of the app: passive watching, the user-run test,
/// and the history they write.
@MainActor
@Observable
final class ConnectionController {
    /// Latest passive connection state (pings + Wi-Fi link).
    var connection: ConnectionSnapshot = .empty
    /// Non-nil while a "Check my connection" test is running.
    var testPhase: ConnectionTestRunner.Phase?
    /// Most recent completed full test (this session or loaded from disk).
    var latestTest: ConnectionTestResult?
    /// Router IP, for the channel-change how-to ("open http://…").
    var gatewayIP: String?
    let store = ConnectionHistoryStore()
    private let monitor: ConnectionMonitor
    private let runner = ConnectionTestRunner()

    init() {
        monitor = ConnectionMonitor(store: store)
        latestTest = store.tests().last
    }

    /// Starts the passive watcher and pauses it across sleep, so a closed
    /// lid never reads as an outage.
    func start() {
        let monitor = self.monitor
        Task { await monitor.start() }
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { _ in
            Task { await monitor.setPaused(true) }
        }
        center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            Task {
                // Let Wi-Fi re-associate before judging the connection.
                try? await Task.sleep(for: .seconds(10))
                await monitor.setPaused(false)
            }
        }
        Task { [weak self] in
            let ip = await Task.detached { GatewayResolver.current()?.ip }.value
            self?.gatewayIP = ip
        }
    }

    var passiveMonitor: ConnectionMonitor { monitor }

    func runTest() {
        guard testPhase == nil else { return }
        testPhase = .measuringIdle
        let runner = self.runner
        let store = self.store
        let passive = monitor
        // Frozen now, so the saved result is always graded against the
        // 10 minutes before it — not whatever is happening when viewed.
        let before = PassiveBefore(gateway: connection.gateway10m, internet: connection.internet10m,
                                   gatewayPingable: connection.gatewayPingable, isWired: connection.isWired)
        Task { [weak self] in
            // The test saturates the line on purpose. Passive pings taken
            // meanwhile would record self-inflicted stalls into history
            // and skew the per-channel comparison, so pause them.
            await passive.setPaused(true)
            defer { Task { await passive.setPaused(false) } }
            let result = await runner.run(before: before) { phase in
                Task { @MainActor in self?.testPhase = phase == .done ? nil : phase }
            }
            store.saveTest(result)
            await MainActor.run {
                self?.latestTest = result
                self?.testPhase = nil
            }
        }
    }
}
