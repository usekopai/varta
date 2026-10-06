import Foundation
import VartaCore

func speechPreparationTests() {
    // Download completion still has a loading/compilation phase: never report it as ready.
    let states: [SpeechPreparation] = [.preparing, .downloading(nil), .downloading(0), .downloading(0.67), .downloading(1), .loading, .ready]
    expect(states.map(\.isBusy) == [true, true, true, true, true, true, false], "speech stays busy through download and compilation")
    expect(states[3].fraction == 0.67 && states[3].status.contains("67%"), "speech progress preserves the download fraction")
    expect(states[5].fraction == nil && states[5] != .ready, "loading does not display a stale completed download bar")
    for value in [Double.nan, .infinity, -.infinity] {
        let state = SpeechPreparation.downloading(value)
        expect(state.fraction == nil && !state.status.contains("%"), "invalid provider progress remains indeterminate")
    }
    expect(SpeechPreparation.downloading(-0.5).fraction == 0, "negative download progress clamps to zero")
    expect(SpeechPreparation.downloading(1.5).fraction == 1, "excess download progress clamps to one")
    let failed = SpeechPreparation.failed("Network unavailable")
    expect(!failed.isBusy && failed.fraction == nil && failed.status.contains("Network unavailable"), "speech failure stops progress and retains the failure reason")
}
