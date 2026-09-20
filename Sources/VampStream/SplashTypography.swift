import SwiftUI

struct SplashTypography: View {
    @ScaledMetric(relativeTo: .title2) private var titleScale: CGFloat = 1
    @ScaledMetric(relativeTo: .footnote) private var detailScale: CGFloat = 1
    let showTitle: Bool
    let showSubtitle: Bool
    let showBottomLabel: Bool
    let size: CGSize
    let reduceMotion: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: max(4, size.height * 0.006)) {
            Text(verbatim: "VAMP STREAM")
                .font(.system(size: titleSize, weight: .medium))
                .tracking(titleSize * titleTracking)
                .foregroundStyle(SplashTheme.ivory)
                .opacity(showTitle ? 1 : 0)
                .offset(y: showTitle ? 0 : 4)

            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: "STREAM MAC APPS")
                Text(verbatim: "TO YOUR iPHONE")
            }
            .font(.system(size: subtitleSize, weight: .medium))
            .tracking(subtitleSize * subtitleTracking)
            .foregroundStyle(SplashTheme.ivory)
            .opacity(showSubtitle ? 1 : 0)
            .offset(y: showSubtitle ? 0 : 3)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.leading, max(24, size.width * 0.075))
        .padding(.top, max(16, size.height * 0.065))
        .overlay(alignment: .bottomLeading) {
            Text(verbatim: "WORK\nCREATE\nPLAY\nANYWHERE")
                .font(.system(size: bottomSize, weight: .medium))
                .tracking(bottomSize * 0.16)
                .foregroundStyle(SplashTheme.ivory)
                .opacity(showBottomLabel ? 1 : 0)
                .padding(.leading, max(24, size.width * 0.075))
                .padding(.bottom, max(16, size.height * 0.06))
        }
        .allowsHitTesting(false)
        .animation(reduceMotion ? nil : .easeOut(duration: SplashTiming.titleDuration), value: showTitle)
        .animation(reduceMotion ? nil : .easeOut(duration: SplashTiming.titleDuration), value: showSubtitle)
        .animation(reduceMotion ? nil : .easeOut(duration: SplashTiming.portalDuration), value: showBottomLabel)
    }

    private var titleSize: CGFloat { max(19, min(24, size.width * 0.055)) * titleScale }
    private var subtitleSize: CGFloat { max(13, min(16, size.width * 0.034)) * detailScale }
    private var bottomSize: CGFloat { max(12, min(14, size.width * 0.031)) * detailScale }
    private var titleTracking: CGFloat { showTitle ? 0.14 : 0.25 }
    private var subtitleTracking: CGFloat { showSubtitle ? 0.13 : 0.18 }
}
