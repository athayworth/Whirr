import Foundation
import Darwin

/// Wraps the kernel's authoritative memory-pressure signal —
/// `DISPATCH_SOURCE_TYPE_MEMORYPRESSURE`. Same source that drives
/// Activity Monitor's "Memory Pressure" graph and `memory_pressure(1)`.
///
/// The hand-rolled classifier in `SystemSampler.classifyPressure` stays
/// as a bootstrap fallback: dispatch sources only fire on *transitions*,
/// so before the first event we don't have a kernel verdict to read. The
/// monitor publishes `nil` in that window; SystemSampler can use its
/// hand-roll value until a real event lands.
///
/// Thread safety: the dispatch source fires on a background queue; reads
/// of `.current` may come from any actor / thread. State is guarded by a
/// single `NSLock` — never held across a callback.
public final class MemoryPressureMonitor: @unchecked Sendable {
    public static let shared = MemoryPressureMonitor()

    private let lock = NSLock()
    private var _current: MemoryPressure?
    /// `nil` until the kernel reports a transition. Callers should
    /// fall back to their own classification in the bootstrap window.
    public var current: MemoryPressure? {
        lock.withLock { _current }
    }

    private let source: DispatchSourceMemoryPressure

    private init() {
        // .all = .normal | .warning | .critical. We want every transition
        // so the published value tracks back down when pressure eases, not
        // just escalations.
        source = DispatchSource.makeMemoryPressureSource(
            eventMask: .all,
            queue: DispatchQueue.global(qos: .utility)
        )
        source.setEventHandler { [weak self] in
            guard let self else { return }
            let event = self.source.data
            let new: MemoryPressure
            if event.contains(.critical)      { new = .critical }
            else if event.contains(.warning)  { new = .warning }
            else                              { new = .normal }
            self.lock.withLock { self._current = new }
        }
        source.resume()
    }
}
