import SwiftUI
import UIKit

// MARK: - Zoomable scroll view (UIKit-backed)

/// `UIScrollView` subclass that sizes and centers its image view using
/// `contentInset`, guaranteeing correct geometry after Auto Layout and
/// during zoom without fighting the scroll view's content offset.
private final class CenteringScrollView: UIScrollView {
    /// Set by the representable; used to recalculate the fit size on layout.
    var displayImage: UIImage?
    private var lastBoundsSize: CGSize = .zero

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let imageView = subviews.first as? UIImageView,
              let image = displayImage else { return }

        let boundsSize = bounds.size
        guard boundsSize.width > 0, boundsSize.height > 0 else { return }

        // Set the image view frame once (at 1x) or when the container resizes.
        if lastBoundsSize != boundsSize {
            lastBoundsSize = boundsSize

            let imageSize = image.size
            let fitScale = min(boundsSize.width / imageSize.width,
                               boundsSize.height / imageSize.height)
            let fitSize = CGSize(width: imageSize.width * fitScale,
                                 height: imageSize.height * fitScale)

            imageView.frame = CGRect(origin: .zero, size: fitSize)
            contentSize = fitSize
        }

        updateCenteringInsets()
    }

    /// Uses `contentInset` to center the image when it's smaller than the
    /// viewport. When the zoomed content exceeds the viewport, insets are
    /// zero so normal scroll panning takes over.
    func updateCenteringInsets() {
        guard let imageView = subviews.first as? UIImageView else { return }

        let boundsSize = bounds.size
        let scaledWidth = imageView.frame.width * zoomScale
        let scaledHeight = imageView.frame.height * zoomScale

        let verticalInset = max((boundsSize.height - scaledHeight) / 2, 0)
        let horizontalInset = max((boundsSize.width - scaledWidth) / 2, 0)

        contentInset = UIEdgeInsets(top: verticalInset, left: horizontalInset,
                                    bottom: verticalInset, right: horizontalInset)
    }
}

