import SwiftUI

struct TextSizePopover: View {
    @Binding var textSize: CGFloat
    let onChanged: (CGFloat) -> Void

    private let stops: [CGFloat] = [14, 16, 18, 20, 22, 24]
    private let minSize: CGFloat = 14
    private let maxSize: CGFloat = 24

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text("Text size")
                    .font(Theme.scaledFont(size: 13, weight: .semibold, relativeTo: .footnote))
                    .foregroundColor(Theme.textSecondary)
                Spacer()
                Text("\(Int(textSize))pt")
                    .font(Theme.scaledFont(size: 13, weight: .medium).monospacedDigit())
                    .foregroundColor(Theme.textPrimary)
            }

            HStack(spacing: 8) {
                Text("A")
                    .font(Theme.scaledFont(size: 12, weight: .medium))
                    .foregroundColor(Theme.textSecondary)

                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        // Track
                        Capsule()
                            .fill(Theme.borderProminent)
                            .frame(height: 4)

                        // Filled track
                        let fraction = (textSize - minSize) / (maxSize - minSize)
                        Capsule()
                            .fill(Theme.accentGradient)
                            .frame(width: geo.size.width * fraction, height: 4)

                        // Stop marks
                        ForEach(stops, id: \.self) { stop in
                            let stopFraction = (stop - minSize) / (maxSize - minSize)
                            Circle()
                                .fill(textSize >= stop ? Theme.accent : Theme.borderProminent)
                                .frame(width: 6, height: 6)
                                .position(x: geo.size.width * stopFraction, y: geo.size.height / 2)
                        }

                        // Thumb
                        Circle()
                            .fill(Theme.accent)
                            .frame(width: 20, height: 20)
                            .shadow(color: Theme.accent.opacity(0.3), radius: 4, y: 2)
                            .position(x: geo.size.width * fraction, y: geo.size.height / 2)
                            .gesture(
                                DragGesture(minimumDistance: 0)
                                    .onChanged { value in
                                        let raw = minSize + (value.location.x / geo.size.width) * (maxSize - minSize)
                                        let clamped = min(max(raw, minSize), maxSize)
                                        let snapped = snapToClosestStop(clamped)
                                        if snapped != textSize {
                                            HapticManager.sliderStep()
                                        }
                                        textSize = snapped
                                        onChanged(snapped)
                                    }
                            )
                    }
                }
                .frame(height: 20)

                Text("A")
                    .font(Theme.scaledFont(size: 18, weight: .medium))
                    .foregroundColor(Theme.textSecondary)
            }
        }
        .padding(16)
        .frame(width: 240)
        .background(Theme.surfaceRaised)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func snapToClosestStop(_ value: CGFloat) -> CGFloat {
        stops.min(by: { abs($0 - value) < abs($1 - value) }) ?? value
    }
}
