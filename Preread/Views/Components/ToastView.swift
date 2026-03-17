import SwiftUI

struct ToastView: View {
    let item: ToastItem
    let onDismiss: () -> Void

    private var iconName: String {
        switch item.type {
        case .info: "info.circle.fill"
        case .success: "checkmark.circle.fill"
        case .error: "exclamationmark.triangle.fill"
        }
    }

    private var iconColor: Color {
        switch item.type {
        case .info: .white
        case .success: .white
        case .error: Theme.danger
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: iconName)
                .font(Theme.scaledFont(size: 13, weight: .semibold))
                .foregroundStyle(iconColor)
            Text(item.message)
                .font(Theme.scaledFont(size: 14, weight: .medium))
                .lineLimit(2)
                .multilineTextAlignment(.leading)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background {
            Capsule()
                .fill(.ultraThinMaterial)
                .environment(\.colorScheme, .dark)
        }
        .shadow(color: .black.opacity(0.15), radius: 8, y: 4)
        .padding(.top, 4)
        .gesture(
            DragGesture()
                .onEnded { value in
                    if value.translation.height < -20 {
                        onDismiss()
                    }
                }
        )
    }
}

// MARK: - Snack pill (bottom)

struct SnackPillView: View {
    let item: SnackItem

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: item.icon)
                .font(Theme.scaledFont(size: 13, weight: .semibold))
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
    @MainActor func toastOverlay(manager: ToastManager? = nil) -> some View {
        modifier(ToastOverlayModifier(manager: manager ?? .shared))
    }
}