/// Wraps a `UIScrollView` to provide native pinch-to-zoom, pan, bounce,
/// and content centering — matching iOS Photos behaviour.
private struct ZoomableImageView: UIViewRepresentable {
    let image: UIImage
    let onSingleTap: () -> Void
    let onZoomChanged: (Bool) -> Void
    /// Called during vertical drag at 1x zoom with the Y offset (for background fade).
    let onDragChanged: (CGFloat) -> Void
    /// Called when a vertical drag at 1x ends. Bool = true means dismiss threshold met.
    let onDragEnded: (Bool) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(image: image, onSingleTap: onSingleTap, onZoomChanged: onZoomChanged,
                    onDragChanged: onDragChanged, onDragEnded: onDragEnded)
    }

    func makeUIView(context: Context) -> CenteringScrollView {
        let scrollView = CenteringScrollView()
        scrollView.displayImage = image
        scrollView.delegate = context.coordinator
        scrollView.backgroundColor = .clear
        scrollView.showsVerticalScrollIndicator = false
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.bouncesZoom = true
        scrollView.minimumZoomScale = 1.0
        scrollView.maximumZoomScale = 5.0
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.isScrollEnabled = false  // Disabled at 1x; enabled when zoomed in

        let imageView = UIImageView(image: image)
        imageView.contentMode = .scaleAspectFit
        imageView.isUserInteractionEnabled = true
        scrollView.addSubview(imageView)
        context.coordinator.imageView = imageView

        // Context menu for long-press (save/copy/share)
        let interaction = UIContextMenuInteraction(delegate: context.coordinator)
        imageView.addInteraction(interaction)

        // Double-tap to toggle zoom
        let doubleTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        scrollView.addGestureRecognizer(doubleTap)

        // Single-tap to toggle chrome (waits for double-tap to fail)
        let singleTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleSingleTap))
        singleTap.numberOfTapsRequired = 1
        singleTap.require(toFail: doubleTap)
        scrollView.addGestureRecognizer(singleTap)

        // Pan gesture for drag-to-dismiss at 1x zoom
        let dismissPan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleDismissPan(_:)))
        dismissPan.delegate = context.coordinator
        scrollView.addGestureRecognizer(dismissPan)
        context.coordinator.dismissPanGesture = dismissPan
        context.coordinator.scrollView = scrollView

        return scrollView
    }

    func updateUIView(_ scrollView: CenteringScrollView, context: Context) {
        scrollView.displayImage = image
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, UIScrollViewDelegate, UIGestureRecognizerDelegate, UIContextMenuInteractionDelegate {
        var imageView: UIImageView?
        weak var scrollView: UIScrollView?
        weak var dismissPanGesture: UIPanGestureRecognizer?

        let image: UIImage
        let onSingleTap: () -> Void
        let onZoomChanged: (Bool) -> Void
        let onDragChanged: (CGFloat) -> Void
        let onDragEnded: (Bool) -> Void

        /// Tracks whether a dismiss pan is active (only at 1x zoom).
        private var isDismissPanning = false
        private var panStartY: CGFloat = 0
        private var wasZoomed = false

        init(image: UIImage,
             onSingleTap: @escaping () -> Void,
             onZoomChanged: @escaping (Bool) -> Void,
             onDragChanged: @escaping (CGFloat) -> Void,
             onDragEnded: @escaping (Bool) -> Void) {
            self.image = image
            self.onSingleTap = onSingleTap
            self.onZoomChanged = onZoomChanged
            self.onDragChanged = onDragChanged
            self.onDragEnded = onDragEnded
        }

        // MARK: UIScrollViewDelegate

        func viewForZooming(in scrollView: UIScrollView) -> UIView? {
            imageView
        }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            (scrollView as? CenteringScrollView)?.updateCenteringInsets()
            let isZoomed = scrollView.zoomScale > scrollView.minimumZoomScale + 0.01
            // Enable panning only when zoomed in
            scrollView.isScrollEnabled = isZoomed

            if isZoomed != wasZoomed {
                wasZoomed = isZoomed
                onZoomChanged(isZoomed)
            }
        }

        // MARK: Tap gestures

        @objc func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
            guard let scrollView else { return }

            if scrollView.zoomScale > scrollView.minimumZoomScale {
                scrollView.setZoomScale(scrollView.minimumZoomScale, animated: true)
            } else {
                // Zoom into the tapped point
                let location = gesture.location(in: imageView)
                let zoomScale: CGFloat = 2.5
                let width = scrollView.bounds.width / zoomScale
                let height = scrollView.bounds.height / zoomScale
                let rect = CGRect(
                    x: location.x - width / 2,
                    y: location.y - height / 2,
                    width: width,
                    height: height
                )
                scrollView.zoom(to: rect, animated: true)
            }
        }

        @objc func handleSingleTap() {
            onSingleTap()
        }

        // MARK: Dismiss pan gesture

        @objc func handleDismissPan(_ gesture: UIPanGestureRecognizer) {
            guard let scrollView, scrollView.zoomScale <= scrollView.minimumZoomScale + 0.01 else { return }
            guard let imageView else { return }

            switch gesture.state {
            case .began:
                isDismissPanning = true
                panStartY = imageView.center.y

            case .changed:
                let translation = gesture.translation(in: scrollView)
                imageView.center = CGPoint(x: imageView.center.x, y: panStartY + translation.y)
                let progress = min(abs(translation.y) / 300, 1.0)
                onDragChanged(progress)

            case .ended, .cancelled:
                isDismissPanning = false
                let translation = gesture.translation(in: scrollView)
                let velocity = gesture.velocity(in: scrollView)
                let shouldDismiss = abs(translation.y) > 100 || abs(velocity.y) > 800
                onDragEnded(shouldDismiss)

                if !shouldDismiss {
                    UIView.animate(withDuration: 0.25, delay: 0, options: .curveEaseOut) {
                        imageView.center = CGPoint(x: imageView.center.x, y: self.panStartY)
                    }
                }

            default:
                break
            }
        }

        // MARK: UIGestureRecognizerDelegate

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard gestureRecognizer === dismissPanGesture,
                  let pan = gestureRecognizer as? UIPanGestureRecognizer,
                  let scrollView else { return true }

            // Only allow dismiss pan at 1x zoom and when drag is primarily vertical
            guard scrollView.zoomScale <= scrollView.minimumZoomScale + 0.01 else { return false }
            let velocity = pan.velocity(in: scrollView)
            return abs(velocity.y) > abs(velocity.x)
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            // Don't allow simultaneous recognition — the dismiss pan is
            // exclusive at 1x zoom to prevent the scroll view's built-in
            // pan from propagating up and dismissing the article sheet.
            false
        }

        // MARK: UIContextMenuInteractionDelegate

        func contextMenuInteraction(_ interaction: UIContextMenuInteraction,
                                    configurationForMenuAtLocation location: CGPoint) -> UIContextMenuConfiguration? {
            UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
                guard let self else { return UIMenu(title: "", children: []) }

                let save = UIAction(title: "Save to Photos",
                                    image: UIImage(systemName: "square.and.arrow.down")) { _ in
                    UIImageWriteToSavedPhotosAlbum(self.image, nil, nil, nil)
                }

                let copy = UIAction(title: "Copy",
                                    image: UIImage(systemName: "doc.on.doc")) { _ in
                    UIPasteboard.general.image = self.image
                }

                let share = UIAction(title: "Share",
                                     image: UIImage(systemName: "square.and.arrow.up")) { [weak self] _ in
                    guard let self, let imageView = self.imageView else { return }
                    let activityVC = UIActivityViewController(activityItems: [self.image], applicationActivities: nil)
                    activityVC.popoverPresentationController?.sourceView = imageView
                    activityVC.popoverPresentationController?.sourceRect = CGRect(
                        x: imageView.bounds.midX, y: imageView.bounds.midY, width: 0, height: 0
                    )

                    // Walk up to the topmost presented view controller
                    guard let windowScene = imageView.window?.windowScene,
                          let rootVC = windowScene.windows.first?.rootViewController else { return }
                    var presenter = rootVC
                    while let presented = presenter.presentedViewController {
                        presenter = presented
                    }
                    presenter.present(activityVC, animated: true)
                }

                return UIMenu(title: "", children: [save, copy, share])
            }
        }
    }
}

