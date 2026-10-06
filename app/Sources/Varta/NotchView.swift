import SwiftUI

/// Black shape that grows down out of the notch. Collapsed it is exactly the notch, so it is invisible.
struct NotchView: View {
    @ObservedObject var model: NotchModel
    let notch: CGSize
    let expanded: CGSize

    var body: some View {
        let size = model.isExpanded ? expanded : notch
        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                UnevenRoundedRectangle(bottomLeadingRadius: model.isExpanded ? 22 : 10,
                                       bottomTrailingRadius: model.isExpanded ? 22 : 10)
                    .fill(Color.black)
                if model.isExpanded {
                    content
                        .padding(.top, notch.height + 6)
                        .padding(.horizontal, 18)
                        .padding(.bottom, 12)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .frame(width: size.width, height: size.height)
            Spacer(minLength: 0)
        }
        .frame(width: expanded.width, height: expanded.height, alignment: .top)
        .animation(.spring(response: 0.32, dampingFraction: 0.82), value: model.isExpanded)
        .animation(.easeOut(duration: 0.18), value: model.phase)
        .preferredColorScheme(.dark)
    }

    @ViewBuilder private var content: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                indicator
                Text(headline)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if !model.chips.isEmpty && model.phase != .listening {
                HStack(spacing: 6) {
                    ForEach(model.chips.prefix(3)) { chip in
                        Label(chip.text, systemImage: chip.symbol)
                            .font(.system(size: 11, weight: .medium))
                            .lineLimit(1)
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(Capsule().fill(Color.white.opacity(0.12)))
                            .foregroundStyle(.white.opacity(0.9))
                    }
                }
            }
            if model.phase == .acting || model.phase == .thinking {
                HStack {
                    Text(model.status).lineLimit(1)
                    Spacer()
                    Text(model.phase == .acting && model.steps > 0 ? "\(model.steps) steps · esc to stop" : "esc to stop")
                }
                .font(.system(size: 10.5))
                .foregroundStyle(.white.opacity(0.5))
            }
        }
    }

    private var headline: String {
        switch model.phase {
        case .listening: return model.transcript.isEmpty ? "Listening…" : model.transcript
        case .thinking, .acting: return model.transcript
        case .done, .message, .preparingSpeech: return model.status
        case .idle: return ""
        }
    }

    @ViewBuilder private var indicator: some View {
        switch model.phase {
        case .listening: Waveform(level: model.level)
        case .thinking, .acting, .preparingSpeech: ProgressView().controlSize(.small).tint(.white)
        case .done(let ok):
            Image(systemName: ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(ok ? Color.green : Color.red).font(.system(size: 16))
        case .message:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow).font(.system(size: 15))
        case .idle: EmptyView()
        }
    }
}

struct Waveform: View {
    var level: Float
    @State private var phase = 0.0

    var body: some View {
        TimelineView(.animation) { t in
            let time = t.date.timeIntervalSinceReferenceDate
            HStack(spacing: 2.5) {
                ForEach(0..<5, id: \.self) { i in
                    let wobble = (sin(time * 9 + Double(i) * 1.3) + 1) / 2
                    Capsule()
                        .fill(Color.red)
                        .frame(width: 3, height: 4 + CGFloat(level) * 14 * CGFloat(0.4 + 0.6 * wobble))
                }
            }
            .frame(width: 24, height: 20)
        }
    }
}
