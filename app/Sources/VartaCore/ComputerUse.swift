import CoreGraphics
import Foundation

/// Feature switches. Computer use (Claude driving the screen with screenshots) is switched off for now:
/// the code below is kept so it can come back, but nothing calls it, Setup doesn't ask for the Screen
/// Recording permission or for an Anthropic key, and tasks that need it say so.
public enum Features {
    public static let computerUse = false
}

/// Cancellation shared between the pipeline and a running agent (Esc in the notch).
public final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var set = false
    public init() {}
    public var isSet: Bool { lock.lock(); defer { lock.unlock() }; return set }
    public func cancel() { lock.lock(); set = true; lock.unlock() }
}

/// What the loop needs from the machine. Coordinates are screenshot pixels.
public protocol Hands {
    var shotSize: (Int, Int) { get }
    func screenshot() async throws -> Data
    func zoom(_ region: [Double]) async throws -> Data
    func frontmost() -> String?
    func secureFocus() -> Bool
    func perform(_ name: String, _ input: JSON) async throws -> String
}

public final class MacHands: Hands {
    let screen: Screen

    public init(app: String) {
        screen = Screen(forApp: app)
    }

    public var shotSize: (Int, Int) { screen.shotSize }
    public func screenshot() async throws -> Data { try await screen.capture() }

    public func zoom(_ region: [Double]) async throws -> Data {
        guard region.count == 4 else { throw InputError(description: "zoom needs [x0, y0, x1, y1]") }
        let s = screen.scale
        return try await screen.capture(region: CGRect(x: region[0] / s, y: region[1] / s, width: max(1, (region[2] - region[0]) / s), height: max(1, (region[3] - region[1]) / s)))
    }

    public func frontmost() -> String? { Observe.frontmostApp() }
    public func secureFocus() -> Bool { Input.focusIsSecure() }

    public func perform(_ name: String, _ input: JSON) async throws -> String {
        let coords = input["coordinate"]?.array?.compactMap(\.double)
        let pt = coords.map { screen.toGlobal($0) }
        let mods = input["text"]?.string
        switch name {
        case "left_click", "right_click", "middle_click", "double_click", "triple_click":
            let button = name == "right_click" ? "right" : name == "middle_click" ? "middle" : "left"
            let count = name == "double_click" ? 2 : name == "triple_click" ? 3 : 1
            try Input.click(pt ?? Input.cursor(), button: button, count: count, modifiers: mods)
        case "left_click_drag":
            guard let s = input["start_coordinate"]?.array?.compactMap(\.double), let pt else { throw InputError(description: "drag needs coordinates") }
            try Input.drag(from: screen.toGlobal(s), to: pt, modifiers: mods)
        case "mouse_move":
            guard let pt else { throw InputError(description: "mouse_move needs a coordinate") }
            Input.move(pt)
        case "left_mouse_down", "left_mouse_up":
            Input.mouseButton(down: name == "left_mouse_down")
        case "cursor_position":
            let (x, y) = screen.toShot(Input.cursor())
            return "X=\(x), Y=\(y)"
        case "scroll":
            if let pt { Input.move(pt) }
            try Input.scroll(input["scroll_direction"]?.string ?? "down", amount: Int(input["scroll_amount"]?.double ?? 3), modifiers: mods)
        case "type":
            try Input.type(input["text"]?.string ?? "")
        case "key":
            try Input.key(input["text"]?.string ?? "", repeat: Int(input["repeat"]?.double ?? 1))
        case "hold_key":
            try Input.key(input["text"]?.string ?? "", hold: min(input["duration"]?.double ?? 0.5, 5))
        case "wait":
            try await Task.sleep(nanoseconds: UInt64(min(input["duration"]?.double ?? 1, 5) * 1e9))
        default:
            throw InputError(description: "unsupported action '\(name)'")
        }
        try await Task.sleep(nanoseconds: 150_000_000) // let the UI react before the next action
        return "OK"
    }
}

/// How computer-use requests reach Anthropic. Step 2 adds a backend-proxied route.
public enum ClaudeRoute {
    /// Anthropic API key: the current computer toolset.
    case direct(apiKey: String)
    /// Vercel AI Gateway: it rejects the toolset (checked 2026-09-25) but accepts the earlier beta tool.
    case gateway(apiKey: String)

    public static func fromCredentials() -> ClaudeRoute? {
        if let k = Credentials.get(.anthropic) { return .direct(apiKey: k) }
        if let k = Credentials.get(.gateway) { return .gateway(apiKey: k) }
        return nil
    }

    var legacy: Bool { if case .gateway = self { return true }; return false }
}

public struct AgentResult {
    public var ok = false
    public var summary = ""
    public var turns = 0
    public var actions: [String] = []
    public var seconds = 0.0
    public var inputTokens = 0
    public var outputTokens = 0
}

/// Claude computer use for the part of a command that has no API. Currently switched off.
public final class ComputerAgent {
    public static var model = ProcessInfo.processInfo.environment["VARTA_CU_MODEL"] ?? "claude-sonnet-5"
    public static var effort = ProcessInfo.processInfo.environment["VARTA_CU_EFFORT"] ?? "low"
    static let maxTurns = 12
    static let timeLimit: TimeInterval = 90
    static let halt = "Not executed: an earlier computer action in this turn failed."

