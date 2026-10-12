import AppKit
import SharedModels
import SharedUtilities
import XCTest

final class RemoteInputPolicyTests: XCTestCase {
    func testDisplayModeMenuExposesFitDisplayAsFirstClassOption() {
        let titles = DisplayMappingEngine.DisplayMode.allCases.map(\.title)
        XCTAssertTrue(titles.contains("Fit Display"))
        XCTAssertTrue(titles.contains("Fill Screen"))
        XCTAssertTrue(titles.contains("Actual Size"))
        XCTAssertEqual(DisplayMappingEngine.DisplayMode.fitDisplay.title, "Fit Display")
    }

    func testControlPrimaryClickTranslatesToSecondaryClick() {
        XCTAssertEqual(RemotePrimaryClickTranslation.button(controlPressed: false), MouseButton.left)
        XCTAssertEqual(RemotePrimaryClickTranslation.button(controlPressed: true), MouseButton.right)
    }

    // MARK: - Key equivalents

    func testDisconnectShortcutStaysLocal() {
        // Regression: the old predicate bailed out whenever Shift was held, so
        // ⇧⌘D was forwarded to the host and never left the session.
        XCTAssertTrue(RemoteKeyEquivalentPolicy.staysLocal(characters: "D", modifiers: [.command, .shift]))
        XCTAssertTrue(RemoteKeyEquivalentPolicy.staysLocal(characters: "d", modifiers: [.command, .shift]))
    }

    func testViewMenuDisplayShortcutsStayLocal() {
        for key in ["0", "1", "2"] {
            XCTAssertTrue(
                RemoteKeyEquivalentPolicy.staysLocal(characters: key, modifiers: [.command]),
                "⌘\(key) is bound in the View menu and must not go to the host"
            )
        }
    }

    func testApplicationMenuShortcutsStayLocal() {
        for key in ["q", "m", "h", ",", "r"] {
            XCTAssertTrue(RemoteKeyEquivalentPolicy.staysLocal(characters: key, modifiers: [.command]))
        }
    }

    func testEverythingElseGoesToTheHost() {
        // The point of a remote-desktop client: the remote Mac gets the shortcut.
        for key in ["c", "v", "s", "t", "w", "a", "z"] {
            XCTAssertFalse(RemoteKeyEquivalentPolicy.staysLocal(characters: key, modifiers: [.command]))
        }
        XCTAssertFalse(RemoteKeyEquivalentPolicy.staysLocal(characters: "d", modifiers: [.command]))
        XCTAssertFalse(RemoteKeyEquivalentPolicy.staysLocal(characters: "q", modifiers: [.command, .shift]))
        XCTAssertFalse(RemoteKeyEquivalentPolicy.staysLocal(characters: "r", modifiers: []))
    }

    func testControlOptionCombinationsAreNeverOurs() {
        // Session actions use ⌃⌥ precisely so they do not take ⌘ keys from the host.
        XCTAssertFalse(RemoteKeyEquivalentPolicy.staysLocal(characters: "0", modifiers: [.command, .option]))
        XCTAssertFalse(RemoteKeyEquivalentPolicy.staysLocal(characters: "q", modifiers: [.command, .control]))
    }
}

@MainActor
final class RemoteArrowKeyMonitorTests: XCTestCase {
    private func event(_ code: UInt16, type: NSEvent.EventType = .keyDown,
                       modifiers: NSEvent.ModifierFlags = [], repeatKey: Bool = false) -> NSEvent {
        NSEvent.keyEvent(with: type, location: .zero, modifierFlags: modifiers,
                         timestamp: 0, windowNumber: 0, context: nil,
                         characters: "", charactersIgnoringModifiers: "",
                         isARepeat: repeatKey, keyCode: code)!
    }

    func testAllArrowsForwardDownRepeatAndUpWithModifiers() {
        let monitor = RemoteArrowKeyMonitor()
        let view = NSView()
        var received: [(UInt16, KeyAction, NSEvent.ModifierFlags)] = []
        monitor.start(for: view, isEnabled: { true }) { event, action in
            received.append((event.keyCode, action, event.modifierFlags))
        }
        defer { monitor.stop() }
        for code: UInt16 in 123...126 {
            XCTAssertNil(monitor.handle(event(code, modifiers: [.shift, .function]), ownsKeyboard: true))
            XCTAssertNil(monitor.handle(event(code, modifiers: [.shift, .function], repeatKey: true), ownsKeyboard: true))
            XCTAssertNil(monitor.handle(event(code, type: .keyUp, modifiers: [.shift, .function]), ownsKeyboard: true))
        }
        XCTAssertEqual(received.map { $0.0 }, [123,123,123,124,124,124,125,125,125,126,126,126])
        XCTAssertEqual(received.map { $0.1 }, Array(repeating: [KeyAction.down, .down, .up], count: 4).flatMap { $0 })
        XCTAssertTrue(received.allSatisfy { $0.2 == [.shift, .function] })
    }

