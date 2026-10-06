import Foundation

/// Model preparation is separate from command execution and API connectivity.
public enum SpeechPreparation: Equatable, Sendable {
    case preparing
    case downloading(Double?)
    case loading
    case ready
    case failed(String)

    public var fraction: Double? {
        guard case let .downloading(value) = self, let value, value.isFinite else { return nil }
        return min(1, max(0, value))
    }

    public var isBusy: Bool {
        switch self {
        case .preparing, .downloading, .loading: return true
        case .ready, .failed: return false
        }
    }

    public var status: String {
        switch self {
        case .preparing: return "Preparing speech…"
        case .downloading:
            if let fraction { return "Downloading Whisper… \(Int((fraction * 100).rounded()))%" }
            return "Downloading Whisper…"
        case .loading: return "Loading and optimizing Whisper…"
        case .ready: return "Speech ready"
        case let .failed(message): return "Speech preparation failed: \(message)"
        }
    }
}
