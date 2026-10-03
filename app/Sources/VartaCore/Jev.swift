import Foundation

public struct JevError: Error, CustomStringConvertible {
    public let description: String
    public init(description: String) { self.description = description }
}

public struct JevReply {
    public let answers: [String: JSON]
    public let model: String
    public let inputTokens: Int
    public let latencyMs: Double

    public init(answers: [String: JSON], model: String, inputTokens: Int, latencyMs: Double) {
        self.answers = answers
        self.model = model
        self.inputTokens = inputTokens
        self.latencyMs = latencyMs
    }
}

/// Minimal client for TypeSafe's System One endpoint (Jev). Keeps one URLSession so the TLS
/// connection stays warm between commands (~0.4 s per request warm, ~1 s cold).
public final class Jev {
    public let model: String
    private let endpoint: URL
    private let auth: () async throws -> String
    private let session: URLSession
    private let maxRetries = 3

    /// `auth` returns a bearer token: the user's own TypeSafe key, or later a backend-issued token.
    public init(model: String = "jev-latest", baseURL: String = "https://api.typesafe.ai", auth: @escaping () async throws -> String) {
        self.model = model
        self.endpoint = URL(string: baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/v1/systemone")!
        self.auth = auth
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 15
        cfg.httpMaximumConnectionsPerHost = 8
        self.session = URLSession(configuration: cfg)
    }

    public func ask(state: JSON, questions: [(String, JSON)]) async throws -> JevReply {
        let body = obj(("model", .string(model)), ("state", state), ("questions", .object(questions)))
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("Bearer \(try await auth())", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = body.data

        for attempt in 0...maxRetries {
            let t0 = Date()
            let data: Data
            let resp: URLResponse
            do {
                (data, resp) = try await session.data(for: req)
            } catch {
                if attempt == maxRetries { throw JevError(description: "network error: \(error.localizedDescription)") }
                try await Task.sleep(nanoseconds: UInt64(0.3 * pow(2, Double(attempt)) * 1e9))
                continue
            }
            let latency = Date().timeIntervalSince(t0) * 1000
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if status == 200 {
                let root = try JSON.parse(data)
                guard let answersObj = root["answers"]?.object else { throw JevError(description: "Jev: no answers") }
                let answers = Dictionary(answersObj, uniquingKeysWith: { a, _ in a })
                let missing = questions.map(\.0).filter { answers[$0] == nil }
                if !missing.isEmpty { throw JevError(description: "Jev: missing answers for \(missing)") }
                let tokens = Int(root["usage"]?["input_tokens"]?.double ?? 0)
                return JevReply(answers: answers, model: root["model"]?.string ?? model, inputTokens: tokens, latencyMs: latency)
            }
            if [429, 500, 502, 503, 504, 529].contains(status) && attempt < maxRetries {
                try await Task.sleep(nanoseconds: UInt64(0.3 * pow(2, Double(attempt)) * 1e9))
                continue
            }
            throw JevError(description: "Jev HTTP \(status): \(String(data: data.prefix(400), encoding: .utf8) ?? "")")
        }
        throw JevError(description: "unreachable")
    }
}

extension JSON {
    /// Jev answer helpers.
    var choice: String? { self["choice"]?.string }
    var confidence: Double { self["confidence"]?.double ?? 0 }
    var noul: Double { self["noul"]?.double ?? 0 }
    var probabilities: [(String, Double)] { self["probabilities"]?.object?.compactMap { k, v in v.double.map { (k, $0) } } ?? [] }
}