    static let system = """
    You operate a Mac to finish one small, specific task for a voice assistant. The user is waiting, so be quick.

    Rules:
    - Only work inside these apps: %@. Do not switch to or click in any other app.
    - Never type passwords, and never buy, send, delete, or post anything.
    - Prefer the most direct action; do not explore.
    - End each group of actions with a screenshot so you can check the result.
    - When the task is done, reply with one short line starting with "DONE:" describing what you did. If you cannot do it, reply with "FAILED:" and why.
    %@
    """

    static let appHints = [
        "Spotify": "- Spotify: double-click a song row in the Songs list to play it, or hover the Top result card and click its round green play button. If Spotify shows the search page but no results, type the query into the search field at the top.",
    ]

    let route: ClaudeRoute
    let session: URLSession

    public init(route: ClaudeRoute) {
        self.route = route
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 60
        session = URLSession(configuration: cfg)
    }

    struct Stop: Error { let reason: String }

    struct Call {
        let id: String
        let name: String
        let input: JSON
    }

    func calls(in content: [JSON]) -> [Call] {
        content.compactMap { b in
            guard b["type"]?.string == "tool_use", let id = b["id"]?.string else { return nil }
            if route.legacy {
                guard b["name"]?.string == "computer", let input = b["input"]?.object else { return nil }
                let action = input.first { $0.0 == "action" }?.1.string ?? ""
                return Call(id: id, name: action, input: .object(input.filter { $0.0 != "action" }))
            }
            guard b["toolset_name"]?.string == "computer" else { return nil }
            return Call(id: id, name: b["name"]?.string ?? "", input: b["input"] ?? obj())
        }
    }

    func result(_ id: String, _ content: JSON, error: Bool = false) -> JSON {
        var pairs: [(String, JSON)] = [("type", "tool_result"), ("tool_use_id", .string(id)), ("content", content)]
        if !route.legacy { pairs.append(("toolset_name", "computer")) }
        if error { pairs.append(("is_error", true)) }
        return .object(pairs)
    }

    static func image(_ png: Data) -> JSON {
        obj(("type", "image"), ("source", obj(("type", "base64"), ("media_type", "image/png"), ("data", .string(png.base64EncodedString())))))
    }

    static func describe(_ c: Call) -> String {
        if c.name == "type" { return "type(\(c.input["text"]?.string?.count ?? 0) chars)" }
        let args = (c.input.object ?? []).filter { $0.0 != "text" || c.name == "key" || c.name.hasSuffix("click") }
            .map { "\($0.0)=\($0.1)" }.joined(separator: ", ")
        return "\(c.name)(\(args))"
    }

    /// Run one turn's actions in order; stop at the first failure and answer every block.
    func runActions(_ calls: [Call], hands: Hands, allowed: Set<String>, cancel: CancelFlag, log: (String) -> Void) async -> ([JSON], String?) {
        var results: [JSON] = []
        var failed = false
        var stop: String?
        for c in calls {
            if failed {
                results.append(result(c.id, .string(ComputerAgent.halt), error: true))
                continue
            }
            log(ComputerAgent.describe(c))
            do {
                if cancel.isSet { throw Stop(reason: "cancelled") }
                if c.name == "screenshot" {
                    results.append(result(c.id, [ComputerAgent.image(try await hands.screenshot())]))
                    continue
                }
                if c.name == "zoom" {
                    let region = c.input["region"]?.array?.compactMap(\.double) ?? []
                    results.append(result(c.id, [ComputerAgent.image(try await hands.zoom(region))]))
                    continue
                }
                if c.name != "wait" && c.name != "cursor_position" {
                    let front = hands.frontmost()
                    if !allowed.contains(front ?? "") {
                        throw Stop(reason: "\(front ?? "an unknown app") is in front; only \(allowed.sorted().joined(separator: ", ")) may be used")
                    }
                }
                if c.name == "type" && hands.secureFocus() { throw Stop(reason: "focus is a password field; typing is not allowed") }
                let text = try await hands.perform(c.name, c.input)
                results.append(result(c.id, [obj(("type", "text"), ("text", .string(text)))]))
            } catch let s as Stop {
                failed = true
                stop = s.reason
                log("  ✗ stopped: \(s.reason)")
                results.append(result(c.id, .string("Error: \(s.reason)"), error: true))
            } catch {
                failed = true
                log("  ✗ \(error)")
                results.append(result(c.id, .string("Error: \(error)"), error: true))
            }
        }
        return (results, stop)
    }

