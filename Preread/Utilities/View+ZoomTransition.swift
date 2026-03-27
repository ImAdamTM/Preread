import SwiftUI

extension View {
    /// Availability-guarded wrapper for `matchedTransitionSource` (iOS 18+).
    /// On iOS 17, this is a no-op.
    func zoomTransitionSource(id: some Hashable, in namespace: Namespace.ID, cornerRadius: CGFloat) -> some View {
        modifier(ZoomTransitionSourceModifier(id: AnyHashable(id), namespace: namespace, cornerRadius: cornerRadius))
    }

    /// Availability-guarded wrapper for `navigationTransition(.zoom(...))` (iOS 18+).
    /// On iOS 17, this is a no-op.
    func zoomNavigationTransition(sourceID: some Hashable, in namespace: Namespace.ID) -> some View {
        modifier(ZoomNavigationTransitionModifier(sourceID: AnyHashable(sourceID), namespace: namespace))
    }

    /// Applies Liquid Glass on iOS 26+, falls back to ultra-thin material on older versions.
    func glassCloseButton() -> some View {
        modifier(GlassCloseButtonModifier())
    }
}

private struct ZoomTransitionSourceModifier: ViewModifier {
    let id: AnyHashable
    let namespace: Namespace.ID
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content
                .matchedTransitionSource(id: id, in: namespace) {
                    $0.clipShape(RoundedRectangle(cornerRadius: cornerRadius))
                        .background(Theme.background)
                }
        } else {
            content
        }
    }
}

private struct GlassCloseButtonModifier: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content
                .glassEffect(.regular.interactive(), in: .circle)
        } else {
            content
                .foregroundStyle(Theme.textPrimary)
                .background(.ultraThinMaterial, in: Circle())
        }
    }
}

private struct ZoomNavigationTransitionModifier: ViewModifier {
    let sourceID: AnyHashable
    let namespace: Namespace.ID

    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content
                .navigationTransition(.zoom(sourceID: sourceID, in: namespace))
        } else {
            content
        }
    }
}
