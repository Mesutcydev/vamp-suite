import XCTest
@testable import InputControl
@testable import SharedModels
@testable import SharedUtilities
@testable import TransportWebRTC

/// Tests for fixes applied during the final stabilization pass.
final class StabilizationPatchTests: XCTestCase {

    // MARK: - Input Content Validation (#12)

    func testValidPointerMoveAccepted() {
        let cmd = InputCommand.pointerMove(PointerMoveCommand(
            location: DesktopPoint(x: 500, y: 300),
            displayID: "main",
            isAbsolute: true
        ))
        XCTAssertNil(InputCommandValidation.validateContent(cmd))
    }

    func testNaNCoordinateRejected() {
        let cmd = InputCommand.pointerMove(PointerMoveCommand(
            location: DesktopPoint(x: Double.nan, y: 300),
            displayID: "main",
            isAbsolute: true
        ))
        let rejection = InputCommandValidation.validateContent(cmd)
        XCTAssertNotNil(rejection)
        if case .invalidContent = rejection {} else {
            XCTFail("Expected invalidContent, got \(String(describing: rejection))")
        }
    }

    func testInfiniteCoordinateRejected() {
        let cmd = InputCommand.pointerMove(PointerMoveCommand(
            location: DesktopPoint(x: .infinity, y: 0),
            displayID: "main",
            isAbsolute: true
        ))
        XCTAssertNotNil(InputCommandValidation.validateContent(cmd))
    }

    func testExtremeCoordinateRejected() {
        let cmd = InputCommand.pointerButton(PointerButtonCommand(
            button: .left,
            action: .down,
            location: DesktopPoint(x: 200_000, y: 0)
        ))
        XCTAssertNotNil(InputCommandValidation.validateContent(cmd))
    }

    func testEmptyTextRejected() {
        let cmd = InputCommand.text(TextInputCommand(text: ""))
        XCTAssertNotNil(InputCommandValidation.validateContent(cmd))
    }

    func testOverlongTextRejected() {
        let longText = String(repeating: "A", count: 20_000)
        let cmd = InputCommand.text(TextInputCommand(text: longText))
        XCTAssertNotNil(InputCommandValidation.validateContent(cmd))
    }

    func testReasonableTextAccepted() {
        let cmd = InputCommand.text(TextInputCommand(text: "Hello World"))
        XCTAssertNil(InputCommandValidation.validateContent(cmd))
    }

    func testKeyCommandAlwaysAccepted() {
        let cmd = InputCommand.key(KeyCommand(keyCode: 36, action: .down))
        XCTAssertNil(InputCommandValidation.validateContent(cmd))
    }

    func testScrollWithinBoundsAccepted() {
        let cmd = InputCommand.scroll(ScrollCommand(deltaX: 10, deltaY: -10))
        XCTAssertNil(InputCommandValidation.validateContent(cmd))
    }

    func testScrollExcessiveDeltaRejected() {
        let cmd = InputCommand.scroll(ScrollCommand(deltaX: 200_000, deltaY: 0))
        XCTAssertNotNil(InputCommandValidation.validateContent(cmd))
    }

    // MARK: - VideoFrameData Wire Decode Validation (#10)

    func testWireDecodeRejectsZeroWidth() {
        // Encode a frame with zero width manually
        var data = Data()
        appendBigEndian(&data, UInt16(0x5646)) // magic
        data.append(2) // version
        data.append(0) // codec h264
        data.append(0) // flags
        data.append(contentsOf: [0, 0, 0]) // reserved
        appendBigEndian(&data, UInt64(1)) // seq
        appendBigEndian(&data, Double(1.0).bitPattern) // pts
        appendBigEndian(&data, UInt32(0)) // width = 0
        appendBigEndian(&data, UInt32(720)) // height
        appendBigEndian(&data, UInt16(0)) // paramSetSize
        data.append(Data([0x00])) // payload

        XCTAssertThrowsError(try VideoFrameData.wireDecode(data)) { error in
            XCTAssertEqual(error as? VideoFrameData.DecodeError, .invalidDimensions)
        }
    }