    func testLocalFocusAndNonArrowShortcutsAreNotConsumed() {
        let monitor = RemoteArrowKeyMonitor()
        let view = NSView()
        var sent = 0
        monitor.start(for: view, isEnabled: { true }) { _, _ in sent += 1 }
        defer { monitor.stop() }
        XCTAssertNotNil(monitor.handle(event(123), ownsKeyboard: false))
        XCTAssertNotNil(monitor.handle(event(2, modifiers: [.command, .shift]), ownsKeyboard: true))
        XCTAssertNotNil(monitor.handle(event(0), ownsKeyboard: true))
        XCTAssertEqual(sent, 0)
    }

    func testFocusLossAndStopReleaseHeldArrowsExactlyOnce() {
        let monitor = RemoteArrowKeyMonitor()
        let view = NSView()
        var actions: [KeyAction] = []
        monitor.start(for: view, isEnabled: { true }) { _, action in actions.append(action) }
        _ = monitor.handle(event(126), ownsKeyboard: true)
        monitor.releasePressedKeys()
        monitor.releasePressedKeys()
        XCTAssertNotNil(monitor.handle(event(126, type: .keyUp), ownsKeyboard: true))
        _ = monitor.handle(event(123), ownsKeyboard: true)
        monitor.stop()
        monitor.stop()
        XCTAssertEqual(actions, [.down, .up, .down, .up])
    }
}

final class MacInputReadinessTests: XCTestCase {
    func testEveryUnavailableConditionBlocksInput() {
        for connected in [false, true] {
            for locked in [false, true] {
                for choosingApp in [false, true] {
                    for receiving in [false, true] {
                        for viewOnly in [false, true] {
                            let state = MacInputReadiness.resolve(connected: connected, locked: locked,
                                choosingApp: choosingApp, receivingVideo: receiving, viewOnly: viewOnly)
                            XCTAssertEqual(state.canSendInput, connected && !locked && !choosingApp && receiving && !viewOnly)
                        }
                    }
                }
            }
        }
    }

    func testExplainsReadinessBeforeViewOnlyPreference() {
        XCTAssertEqual(MacInputReadiness.resolve(connected: false, locked: false, choosingApp: false,
            receivingVideo: true, viewOnly: true), .reconnecting)
        XCTAssertEqual(MacInputReadiness.resolve(connected: true, locked: true, choosingApp: false,
            receivingVideo: true, viewOnly: true), .locked)
        XCTAssertEqual(MacInputReadiness.resolve(connected: true, locked: false, choosingApp: true,
            receivingVideo: true, viewOnly: false), .choosingApp)
    }
}

final class MacKeyboardPreferenceTests: XCTestCase {
    func testRemoteDisplayShortcutPreferenceDoesNotTakeDisconnectOrQuit() {
        for key in ["0", "1", "2"] {
            XCTAssertFalse(RemoteKeyEquivalentPolicy.staysLocal(characters: key, modifiers: .command,
                keepsDisplayShortcutsLocal: false))
        }
        XCTAssertTrue(RemoteKeyEquivalentPolicy.staysLocal(characters: "d", modifiers: [.command, .shift],
            keepsDisplayShortcutsLocal: false))
        XCTAssertTrue(RemoteKeyEquivalentPolicy.staysLocal(characters: "q", modifiers: .command,
            keepsDisplayShortcutsLocal: false))
    }

    func testExplicitArrowShortcutsMatchBothTransportMappings() {
        for key in [MacRemoteShortcut.left, .right, .up, .down, .controlLeft, .controlRight, .controlUp, .controlDown] {
            XCTAssertEqual(key.assistantKey, MacAssistantKeyMapping.name(for: key.keyCode))
            XCTAssertEqual(key.modifiers.contains(.control), key.assistantModifiers.contains("control"))
        }
    }
}

final class MacRemoteContentLayoutTests: XCTestCase {
    func testRetinaActualSizeRemainsOneToOneWhenWindowIsSmaller() {
        let rect = MacRemoteContentLayout.rect(imageSize: CGSize(width: 2000, height: 1000),
            viewSize: CGSize(width: 600, height: 400), pixelScale: 2, mode: .actualSize)
        XCTAssertEqual(rect, CGRect(x: -200, y: -50, width: 1000, height: 500))
    }
    func testFitAndFillUseTheSameCenterWithDifferentCropping() {
        let image = CGSize(width: 2000, height: 1000)
        let view = CGSize(width: 600, height: 400)
        XCTAssertEqual(MacRemoteContentLayout.rect(imageSize: image, viewSize: view, pixelScale: 2, mode: .fitDisplay),
                       CGRect(x: 0, y: 50, width: 600, height: 300))
        XCTAssertEqual(MacRemoteContentLayout.rect(imageSize: image, viewSize: view, pixelScale: 2, mode: .fillScreen),
                       CGRect(x: -100, y: 0, width: 800, height: 400))
        XCTAssertNil(MacRemoteContentLayout.rect(imageSize: .zero, viewSize: view, pixelScale: 2, mode: .fitDisplay))
    }
}
