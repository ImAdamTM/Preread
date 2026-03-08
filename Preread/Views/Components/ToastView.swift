import SwiftUI

struct ToastView: View {
    let item: ToastItem
    let onDismiss: () -> Void

    @State private var offset: CGFloat = -120
    @State private var dragOffset: CGFloat = 0

    private var accentColor: Color {
        switch item.type {
        case .info: Theme.teal
        case .success: Theme.success
        case .error: Theme.danger
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(accentColor)
                .frame(width: 3)

            Text(item.message)
                .font(.system(size: 14))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(2)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 14)
        .background {
            RoundedRectangle(cornerRadius: 16)
                .fill(Theme.card)
                .overlay {
                    RoundedRectangle(cornerRadius: 16)
                        .fill(.ultraThinMaterial)
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 16)
                        .strokeBorder(Theme.border, lineWidth: 1)
                }
        }
        .padding(.horizontal, 16)
        .offset(y: offset + dragOffset)
        .gesture(
            DragGesture()
                .onChanged { value in
                    if value.translation.height < 0 {
                        dragOffset = value.translation.height
                    }
                }
                .onEnded { value in
                    if value.translation.height < -30 {
                        dismiss()
                    } else {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                            dragOffset = 0
                        }
                    }
                }
        )
        .onAppear {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                offset = 0
            }
        }
    }

    private func dismiss() {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.9)) {
            offset = -120
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            onDismiss()
        }
    }
}

// MARK: - Snack pill (bottom)

struct SnackPillView: View {
    let item: SnackItem

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: item.icon)
                .font(.system(size: 13, weight: .semibold))
            Text(item.message)
                .font(Theme.scaledFont(size: 14, weight: .medium))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background {
            Capsule()
                .fill(.ultraThinMaterial)
                .environment(\.colorScheme, .dark)
        }
        .shadow(color: .black.opacity(0.15), radius: 8, y: 4)
    }
}

/// Modifier that overlays toasts at the top and snack pills at the bottom.
struct ToastOverlayModifier: ViewModifier {
    @ObservedObject var manager: ToastManager

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .top) {
                if let toast = manager.currentToast {
                    ToastView(item: toast) {
                        manager.dismiss()
                    }
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .overlay(alignment: .bottom) {
                if let snack = manager.currentSnack {
                    SnackPillView(item: snack)
                        .padding(.bottom, 40)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.spring(response: 0.4, dampingFraction: 0.85), value: manager.currentToast?.id)
            .animation(.spring(response: 0.35, dampingFraction: 0.8), value: manager.currentSnack?.id)
    }
}

extension View {
    func toastOverlay(manager: ToastManager = .shared) -> some View {
        modifier(ToastOverlayModifier(manager: manager))
    }
}