    func testWireDecodeRejectsHugeDimensions() {
        var data = Data()
        appendBigEndian(&data, UInt16(0x5646))
        data.append(2)
        data.append(0)
        data.append(0)
        data.append(contentsOf: [0, 0, 0])
        appendBigEndian(&data, UInt64(1))
        appendBigEndian(&data, Double(1.0).bitPattern)
        appendBigEndian(&data, UInt32(50000)) // excessive width
        appendBigEndian(&data, UInt32(50000))
        appendBigEndian(&data, UInt16(0))
        data.append(Data([0x00]))

        XCTAssertThrowsError(try VideoFrameData.wireDecode(data)) { error in
            XCTAssertEqual(error as? VideoFrameData.DecodeError, .invalidDimensions)
        }
    }

    func testWireDecodeAcceptsValidDimensions() throws {
        let original = VideoFrameData(
            codec: .h264,
            data: Data([0xAA, 0xBB]),
            isKeyframe: true,
            presentationTimestamp: 2.5,
            width: 1920,
            height: 1080,
            sequenceNumber: 42
        )
        let wire = original.wireEncode()
        let decoded = try VideoFrameData.wireDecode(wire)
        XCTAssertEqual(decoded.width, 1920)
        XCTAssertEqual(decoded.height, 1080)
        XCTAssertEqual(decoded.sequenceNumber, 42)
    }

    func testLargeVideoFrameFragmentsAndReassembles() throws {
        let original = VideoFrameData(
            codec: .hevc,
            data: Data(repeating: 0xA5, count: 900_000),
            isKeyframe: true,
            presentationTimestamp: 12.5,
            width: 3840,
            height: 2160,
            sequenceNumber: 42,
            parameterSets: Data([0, 0, 0, 1, 0x40])
        )
        let packets = original.wirePackets(maxPacketBytes: 256 * 1024)
        XCTAssertGreaterThan(packets.count, 1)
        XCTAssertTrue(packets.allSatisfy { $0.count <= 256 * 1024 })

        let reassembler = VideoFrameReassembler()
        var decoded: VideoFrameData?
        for packet in packets {
            decoded = try reassembler.ingest(packet) ?? decoded
        }
        XCTAssertEqual(decoded, original)
    }

    // MARK: - XOR FEC (Tier 2a)

    private func makeFECFrame(dataBytes: Int) -> VideoFrameData {
        VideoFrameData(
            codec: .hevc,
            data: Data((0..<dataBytes).map { UInt8(($0 &* 31 &+ 7) & 0xFF) }),
            isKeyframe: true,
            presentationTimestamp: 3.0,
            width: 1920, height: 1080,
            sequenceNumber: 99,
            parameterSets: Data([0, 0, 0, 1, 0x40, 0x01])
        )
    }

    func testFECEmitsExactlyOneParityForMultiFragmentFrame() {
        let frame = makeFECFrame(dataBytes: 20_000)
        let withFEC = frame.wirePackets(maxPacketBytes: 2048, fec: true)
        let withoutFEC = frame.wirePackets(maxPacketBytes: 2048, fec: false)
        XCTAssertGreaterThan(withoutFEC.count, 1)
        XCTAssertEqual(withFEC.count, withoutFEC.count + 1, "FEC appends exactly one parity packet")
    }

    func testFECNoParityForSingleFragment() {
        let frame = makeFECFrame(dataBytes: 200)
        let packets = frame.wirePackets(maxPacketBytes: 64 * 1024, fec: true)
        XCTAssertEqual(packets.count, 1, "single-fragment frames carry no parity")
    }

    func testFECRecoversDroppedMiddleFragment() throws {
        let frame = makeFECFrame(dataBytes: 20_000)
        var packets = frame.wirePackets(maxPacketBytes: 2048, fec: true)
        XCTAssertGreaterThan(packets.count, 3)
        packets.remove(at: 2)   // drop a middle data fragment; parity is still last
        let reassembler = VideoFrameReassembler()
        var decoded: VideoFrameData?
        for p in packets { decoded = try reassembler.ingest(p) ?? decoded }
        XCTAssertEqual(decoded, frame, "single mid-frame loss must be FEC-recovered")
    }

