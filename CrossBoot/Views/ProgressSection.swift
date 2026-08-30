import SwiftUI

/// Progress bar plus the status line beneath it
struct ProgressSection: View {
    let state: ProcessState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ProgressBar(value: state.progress, total: 100)
                .padding(.vertical, 4)

            HStack {
                Text("Status: \(state.stage.description)")
                    .foregroundColor(.secondary)
                    .lineLimit(1)

                Spacer()

                Text("\(Int(state.progress))%")
                    .foregroundColor(.secondary)
            }
        }
    }
}

/// Thin capsule progress indicator
private struct ProgressBar: View {
    var value: Double
    var total: Double
    var height: CGFloat = 5

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.secondary.opacity(0.15))
                    .frame(height: height)

                if value > 0 {
                    Capsule()
                        .fill(Color.accentColor)
                        .frame(width: fillWidth(in: geometry.size.width), height: height)
                        .animation(.linear(duration: 0.2), value: value)
                }
            }
        }
        .frame(height: height)
    }

    private func fillWidth(in available: CGFloat) -> CGFloat {
        let fraction = total > 0 ? value / total : 0
        return min(max(0, available * CGFloat(fraction)), available)
    }
}

#Preview {
    VStack(spacing: 24) {
        ProgressSection(state: ProcessState())
        ProgressSection(state: ProcessState(stage: .copying, progress: 42, currentFile: "install.wim"))
        ProgressSection(state: ProcessState(stage: .done, progress: 100))
    }
    .padding()
    .frame(width: 400)
}
