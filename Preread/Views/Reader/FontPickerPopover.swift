import SwiftUI

struct FontPickerPopover: View {
    @Binding var selectedFont: String
    let onChanged: (String) -> Void

    private let fonts: [(name: String, displayName: String, preview: Font)] = [
        ("-apple-system", "System", .system(size: 15, design: .default)),
        ("Georgia", "Georgia", .custom("Georgia", size: 15)),
        ("New York", "New York", .system(size: 15, design: .serif)),
        ("Palatino", "Palatino", .custom("Palatino", size: 15))
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Reading font")
                .font(Theme.scaledFont(size: 13, weight: .semibold, relativeTo: .footnote))
                .foregroundColor(Theme.textSecondary)

            VStack(spacing: 0) {
                ForEach(Array(fonts.enumerated()), id: \.offset) { index, font in
                    if index > 0 {
                        Divider()
                            .background(Theme.border)
                    }

                    Button {
                        if selectedFont != font.name {
                            HapticManager.fontSelected()
                            selectedFont = font.name
                            onChanged(font.name)
                        }
                    } label: {
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(font.displayName)
                                    .font(Theme.scaledFont(size: 14, weight: .medium, relativeTo: .subheadline))
                                    .foregroundColor(Theme.textPrimary)

                                Text("Reading should feel good.")
                                    .font(font.preview)
                                    .foregroundColor(Theme.textSecondary)
                            }

                            Spacer()

                            if selectedFont == font.name {
                                Circle()
                                    .fill(Theme.accent)
                                    .frame(width: 8, height: 8)
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .background(Theme.border)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .padding(16)
        .frame(width: 240)
        .background(Theme.surfaceRaised)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}