    func testFECRecoversDroppedLastFragment() throws {
        // 20_001 makes the wire length non-divisible by the fragment size, so the last
        // fragment is shorter — exercises the zero-padding / trim path in recovery.
        let frame = makeFECFrame(dataBytes: 20_001)
        var packets = frame.wirePackets(maxPacketBytes: 2048, fec: true)
        let parity = packets.removeLast()   // parity is appended last
        packets.removeLast()                // drop the last (short) data fragment
        packets.append(parity)
        let reassembler = VideoFrameReassembler()
        var decoded: VideoFrameData?
        for p in packets { decoded = try reassembler.ingest(p) ?? decoded }
        XCTAssertEqual(decoded, frame, "last-fragment loss must be FEC-recovered")
    }

    func testFECRecoversRegardlessOfParityArrivalOrder() throws {
        let frame = makeFECFrame(dataBytes: 20_000)
        var packets = frame.wirePackets(maxPacketBytes: 2048, fec: true)
        let parity = packets.removeLast()
        packets.remove(at: 0)               // drop first data fragment
        let reassembler = VideoFrameReassembler()
        var decoded: VideoFrameData?
        decoded = try reassembler.ingest(parity) ?? decoded   // parity arrives first
        for p in packets { decoded = try reassembler.ingest(p) ?? decoded }
        XCTAssertEqual(decoded, frame, "recovery must not depend on parity arrival order")
    }

    func testFECCannotRecoverTwoLosses() throws {
        let frame = makeFECFrame(dataBytes: 20_000)
        var packets = frame.wirePackets(maxPacketBytes: 2048, fec: true)
        XCTAssertGreaterThan(packets.count, 4)
        packets.remove(at: 3)               // two data fragments lost — beyond single parity
        packets.remove(at: 1)
        let reassembler = VideoFrameReassembler()
        var decoded: VideoFrameData?
        for p in packets { decoded = try reassembler.ingest(p) ?? decoded }
        XCTAssertNil(decoded, "two losses exceed single-parity FEC; frame stays incomplete")
    }

    // MARK: - Multi-display demux (Tier 4a)

    func testFragmentsDemuxByDisplayIDDespiteSameSequence() throws {
        // Two displays send fragmented frames with the SAME sequence number; interleaved
        // on one channel they must reassemble independently (keyed by displayID, not seq).
        func frame(_ display: UInt8, _ byte: UInt8) -> VideoFrameData {
            VideoFrameData(codec: .hevc, data: Data(repeating: byte, count: 20_000),
                           isKeyframe: true, presentationTimestamp: 1.0, width: 1920, height: 1080,
                           sequenceNumber: 42, parameterSets: Data([0, 0, 0, 1, 0x40]), displayID: display)
        }
        let a = frame(0, 0xAA), b = frame(1, 0xBB)
        let pa = a.wirePackets(maxPacketBytes: 2048)
        let pb = b.wirePackets(maxPacketBytes: 2048)
        XCTAssertGreaterThan(pa.count, 1)
        var interleaved: [Data] = []
        for i in 0..<max(pa.count, pb.count) {
            if i < pa.count { interleaved.append(pa[i]) }
            if i < pb.count { interleaved.append(pb[i]) }
        }
        let reassembler = VideoFrameReassembler()
        var got: [VideoFrameData] = []
        for p in interleaved { if let f = try reassembler.ingest(p) { got.append(f) } }
        XCTAssertEqual(Set(got.map { $0.displayID }), [0, 1], "both displays reassemble")
        XCTAssertEqual(got.first { $0.displayID == 0 }?.data, a.data)
        XCTAssertEqual(got.first { $0.displayID == 1 }?.data, b.data)
    }

    func testDisplayIDSurvivesWholeFrameWireRoundTrip() throws {
        let f = VideoFrameData(codec: .h264, data: Data([1, 2, 3, 4]), isKeyframe: false,
                               presentationTimestamp: 2.0, width: 640, height: 480,
                               sequenceNumber: 7, displayID: 3)
        let decoded = try VideoFrameData.wireDecode(f.wireEncode())
        XCTAssertEqual(decoded.displayID, 3)
        XCTAssertEqual(decoded.data, f.data)
    }

    // MARK: - Viewport Coordinate Mapper (#9)

