import SwiftUI
import VartaCore

struct SpeechStatusView: View {
    let preparation: SpeechPreparation
    var retry: () -> Void
    private var ready: Bool { preparation == .ready }

    var body: some View {
        GroupBox("Speech") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    if preparation.isBusy {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: ready ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                            .foregroundStyle(ready ? Color.green : Color.orange)
                    }
                    Text(ready ? "Whisper is ready" : preparation.status)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if case .failed = preparation {
                        Button("Retry") { retry() }
                    }
                }
                if let fraction = preparation.fraction {
                    ProgressView(value: fraction, total: 1)
                        .accessibilityLabel("Whisper model download")
                        .accessibilityValue("\(Int((fraction * 100).rounded())) percent")
                }
                if preparation == .loading {
                    Text("Preparing local speech recognition. The first load can take a few minutes.")
                        .foregroundStyle(.secondary)
                } else if ready {
                    Text("Your voice is transcribed on this Mac.").foregroundStyle(.secondary)
                }
            }
            .padding(6)
        }
    }
}
