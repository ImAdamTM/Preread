import SwiftUI

struct ImageLightboxView: View {
    let imageURL: URL
    let onDismiss: () -> Void

    @State private var image: UIImage?
    @State private var scale: CGFloat = 1.0
    @State private var lastScale: CGFloat = 1.0
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero
    @State private var dragOffset: CGSize = .zero
    @State private var backgroundOpacity: Double = 1.0

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black
                    .opacity(backgroundOpacity)
                    .ignoresSafeArea()
                    .onTapGesture { dismiss() }

                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .scaleEffect(scale)
                        .offset(x: offset.width, y: offset.height + dragOffset.height)
                        .gesture(dragGesture(in: geometry))
                        .gesture(pinchGesture)
                        .onTapGesture(count: 2) { toggleZoom(in: geometry) }
                } else {
                    ProgressView()
                        .tint(.white)
                }

                // Close button
                VStack {
                    HStack {
                        Spacer()
                        Button {
                            dismiss()
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(.white)
                                .frame(width: 32, height: 32)
                                .background(.ultraThinMaterial.opacity(0.6), in: Circle())
                        }
                        .padding(.top, geometry.safeAreaInsets.top + 8)
                        .padding(.trailing, 16)
                        .opacity(backgroundOpacity)
                    }
                    Spacer()
                }
                .ignoresSafeArea()
            }
        }
        .statusBarHidden()
        .task { loadImage() }
    }

    // MARK: - Gestures

    private var pinchGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                let newScale = lastScale * value.magnification
                scale = min(max(newScale, 1.0), 5.0)
            }
            .onEnded { _ in
                withAnimation(.easeOut(duration: 0.2)) {
                    if scale < 1.0 { scale = 1.0 }
                    lastScale = scale
                    if scale == 1.0 {
                        offset = .zero
                        lastOffset = .zero
                    }
                }
            }
    }

    /// Unified drag gesture: pans when zoomed in, drags to dismiss at 1x.
    private func dragGesture(in geometry: GeometryProxy) -> some Gesture {
        DragGesture()
            .onChanged { value in
                if scale > 1.0 {
                    offset = CGSize(
                        width: lastOffset.width + value.translation.width,
                        height: lastOffset.height + value.translation.height
                    )
                } else {
                    dragOffset = CGSize(width: 0, height: value.translation.height)
                    let progress = min(abs(value.translation.height) / 300, 1.0)
                    backgroundOpacity = 1.0 - (progress * 0.5)
                }
            }
            .onEnded { value in
                if scale > 1.0 {
                    lastOffset = offset
                } else {
                    if abs(value.translation.height) > 100 {
                        dismiss()
                    } else {
                        withAnimation(.easeOut(duration: 0.2)) {
                            dragOffset = .zero
                            backgroundOpacity = 1.0
                        }
                    }
                }
            }
    }

    private func toggleZoom(in geometry: GeometryProxy) {
        withAnimation(.easeInOut(duration: 0.3)) {
            if scale > 1.0 {
                scale = 1.0
                lastScale = 1.0
                offset = .zero
                lastOffset = .zero
            } else {
                scale = 2.5
                lastScale = 2.5
            }
        }
    }

    // MARK: - Helpers

    private func dismiss() {
        withAnimation(.easeOut(duration: 0.2)) {
            backgroundOpacity = 0
            dragOffset = CGSize(width: 0, height: 300)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            onDismiss()
        }
    }

    private func loadImage() {
        guard imageURL.isFileURL,
              let data = try? Data(contentsOf: imageURL),
              let loaded = UIImage(data: data) else {
            // Image missing or unreadable — skip the lightbox
            onDismiss()
            return
        }
        image = loaded
    }
}