    func testZeroSizeDisplayDeltaReturnsZero() {
        let display = DisplayDescriptor(
            id: "test", name: "Test",
            frame: DesktopRect(origin: .zero, size: .zero),
            pixelSize: .zero, scaleFactor: 1, isPrimary: true
        )
        let mapper = ViewportCoordinateMapper(
            display: display,
            viewSize: DesktopSize(width: 100, height: 100)
        )
        let delta = mapper.viewDeltaToDisplayDelta(dx: 10, dy: 5)
        XCTAssertEqual(delta.x, 0)
        XCTAssertEqual(delta.y, 0)
    }

    func testZeroViewSizeDeltaReturnsZero() {
        let display = DisplayDescriptor(
            id: "test", name: "Test",
            frame: DesktopRect(origin: .zero, size: DesktopSize(width: 1920, height: 1080)),
            pixelSize: DesktopSize(width: 3840, height: 2160), scaleFactor: 2, isPrimary: true
        )
        let mapper = ViewportCoordinateMapper(
            display: display,
            viewSize: .zero
        )
        let delta = mapper.viewDeltaToDisplayDelta(dx: 10, dy: 5)
        XCTAssertEqual(delta.x, 0)
        XCTAssertEqual(delta.y, 0)
    }

    func testPointerButtonLocationTranslatesToGlobalCoordinates() throws {
        let display = DisplayDescriptor(
            id: "secondary",
            name: "Left",
            frame: DesktopRect(origin: DesktopPoint(x: -1920, y: 0), size: DesktopSize(width: 1920, height: 1080)),
            pixelSize: DesktopSize(width: 3840, height: 2160),
            scaleFactor: 2,
            isPrimary: false
        )
        let layout = DisplayLayout.computed(from: [display])
        let command = InputCommand.pointerButton(
            PointerButtonCommand(
                button: .left,
                action: .click,
                location: DesktopPoint(x: 960, y: 540),
                displayID: "secondary"
            )
        )

        let result = InputCoordinateTranslator.translateToGlobal(command, layout: layout)
        switch result {
        case .success(.pointerButton(let translated)):
            let location = try XCTUnwrap(translated.location)
            XCTAssertEqual(location.x, -960, accuracy: 0.001)
            XCTAssertEqual(location.y, 540, accuracy: 0.001)
            XCTAssertEqual(translated.displayID, "secondary")
        default:
            XCTFail("Expected translated pointer button command")
        }
    }

    // MARK: - Negative Origin Coordinate Mapping

    func testNegativeOriginDisplayGlobalToLocal() {
        let display = DisplayDescriptor(
            id: "secondary", name: "Left",
            frame: DesktopRect(origin: DesktopPoint(x: -1920, y: 0), size: DesktopSize(width: 1920, height: 1080)),
            pixelSize: DesktopSize(width: 3840, height: 2160), scaleFactor: 2, isPrimary: false
        )
        let layout = DisplayLayout.computed(from: [display])
        let local = layout.globalToLocal(DesktopPoint(x: -960, y: 540), displayID: "secondary")
        XCTAssertNotNil(local)
        XCTAssertEqual(local!.x, 960, accuracy: 0.001)
        XCTAssertEqual(local!.y, 540, accuracy: 0.001)
    }

    func testNegativeOriginLocalToGlobal() {
        let display = DisplayDescriptor(
            id: "secondary", name: "Left",
            frame: DesktopRect(origin: DesktopPoint(x: -1920, y: 0), size: DesktopSize(width: 1920, height: 1080)),
            pixelSize: DesktopSize(width: 3840, height: 2160), scaleFactor: 2, isPrimary: false
        )
        let layout = DisplayLayout.computed(from: [display])
        let global = layout.localToGlobal(DesktopPoint(x: 960, y: 540), displayID: "secondary")
        XCTAssertNotNil(global)
        XCTAssertEqual(global!.x, -960, accuracy: 0.001)
        XCTAssertEqual(global!.y, 540, accuracy: 0.001)
    }

    // MARK: - Helpers

    private func appendBigEndian<T: FixedWidthInteger>(_ data: inout Data, _ value: T) {
        var big = value.bigEndian
        withUnsafeBytes(of: &big) { data.append(contentsOf: $0) }
    }
}
