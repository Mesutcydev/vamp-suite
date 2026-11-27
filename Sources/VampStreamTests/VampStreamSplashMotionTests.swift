import SwiftUI
import XCTest
@testable import Vamp_Stream

final class VampStreamSplashMotionTests: XCTestCase {
    func testRenderedBoundsAreOffscreenAtBothEndsAcrossSupportedContainerSizes() {
        let sizes = [CGSize(width: 320, height: 568), CGSize(width: 393, height: 852),
                     CGSize(width: 834, height: 1194), CGSize(width: 844, height: 390),
                     CGSize(width: 240, height: 768)]
        for size in sizes {
            let layout = VampStreamSplashLayout(size: size)
            let entrance = VampStreamSplashMotion.frame(at: 0, layout: layout, reduceMotion: false)
            let exit = VampStreamSplashMotion.frame(at: 1.35, layout: layout, reduceMotion: false)
            XCTAssertGreaterThan(entrance.center.y - layout.markSize.height * entrance.scale / 2, size.height)
            XCTAssertGreaterThan(exit.center.x - layout.markSize.width / 2, size.width)
            XCTAssertLessThan(exit.center.y + layout.markSize.height / 2, 0)
            XCTAssertEqual(exit.titleOpacity, 0, accuracy: 0.00001)
            XCTAssertEqual(exit.backgroundOpacity, 0, accuracy: 0.00001)
            XCTAssertEqual(exit.echoOpacity, 0, accuracy: 0.00001)
        }
    }

    func testSettledArtworkAndTitleFitInsideSafeAreas() {
        let containers: [(CGSize, EdgeInsets)] = [
            (CGSize(width: 320, height: 568), EdgeInsets(top: 20, leading: 0, bottom: 0, trailing: 0)),
            (CGSize(width: 393, height: 852), EdgeInsets(top: 59, leading: 0, bottom: 34, trailing: 0)),
            (CGSize(width: 834, height: 1194), EdgeInsets(top: 24, leading: 0, bottom: 20, trailing: 0)),
            (CGSize(width: 844, height: 390), EdgeInsets(top: 0, leading: 59, bottom: 21, trailing: 59)),
            (CGSize(width: 240, height: 768), EdgeInsets(top: 24, leading: 0, bottom: 20, trailing: 0))
        ]
        for (size, safeArea) in containers {
            let layout = VampStreamSplashLayout(size: size, safeArea: safeArea)
            XCTAssertGreaterThanOrEqual(layout.settledCenter.x - layout.markSize.width / 2, safeArea.leading)
            XCTAssertLessThanOrEqual(layout.settledCenter.x + layout.markSize.width / 2, size.width - safeArea.trailing)
            XCTAssertGreaterThanOrEqual(layout.settledCenter.y - layout.markSize.height / 2, safeArea.top)
            XCTAssertLessThanOrEqual(layout.titleCenterY + layout.titleSize * 0.75, size.height - safeArea.bottom)
            XCTAssertLessThanOrEqual(layout.titleSize, 24)
            XCTAssertEqual(layout.markSize.width / layout.markSize.height, 1.5, accuracy: 0.00001)
        }
    }

    func testTitleFinishesItsFadeBeforeExitAndEchoesFollowTheExitPath() {
        let layout = VampStreamSplashLayout(size: CGSize(width: 720, height: 1564))
        let before = VampStreamSplashMotion.frame(at: 0.38, layout: layout, reduceMotion: false)
        let settled = VampStreamSplashMotion.frame(at: 0.7, layout: layout, reduceMotion: false)
        let exit = VampStreamSplashMotion.frame(at: 1.05, layout: layout, reduceMotion: false)
        let echo = VampStreamSplashMotion.echoCenter(at: 1.05, delay: 0.055, layout: layout)
        XCTAssertEqual(before.titleOpacity, 0)
        XCTAssertEqual(settled.titleOpacity, 1)
        XCTAssertEqual(settled.center.x, layout.settledCenter.x)
        XCTAssertEqual(settled.center.y, layout.settledCenter.y, accuracy: 0.00001)
        XCTAssertEqual(settled.echoOpacity, 0)
        XCTAssertEqual(exit.titleOpacity, 0)
        XCTAssertGreaterThan(exit.echoOpacity, 0)
        XCTAssertLessThanOrEqual(exit.echoOpacity, 0.14)
        XCTAssertLessThan(echo.x, exit.center.x)
        XCTAssertGreaterThan(echo.y, exit.center.y)
    }

    func testReducedMotionHasNoTranslationScaleOrEchoes() {
        let layout = VampStreamSplashLayout(size: CGSize(width: 393, height: 852))
        for time in [0.0, 0.05, 0.1, 0.15, 0.6, 1.2] {
            let frame = VampStreamSplashMotion.frame(at: time, layout: layout, reduceMotion: true)
            XCTAssertEqual(frame.center, layout.settledCenter)
            XCTAssertEqual(frame.scale, 1)
            XCTAssertEqual(frame.echoOpacity, 0)
        }
    }

    func testInvalidGeometryIsNotPresented() {
        for size in [CGSize.zero, CGSize(width: CGFloat.infinity, height: 500), CGSize(width: 300, height: CGFloat.nan)] {
            XCTAssertFalse(VampStreamSplashLayout(size: size).isValid)
        }
    }
}
