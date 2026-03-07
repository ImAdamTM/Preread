import SwiftUI

struct CacheFidelitySlider: View {
    @Binding var selectedLevel: CacheLevel

    private let levels: [(level: CacheLevel, icon: String, label: String)] = [
        (.standard, "doc.richtext", "Standard"),
        (.full, "doc.on.doc", "Full")
    ]

    private var selectedIndex: Int {
        levels.firstIndex(where: { $0.level == selectedLevel }) ?? 0
    }

    var body: some View {
        VStack(spacing: 16) {
            // Track with stops
            GeometryReader { geo in
                let stopSpacing = geo.size.width / CGFloat(levels.count - 1)

                ZStack(alignment: .leading) {
                    // Background track
                    Capsule()
                        .fill(Theme.surfaceRaised)
                        .frame(height: 6)

                    // Active fill
                    let fillWidth = stopSpacing * CGFloat(selectedIndex)
                    Capsule()
                        .fill(Theme.accentGradient)
                        .frame(width: max(fillWidth, 6), height: 6)

                    // Stop buttons
                    ForEach(Array(levels.enumerated()), id: \.offset) { index, item in
                        let isActive = index <= selectedIndex
                        let xPos = stopSpacing * CGFloat(index)

                        Button {
                            if selectedLevel != item.level {
                                HapticManager.sliderStep()
                                withAnimation(Theme.gentleAnimation()) {
                                    selectedLevel = item.level
                                }
                            }
                        } label: {
                            VStack(spacing: 6) {
                                // Stop dot
                                Circle()
                                    .fill(isActive ? Theme.accent : Theme.surfaceRaised)
                                    .frame(width: 16, height: 16)
                                    .overlay(
                                        Circle()
                                            .fill(isActive ? Color.white : Color.clear)
                                            .frame(width: 6, height: 6)
                                    )
                                    .shadow(color: isActive ? Theme.accent.opacity(0.3) : .clear, radius: 4, y: 2)

                                // Icon
                                Image(systemName: item.icon)
                                    .font(.system(size: 18))
                                    .foregroundColor(isActive ? Theme.textPrimary : Theme.textSecondary)

                                // Label
                                Text(item.label)
                                    .font(Theme.scaledFont(size: 12, weight: .medium, relativeTo: .caption))
                                    .foregroundColor(isActive ? Theme.textPrimary : Theme.textSecondary)
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(item.label), level \(index + 1) of \(levels.count)")
                        .accessibilityValue(index == selectedIndex ? "Selected" : "")
                        .accessibilityAddTraits(index == selectedIndex ? .isSelected : [])
                        .frame(width: 60)
                        .position(x: xPos, y: geo.size.height / 2)
                    }
                }
            }
            .frame(height: 80)

            // Sub-label
            Text(sublabel)
                .font(Theme.scaledFont(size: 13, relativeTo: .footnote).italic())
                .foregroundColor(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .animation(.easeInOut(duration: 0.2), value: selectedLevel)
        }
    }

    private var sublabel: String {
        switch selectedLevel {
        case .standard:
            return "Saves text and all images. Recommended for most sources."
        case .full:
            return "Saves the complete page including fonts and stylesheets. Largest footprint."
        }
    }
}