    func send(system: String, messages: [JSON], shot: (Int, Int)) async throws -> JSON {
        var pairs: [(String, JSON)] = [
            ("model", .string(route.legacy ? "anthropic/\(ComputerAgent.model.replacingOccurrences(of: #"-(\d+)-(\d+)$"#, with: "-$1.$2", options: .regularExpression))" : ComputerAgent.model)),
            ("max_tokens", 8000),
            ("system", .string(system)),
            ("output_config", obj(("effort", .string(ComputerAgent.effort)))),
            ("messages", .array(messages)),
        ]
        var req: URLRequest
        switch route {
        case let .direct(key):
            let toolset = obj(("type", "computer_toolset_20260801"), ("cache_control", obj(("type", "ephemeral"))))
            pairs.append(("tools", .array([toolset])))
            req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
            req.setValue(key, forHTTPHeaderField: "x-api-key")
        case let .gateway(key):
            let tool = obj(("type", "computer_20251124"), ("name", "computer"),
                           ("display_width_px", .number(Double(shot.0))), ("display_height_px", .number(Double(shot.1))),
                           ("enable_zoom", true), ("cache_control", obj(("type", "ephemeral"))))
            pairs.append(("tools", .array([tool])))
            req = URLRequest(url: URL(string: "https://ai-gateway.vercel.sh/v1/messages")!)
            req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            req.setValue("computer-use-2025-11-24", forHTTPHeaderField: "anthropic-beta")
        }
        req.httpMethod = "POST"
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.httpBody = JSON.object(pairs).data
        for attempt in 0...2 {
            let (data, resp) = try await session.data(for: req)
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if status == 200 { return try JSON.parse(data) }
            if [429, 500, 502, 503, 504, 529].contains(status) && attempt < 2 {
                try await Task.sleep(nanoseconds: UInt64(pow(2, Double(attempt)) * 1e9))
                continue
            }
            throw InputError(description: "Claude HTTP \(status): \(String(data: data.prefix(300), encoding: .utf8) ?? "")")
        }
        throw InputError(description: "unreachable")
    }

    /// `doneCheck` runs after each batch; if it returns a description, the task is finished and the
    /// loop ends without spending another model turn just to look and say DONE.
    public func run(task: String, apps: [String], hands: Hands, cancel: CancelFlag,
                    onAction: @escaping (String) -> Void = { _ in },
                    doneCheck: (() async -> String?)? = nil) async -> AgentResult {
        let t0 = Date()
        var res = AgentResult()
        let hints = apps.compactMap { ComputerAgent.appHints[$0] }.joined(separator: "\n")
        let system = String(format: ComputerAgent.system, apps.joined(separator: ", "), hints)
        var log: [String] = []
        let record: (String) -> Void = { line in log.append(line); onAction(line) }
        do {
            // Instruction text before the image improves click accuracy.
            var messages: [JSON] = [obj(("role", "user"), ("content", [obj(("type", "text"), ("text", .string(task + "\n\nThis is the screen right now:"))),
                                                                          ComputerAgent.image(try await hands.screenshot())]))]
            for turn in 1...ComputerAgent.maxTurns {
                if cancel.isSet { res.summary = "FAILED: cancelled"; break }
                if Date().timeIntervalSince(t0) > ComputerAgent.timeLimit { res.summary = "FAILED: time limit"; break }
                let resp = try await send(system: system, messages: messages, shot: hands.shotSize)
                res.turns = turn
                let u = resp["usage"]
                res.inputTokens += Int((u?["input_tokens"]?.double ?? 0) + (u?["cache_read_input_tokens"]?.double ?? 0) + (u?["cache_creation_input_tokens"]?.double ?? 0))
                res.outputTokens += Int(u?["output_tokens"]?.double ?? 0)
                if resp["stop_reason"]?.string == "refusal" { res.summary = "FAILED: the model declined this request"; break }
                let content = resp["content"]?.array ?? []
                messages.append(obj(("role", "assistant"), ("content", .array(content))))
                let cs = calls(in: content)
                let callIDs = Set(cs.map(\.id))
                let others = content.filter { $0["type"]?.string == "tool_use" && !callIDs.contains($0["id"]?.string ?? "") }
                let text = content.compactMap { $0["type"]?.string == "text" ? $0["text"]?.string : nil }.joined(separator: " ").trimmingCharacters(in: .whitespaces)
                if cs.isEmpty && others.isEmpty {
                    res.summary = text.isEmpty ? "FAILED: no answer" : text
                    res.ok = text.uppercased().hasPrefix("DONE")
                    break
                }
                var (results, stop) = await runActions(cs, hands: hands, allowed: Set(apps), cancel: cancel, log: record)
                results += others.map { obj(("type", "tool_result"), ("tool_use_id", $0["id"] ?? .null), ("content", "Unknown tool."), ("is_error", true)) }
                if let stop { res.summary = "FAILED: \(stop)"; break }
                if let doneCheck, !results.contains(where: { $0["is_error"] != nil }), let finished = await doneCheck() {
                    res.ok = true
                    res.summary = "DONE: \(finished)"
                    break
                }
                messages.append(obj(("role", "user"), ("content", .array(results))))
                if turn == ComputerAgent.maxTurns { res.summary = "FAILED: step limit (\(ComputerAgent.maxTurns) turns)" }
            }
        } catch {
            res.summary = "FAILED: \(error)"
        }
        res.actions = log
        res.seconds = Date().timeIntervalSince(t0)
        return res
    }
}
