import SwiftUI

struct FloatingControlStrip: View {
    @Binding var isDarkMode: Bool
    @Binding var textSize: CGFloat
    @Binding var fontFamily: String
    let articleURL: URL?
    let articleTitle: String
    let isVisible: Bool
    let isDarkReaderProcessing: Bool
    let onDarkModeToggle: () -> Void
    let onTextSizeChanged: (CGFloat) -> Void
    let onFontChanged: (String) -> Void

    @State private var showTextSize = false
    @State private var showFontPicker = false
    @State private var moonRotation: Double = 0

    var body: some View {
        HStack(spacing: 0) {
            // Web | Read toggle
            modeToggle

            divider

            // Moon (dark mode)
            Button {
                onDarkModeToggle()
            } label: {
                Image(systemName: "moon.fill")
                    .font(.system(size: 16))
                    .foregroundColor(isDarkMode ? Theme.teal : Theme.textPrimary)
                    .rotationEffect(.degrees(moonRotation))
                    .frame(width: 44, height: 52)
            }
            .accessibilityLabel("Dark mode")
            .accessibilityValue(isDarkMode ? "On" : "Off")
            .disabled(isDarkReaderProcessing)
            .onChange(of: isDarkReaderProcessing) { _, processing in
                if processing && !Theme.reduceMotion {
                    withAnimation(.linear(duration: 0.8).repeatForever(autoreverses: false)) {
                        moonRotation = 360
                    }
                } else {
                    withAnimation(.easeOut(duration: 0.2)) {
                        moonRotation = 0
                    }
                }
            }

            divider

            // Aa (text size tap / font long-press)
            controlButton(icon: "textformat.size", isActive: showTextSize || showFontPicker) {
                showTextSize.toggle()
            }
            .accessibilityLabel("Text size")
            .onLongPressGesture {
                HapticManager.fontSelected()
                showFontPicker = true
            }
            .popover(isPresented: $showTextSize) {
                TextSizePopover(textSize: $textSize, onChanged: onTextSizeChanged)
                    .presentationCompactAdaptation(.popover)
            }
            .popover(isPresented: $showFontPicker) {
                FontPickerPopover(selectedFont: $fontFamily, onChanged: onFontChanged)
                    .presentationCompactAdaptation(.popover)
            }

            divider

            // Share
            ShareLink(item: articleURL ?? URL(string: "https://preread.app")!,
                      subject: Text(articleTitle)) {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 16))
                    .foregroundColor(Theme.textPrimary)
                    .frame(width: 44, height: 52)
            }
            .accessibilityLabel("Share")
        }
        .frame(width: 280, height: 52)
        .background(.ultraThinMaterial.opacity(0.85))
        .background(Color.black.opacity(0.3))
        .clipShape(Capsule())
        .overlay(
            Capsule()
                .stroke(Theme.borderProminent, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.3), radius: 16, y: 4)
        .offset(y: isVisible ? 0 : 20)
        .opacity(isVisible ? 1 : 0)
        .animation(Theme.gentleAnimation(), value: isVisible)
    }

    // MARK: - Mode toggle

    private var modeToggle: some View {
        HStack(spacing: 0) {
            modeButton("Web", isActive: !isDarkMode)
            modeButton("Read", isActive: isDarkMode)
        }
        .frame(width: 88)
    }

    private func modeButton(_ label: String, isActive: Bool) -> some View {
        Button {
            HapticManager.modeToggle()
            isDarkMode = (label == "Read")
        } label: {
            VStack(spacing: 4) {
                Text(label)
                    .font(Theme.scaledFont(size: 12, weight: .medium, relativeTo: .caption))
                    .foregroundColor(isActive ? Theme.teal : Theme.textSecondary)

                Rectangle()
                    .fill(isActive ? Theme.teal : Color.clear)
                    .frame(height: 2)
                    .frame(width: 24)
            }
            .frame(width: 44, height: 52)
        }
        .accessibilityLabel("\(label) mode")
        .accessibilityValue(isActive ? "Active" : "")
    }

    // MARK: - Helpers

    private var divider: some View {
        Rectangle()
            .fill(Theme.borderProminent)
            .frame(width: 1, height: 24)
    }

    private func controlButton(icon: String, isActive: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 16))
                .foregroundColor(isActive ? Theme.teal : Theme.textPrimary)
                .frame(width: 44, height: 52)
        }
    }
}