// MARK: - Image lightbox view

struct ImageLightboxView: View {
    let imageURL: URL
    let onDismiss: () -> Void
    @Binding var chromeVisible: Bool

    @State private var image: UIImage?
    @State private var backgroundOpacity: Double = 0
    @State private var imageOpacity: Double = 0
    @State private var dismissScale: CGFloat = 0.85

    var body: some View {
        ZStack {
            Color.black
                .opacity(backgroundOpacity)
                .ignoresSafeArea()

            if let image {
                ZoomableImageView(
                    image: image,
                    onSingleTap: {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            chromeVisible.toggle()
                        }
                    },
                    onZoomChanged: { zoomed in
                        if zoomed && chromeVisible {
                            withAnimation(.easeOut(duration: 0.2)) {
                                chromeVisible = false
                            }
                        }
                    },
                    onDragChanged: { progress in
                        backgroundOpacity = 1.0 - (progress * 0.5)
                        if chromeVisible {
                            withAnimation(.easeOut(duration: 0.15)) {
                                chromeVisible = false
                            }
                        }
                    },
                    onDragEnded: { shouldDismiss in
                        if shouldDismiss {
                            dismiss()
                        } else {
                            withAnimation(.easeOut(duration: 0.2)) {
                                backgroundOpacity = 1.0
                                chromeVisible = true
                            }
                        }
                    }
                )
                .opacity(imageOpacity)
                .scaleEffect(dismissScale)
            } else {
                ProgressView()
                    .tint(.white)
            }
        }
        .statusBarHidden()
        .contentShape(Rectangle())
        .task { loadImage() }
    }

    // MARK: - Helpers

    private func dismiss() {
        withAnimation(.easeOut(duration: 0.25)) {
            backgroundOpacity = 0
            imageOpacity = 0
            dismissScale = 0.85
            chromeVisible = false
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            onDismiss()
        }
    }

    private func loadImage() {
        guard imageURL.isFileURL,
              let data = try? Data(contentsOf: imageURL),
              let loaded = UIImage(data: data) else {
            onDismiss()
            return
        }
        image = loaded
        withAnimation(.easeOut(duration: 0.25)) {
            backgroundOpacity = 1.0
            imageOpacity = 1.0
            dismissScale = 1.0
        }
    }
}
