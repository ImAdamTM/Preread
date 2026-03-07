import UIKit

@MainActor
enum HapticManager {
    static func pullToRefresh() {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    static func cardLift() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    static func cardDrop() {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    static func articleCached() {
        UIImpactFeedbackGenerator(style: .soft).impactOccurred()
    }

    static func allRefreshComplete() {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    static func swipeThreshold() {
        UISelectionFeedbackGenerator().selectionChanged()
    }

    static func modeToggle() {
        UISelectionFeedbackGenerator().selectionChanged()
    }

    static func sliderStep() {
        UISelectionFeedbackGenerator().selectionChanged()
    }

    static func fontSelected() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    static func shortcutAdded() {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    static func deleteConfirm() {
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
    }

    static func fetchFailed() {
        UINotificationFeedbackGenerator().notificationOccurred(.error)
    }
}
