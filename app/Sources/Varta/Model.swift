import Foundation
import VartaCore
import SwiftUI

struct Chip: Identifiable, Hashable {
    let id = UUID()
    let symbol: String
    let text: String
}

enum Phase: Equatable {
    case idle
    case listening
    case thinking
    case acting
    case done(ok: Bool)
    case message // offline / permission problems
    case preparingSpeech
}

/// Everything the notch shows. Mutated on the main thread only.
final class NotchModel: ObservableObject {
    @Published var phase: Phase = .idle
    @Published var transcript = ""
    @Published var level: Float = 0
    @Published var chips: [Chip] = []
    @Published var status = ""
    @Published var steps = 0
    @Published var connected = false

    var isExpanded: Bool { phase != .idle }

    func reset() {
        transcript = ""
        chips = []
        status = ""
        steps = 0
        level = 0
    }

    /// Short chips for what Jev understood.
    func applyPlan(_ plan: Plan) {
        var out: [Chip] = []
        func v(_ k: String) -> String? { plan.args[k]?.isSome == true ? plan.args[k]?.text : nil }
        switch plan.intent {
        case "play_music":
            if let s = v("song") { out.append(Chip(symbol: "music.note", text: s)) }
            if let a = v("artist") { out.append(Chip(symbol: "person.fill", text: a)) }
            if let m = v("mood") { out.append(Chip(symbol: "sparkles", text: m)) }
        case "open_site":
            if let s = v("site") { out.append(Chip(symbol: "globe", text: URL(string: s)?.host() ?? s)) }
        case "web_search":
            out += (plan.args["queries"]?.list ?? []).map { Chip(symbol: "magnifyingglass", text: $0) }
        case "open_app":
            if let a = v("app") { out.append(Chip(symbol: "app.fill", text: a)) }
        case "app_task":
            out.append(Chip(symbol: "cursorarrow.click.2", text: v("app") ?? "app"))
        default:
            break
        }
        chips = out
    }
}
