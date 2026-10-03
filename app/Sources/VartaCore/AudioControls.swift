import Foundation

/// Fixed operations and validated values only; command text never becomes script source.
extension Executor {
    func controlAudio(_ plan: Plan, _ res: inout ExecResult, cancel: CancelFlag?) {
        guard let operation = plan.arg("operation"), ["set", "increase", "decrease", "mute", "unmute"].contains(operation) else {
            res.ok = false; res.note = "Specify a volume change, mute, or unmute"; return
        }
        var amount = 0
        if ["set", "increase", "decrease"].contains(operation) {
            guard let n = plan.args["amount"]?.number, n.isFinite, n.rounded() == n, (0...100).contains(n) else {
                res.ok = false; res.note = "Specify a whole percentage from 0 to 100"; return
            }
            amount = Int(n)
        }
        let script = """
        on run argv
            set operation to item 1 of argv
            set amount to (item 2 of argv) as integer
            set originalSettings to get volume settings
            if operation is "mute" then
                set volume with output muted
            else if operation is "unmute" then
                set volume without output muted
            else
                set target to amount
                if operation is "increase" then set target to (output volume of originalSettings) + amount
                if operation is "decrease" then set target to (output volume of originalSettings) - amount
                if target > 100 then set target to 100
                if target < 0 then set target to 0
                set volume output volume target
            end if
            set currentSettings to get volume settings
            if operation is "mute" then
                if not (output muted of currentSettings) then error "Could not mute this audio device"
                return "Audio muted"
            else if operation is "unmute" then
                if output muted of currentSettings then error "Could not unmute this audio device"
                return "Audio unmuted"
            end if
            if (output volume of currentSettings) is not target then error "This audio device did not accept the volume change"
            set message to "Volume set to " & target & "%"
            if output muted of currentSettings then set message to message & " (audio is muted)"
            return message
        end run
        """
        if let result = osascript(&res, script, operation, String(amount), cancel: cancel) { res.note = result }
    }

    func controlPlayback(_ plan: Plan, _ res: inout ExecResult, cancel: CancelFlag?) {
        let commands = ["pause": "pause", "resume": "play", "next": "next track", "previous": "previous track"]
        guard let operation = plan.arg("operation"), let command = commands[operation],
              let requested = plan.arg("player"), ["automatic", "Spotify", "Music"].contains(requested) else {
            res.ok = false; res.note = "Specify a playback control for Spotify or Apple Music"; return
        }
        let candidates = requested == "automatic" ? ["Spotify", "Music"].filter { apps.contains($0) } : [requested]
        var states: [String: String] = [:]
        for player in candidates {
            guard apps.contains(player) else {
                res.ok = false; res.note = "\(player == "Music" ? "Apple Music" : player) is not installed"; return
            }
            // `player` comes exclusively from the fixed names above.
            let script = """
            if application "\(player)" is not running then return "not_running"
            tell application "\(player)" to return player state as text
            """
            guard let state = osascript(&res, script, cancel: cancel) else { return }
            guard ["playing", "paused", "stopped", "not_running"].contains(state) else {
                res.ok = false; res.note = "Could not determine playback state"; return
            }
            if state != "not_running" { states[player] = state }
        }
        let playing = candidates.filter { states[$0] == "playing" }
        let running = candidates.filter { states[$0] != nil }
        let selected: String?
        if requested != "automatic" { selected = running.first }
        else if playing.count == 1 { selected = playing.first }
        else if playing.isEmpty && running.count == 1 { selected = running.first }
        else { selected = nil }
        guard let player = selected else {
            res.ok = false
            res.note = running.isEmpty ? "Open Spotify or Apple Music and choose something to play first" : "Say Spotify or Apple Music to choose a player"
            return
        }
        let label = player == "Music" ? "Apple Music" : player
        let expected = operation == "pause" ? "paused" : "playing"
        let verify = ["pause", "resume"].contains(operation) ? """
            repeat 5 times
                if (player state as text) is "\(expected)" then return "verified"
                delay 0.1
            end repeat
            error "The player did not reach the requested playback state"
        """ : "return \"dispatched\""
        let script = """
        if application "\(player)" is not running then error "The player has closed"
        tell application "\(player)"
            \(command)
            \(verify)
        end tell
        """
        guard let result = osascript(&res, script, cancel: cancel) else { return }
        if ["pause", "resume"].contains(operation) {
            guard result == "verified" else { res.ok = false; res.note = "Could not verify playback"; return }
            res.note = operation == "pause" ? "Paused \(label)" : "Resumed \(label)"
        } else {
            guard result == "dispatched" else { res.ok = false; res.note = "Could not dispatch playback control"; return }
            res.note = "Requested \(operation == "next" ? "next" : "previous") track in \(label)"
        }
    }
}
