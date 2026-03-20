import SwiftUI

/// A simple launch splash that shows the gradient logo, then fades out.
struct SplashView: View {
    @State private var logoVisible = false
    @State private var dismissed = false

    /// Called once the splash animation completes so the parent can remove it.
    var onFinished: () -> Void

    var body: some View {
        ZStack {
            Theme.background
                .ignoresSafeArea()

            LinearGradient(
                colors: [Color("PrereadAccent"), Color("PrereadPurple")],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .mask(
                Image("Logo")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            )
            .frame(height: 60)
            .offset(x: 3)
            .scaleEffect(logoVisible ? 1.0 : 0.8)
            .opacity(logoVisible ? 1.0 : 0.0)
        }
        .opacity(dismissed ? 0 : 1)
        .scaleEffect(dismissed ? 1.02 : 1.0)
        .onAppear {
            let animate = !Theme.reduceMotion
            withAnimation(animate ? .easeOut(duration: 0.4) : .linear(duration: 0.15)) {
                logoVisible = true
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
                withAnimation(animate ? .easeIn(duration: 0.3) : .linear(duration: 0.15)) {
                    dismissed = true
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + (animate ? 0.3 : 0.15)) {
                    onFinished()
                }
            }
        }
    }
}
