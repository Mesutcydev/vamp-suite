import Foundation
import XCTest
@testable import ClientiOS

final class BeetCodeRemoteClientTests: XCTestCase {
    func testAssistantUnlockStatusDecodesAndOffersSecureEntry() throws {
        let data = Data(#"{"enabled":true,"screenRecording":true,"accessibility":true,"ready":false,"locked":true,"remoteUnlockEnabled":true,"remoteUnlockAvailable":true,"remoteUnlockMessage":"Enter the Mac login password.","displays":[]}"#.utf8)

        let status = try JSONDecoder().decode(BeetCodeControlStatus.self, from: data)

        XCTAssertTrue(status.shouldOfferRemoteUnlock)
        XCTAssertEqual(status.remoteUnlockMessage, "Enter the Mac login password.")
    }

    func testOlderAssistantStatusKeepsUnlockEntryHidden() throws {
        let data = Data(#"{"enabled":true,"screenRecording":true,"accessibility":true,"ready":false,"message":"Not ready","displays":[]}"#.utf8)

        let status = try JSONDecoder().decode(BeetCodeControlStatus.self, from: data)

        XCTAssertFalse(status.shouldOfferRemoteUnlock)
    }

    func testEndpointDefaultsPortAndExtractsPairingCodeFromQuery() throws {
        let endpoint = try BeetCodeRemoteEndpoint.parse(address: "http://192.168.1.20/?pair=123456")
        XCTAssertEqual(endpoint.url.absoluteString, "http://192.168.1.20:9575")
        XCTAssertEqual(endpoint.pairingCode, "123456")
    }

    func testEndpointRejectsPlainHTTPPublicAddress() {
        XCTAssertThrowsError(try BeetCodeRemoteEndpoint.parse(address: "http://example.com:9575")) { error in
            XCTAssertEqual(error as? BeetCodeRemoteError, .insecurePublicAddress)
        }
    }

    func testEndpointAcceptsSecurePublicAddressAndRejectsBadCode() throws {
        let endpoint = try BeetCodeRemoteEndpoint.parse(address: "https://example.com:9575", pairingCode: "123456")
        XCTAssertEqual(endpoint.url.host, "example.com")
        XCTAssertEqual(endpoint.pairingCode, "123456")
        XCTAssertThrowsError(try BeetCodeRemoteEndpoint.parse(address: "192.168.1.20", pairingCode: "123")) { error in
            XCTAssertEqual(error as? BeetCodeRemoteError, .invalidPairingCode)
        }
    }

    func testInputCommandsUseBeetCodeWireActions() {
        let commands: [BeetCodeInputCommand] = [
            .click(x: 10, y: 20, button: "left", count: 2),
            .move(x: 30, y: 40),
            .relative(dx: 2, dy: -1),
            .down(button: "left"),
            .up(button: "left"),
            .scroll(x: nil, y: nil, dx: 1, dy: -2),
            .type("hello"),
            .key("Return", modifiers: ["command"])
        ]
        XCTAssertEqual(commands.map { $0.wireBody()["action"] as? String }, [
            "click", "move", "rel", "down", "up", "scroll", "type", "key"
        ])
        XCTAssertEqual(commands[0].wireBody()["count"] as? Int, 2)
        XCTAssertEqual((commands[2].wireBody()["x"] as? NSNumber)?.doubleValue, 2)
        XCTAssertEqual(commands[7].wireBody()["modifiers"] as? [String], ["command"])
    }

    func testAssistantTapUsesOrderedMoveDownUpPrimitives() {
        let commands = BeetCodeInputCommand.clickSequence(
            x: 120,
            y: 240,
            button: "left",
            count: 1
        )
        XCTAssertEqual(commands.map { $0.wireBody()["action"] as? String }, [
            "move", "down", "up"
        ])
        XCTAssertEqual((commands[0].wireBody()["x"] as? NSNumber)?.doubleValue, 120)
        XCTAssertEqual((commands[0].wireBody()["y"] as? NSNumber)?.doubleValue, 240)
    }

    func testAssistantDoubleTapSendsTwoCompleteButtonPairs() {
        let commands = BeetCodeInputCommand.clickSequence(
            x: nil,
            y: nil,
            button: "left",
            count: 2
        )
        XCTAssertEqual(commands.map { $0.wireBody()["action"] as? String }, [
            "down", "up", "down", "up"
        ])
    }

    func testRemoteApplicationListPayloadDecodesStableWindowIdentity() throws {
        let data = Data(#"{"windowID":42,"bundleIdentifier":"com.apple.Safari","name":"Safari","windowTitle":"Start Page","width":1280,"height":800}"#.utf8)
        let application = try JSONDecoder().decode(BeetCodeRemoteApplication.self, from: data)
        XCTAssertEqual(application.id, "com.apple.Safari")
        XCTAssertEqual(application.streamListID, "window:42")
        XCTAssertEqual(application.bundleIdentifier, "com.apple.Safari")
        XCTAssertEqual(application.name, "Safari")
        XCTAssertEqual(application.windowTitle, "Start Page")
        XCTAssertTrue(application.isRunning)
        XCTAssertFalse(application.isActive)
    }

    func testInstalledRemoteApplicationDecodesWithoutWindow() throws {
        let data = Data(#"{"windowID":null,"bundleIdentifier":"com.apple.TextEdit","name":"TextEdit","width":0,"height":0,"isRunning":false,"isActive":false}"#.utf8)
        let application = try JSONDecoder().decode(BeetCodeRemoteApplication.self, from: data)
        XCTAssertNil(application.windowID)
        XCTAssertEqual(application.id, "com.apple.TextEdit")
        XCTAssertFalse(application.isRunning)
    }

    func testMultipartParserHandlesSplitH264PartAndGeometry() throws {
        let boundary = "beet-test"
        let parameterSets = Data([0, 0, 0, 1, 0x67, 0x64])
        let avcc = Data([0, 0, 0, 2, 0x65, 0x01])
        var body = Data()
        body.append(parameterSets)
        body.append(avcc)
        let message = Data(
            "--\(boundary)\r\nContent-Type: video/avc\r\nContent-Length: \(body.count)\r\nX-Beet-Keyframe: 1\r\nX-Beet-Params-Length: \(parameterSets.count)\r\nX-Beet-Image-Width: 1920\r\nX-Beet-Image-Height: 1080\r\nX-Beet-Display-X: 10\r\nX-Beet-Display-Y: 20\r\nX-Beet-Display-Width: 960\r\nX-Beet-Display-Height: 540\r\n\r\n".utf8
        ) + body + Data("\r\n--\(boundary)--\r\n".utf8)
        let response = try XCTUnwrap(HTTPURLResponse(
            url: URL(string: "http://192.168.1.20:9575/api/control/screen/stream")!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "multipart/mixed; boundary=\(boundary)"]))

        var parser = BeetCodeScreenStreamParser()
        try parser.configure(response: response)
        var frames: [BeetCodeScreenFrame] = []
        let chunkSize = 7
        var offset = 0
        while offset < message.count {
            let end = min(offset + chunkSize, message.count)
            frames.append(contentsOf: try parser.append(message.subdata(in: offset..<end)))
            offset = end
        }

        let frame = try XCTUnwrap(frames.first)
        XCTAssertEqual(frame.geometry, BeetCodeDisplayGeometry(
            imageWidth: 1920,
            imageHeight: 1080,
            displayX: 10,
            displayY: 20,
            displayWidth: 960,
            displayHeight: 540))
        guard case let .h264(data, keyframe, params) = frame.payload else {
            return XCTFail("Expected H.264 payload")
        }
        XCTAssertEqual(data, avcc)
        XCTAssertTrue(keyframe)
        XCTAssertEqual(params, parameterSets)
    }
}
