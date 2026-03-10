import SwiftUI

struct CacheFidelitySlider: View {
    @Binding var selectedLevel: CacheLevel

    var body: some View {
        HStack(spacing: 8) {
            cacheLevelCard(
                .standard,
                icon: "doc.richtext",
                title: "Reading",
                subtitle: "Text & images"
            )
            cacheLevelCard(
                .full,
                icon: "doc.on.doc",
                title: "Full page",
                subtitle: "Uses more storage"
            )
        }
    }

    private func cacheLevelCard(_ level: CacheLevel, icon: String, title: String, subtitle: String) -> some View {
        let isSelected = selectedLevel == level
        return Button {
            if selectedLevel != level {
                HapticManager.sliderStep()
                selectedLevel = level
            }
        } label: {
            VStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 18))
                    .foregroundColor(isSelected ? .white : Theme.textPrimary)
                VStack(spacing: 2) {
                    Text(title)
                        .font(Theme.scaledFont(size: 14, weight: .semibold, relativeTo: .subheadline))
                        .foregroundColor(isSelected ? .white : Theme.textPrimary)
                    Text(subtitle)
                        .font(Theme.scaledFont(size: 11, relativeTo: .caption))
                        .foregroundColor(isSelected ? .white.opacity(0.7) : Theme.textSecondary)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(isSelected ? AnyShapeStyle(Theme.accentGradient) : AnyShapeStyle(Theme.surfaceRaised))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(isSelected ? Color.clear : Theme.border, lineWidth: 1)
            )
        }
        .accessibilityLabel(title)
        .accessibilityValue(isSelected ? "Selected" : "")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
