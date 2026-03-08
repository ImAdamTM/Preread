import SwiftUI

enum ToastType {
    case info
    case success
    case error
}

struct ToastItem: Identifiable {
    let id = UUID()
    let message: String
    let type: ToastType
    let duration: TimeInterval

    init(message: String, type: ToastType = .info, duration: TimeInterval = 4.0) {
        self.message = message
        self.type = type
        self.duration = duration
    }
}

struct SnackItem: Identifiable, Equatable {
    let id = UUID()
    let message: String
    let icon: String

    static func == (lhs: SnackItem, rhs: SnackItem) -> Bool {
        lhs.id == rhs.id
    }
}

@MainActor
final class ToastManager: ObservableObject {
    static let shared = ToastManager()

    @Published var currentToast: ToastItem?
    @Published var currentSnack: SnackItem?

    private var dismissTask: Task<Void, Never>?
    private var snackDismissTask: Task<Void, Never>?

    private init() {}

    func show(_ message: String, type: ToastType = .info, duration: TimeInterval = 4.0) {
        dismissTask?.cancel()
        currentToast = ToastItem(message: message, type: type, duration: duration)

        dismissTask = Task {
            try? await Task.sleep(for: .seconds(duration))
            guard !Task.isCancelled else { return }
            dismiss()
        }
    }

    func dismiss() {
        dismissTask?.cancel()
        currentToast = nil
    }

    func snack(_ message: String, icon: String, duration: TimeInterval = 1.5) {
        snackDismissTask?.cancel()
        currentSnack = SnackItem(message: message, icon: icon)

        snackDismissTask = Task {
            try? await Task.sleep(for: .seconds(duration))
            guard !Task.isCancelled else { return }
            dismissSnack()
        }
    }

    func dismissSnack() {
        snackDismissTask?.cancel()
        currentSnack = nil
    }

    // MARK: - Pre-defined toasts

    func showOffline() {
        show("Can't reach your sources right now. Your saved articles are still here.", type: .error, duration: 4)
    }

    func showDarkMode() {
        show("Dark mode on — Dark Reader is restyling this page.", type: .info, duration: 2)
    }

    func showShortcutAdded() {
        show("Added to Home Screen", type: .success, duration: 2)
    }

    func showLowStorage() {
        show("Your device is running low on storage. You can free up space in Settings.", type: .error, duration: 6)
    }
}
