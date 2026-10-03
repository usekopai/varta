import Foundation

/// Monotonic per-command timing. Contains no transcript, arguments, paths, or event titles.
public final class CommandTiming: @unchecked Sendable {
    public struct Sample: Codable {
        public let schemaVersion: Int
        public let id: String, startedAt: String, version: String, outcome: String
        public let intent: String?, speechSource: String?
        public let transcriptMs: Double?, transcriptToPlanMs: Double?, planToStatusMs: Double?
        public let releaseToStatusMs: Double
        public let routingReportedMs: Double?, jevSuccessfulAttemptMs: Double?
    }
    private let lock = NSLock()
    private let clock: () -> Double
    private let start: Double
    private let id = UUID().uuidString, startedAt = ISO8601DateFormatter().string(from: Date())
    private var transcript: Double?, plan: Double?, intent: String?, speechSource: String?
    private var routing: Double?, jev: Double?
    private var finished = false
    public init(clock: @escaping () -> Double = { ProcessInfo.processInfo.systemUptime }) {
        self.clock = clock; start = clock()
    }
    public func transcribed(source: String) {
        lock.withLock { guard !finished else { return }; transcript = clock(); speechSource = source }
    }
    public func observe(_ event: PipelineEvent) -> Sample? {
        switch event {
        case let .plan(p):
            lock.withLock { guard !finished else { return }; plan = clock(); intent = p.intent; routing = p.latencyMs; jev = p.jevMs }
            return nil
        case let .done(ok, _): return finish(ok ? "success" : "failure")
        case .clarification: return finish("clarification")
        default: return nil
        }
    }
    public func finish(_ outcome: String) -> Sample? {
        lock.withLock {
            guard !finished else { return nil }; finished = true
            let end = clock()
            return Sample(schemaVersion: 1, id: id, startedAt: startedAt, version: Varta.version, outcome: outcome,
                          intent: intent, speechSource: speechSource,
                          transcriptMs: transcript.map { ($0-start)*1000 },
                          transcriptToPlanMs: transcript.flatMap { t in plan.map { ($0-t)*1000 } },
                          planToStatusMs: plan.map { (end-$0)*1000 }, releaseToStatusMs: (end-start)*1000,
                          routingReportedMs: routing, jevSuccessfulAttemptMs: jev)
        }
    }
}
