import SwiftUI

enum TunerTypography {
    static let screenTitle = Font.custom("DM Sans", size: 28, relativeTo: .largeTitle).weight(.bold)
    static let sectionTitle = Font.custom("DM Sans", size: 20, relativeTo: .title2).weight(.semibold)
    static let title = Font.custom("DM Sans", size: 17, relativeTo: .headline).weight(.semibold)
    static let body = Font.custom("DM Sans", size: 17, relativeTo: .body)
    static let compactBody = Font.custom("DM Sans", size: 15, relativeTo: .callout)
    static let supporting = Font.custom("DM Sans", size: 13, relativeTo: .footnote)
    static let caption = Font.custom("DM Sans", size: 12, relativeTo: .caption).weight(.semibold)
    static let symbolTitle = Font.custom("DM Sans", size: 22, relativeTo: .title2).weight(.semibold)
}

struct TunerCanvasBackground: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color.nordicBackground, Color.nordicBackgroundEnd],
                startPoint: .top,
                endPoint: .bottom
            )
            Canvas { context, size in
                guard size.width > 0, size.height > 0 else { return }

                let width = max(1, Int(size.width))
                let height = max(1, Int(size.height))
                let sampleCount = min(4_000, max(512, width * height / 128))
                let grainColor = colorScheme == .dark ? Color.white : Color.black
                var state: UInt64 = 0x4D595DF4
                var grain = Path()

                for _ in 0..<sampleCount {
                    state = state &* 6_364_136_223_846_793_005 &+ 1
                    let x = CGFloat(Int(state % UInt64(width)))
                    state = state &* 6_364_136_223_846_793_005 &+ 1
                    let y = CGFloat(Int(state % UInt64(height)))
                    grain.addEllipse(in: CGRect(x: x, y: y, width: 0.7, height: 0.7))
                }
                context.fill(grain, with: .color(grainColor.opacity(0.08)))
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
        .ignoresSafeArea()
    }
}

extension View {
    /// Native lists and forms use Surface; Canvas stays behind app pages and empty states.
    func nordicListStyle() -> some View {
        scrollContentBackground(.hidden)
            .background(Color.nordicSurface)
            .foregroundStyle(Color.nordicText)
            .font(TunerTypography.body)
    }
}
