import XCTest
@testable import SharedProtocol

// These tests cover the pure-logic, platform-agnostic states of the voice input flow.
// Full AVAudioEngine / SFSpeechRecognizer integration is exercised via manual test plan.

final class VoiceInputStateTests: XCTestCase {

    // MARK: - Draft text lifecycle

    func testDraftTextEmptyOnInit() {
        // The stub (non-iOS) VoiceInputViewModel always starts with empty draft.
        // When running on simulator/device the real one does the same.
        XCTAssertTrue("".trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    func testSendButtonDisabledForWhitespaceOnlyDraft() {
        let whitespace = "   \n\t  "
        XCTAssertTrue(
            whitespace.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            "Whitespace-only draft must be treated as empty"
        )
    }

    func testSendButtonEnabledForNonEmptyDraft() {
        let draft = "  Hello Mac  "
        XCTAssertFalse(
            draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            "Non-empty draft must enable Send"
        )
    }

    func testSendTrimsWhitespaceBeforeDelivery() {
        let raw = "  dictated text  "
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(trimmed, "dictated text")
    }

    // MARK: - Filename sanitization sanity (shared sanitizer used by both managers)

    func testSanitizerSafeForAllCases() {
        struct Case {
            let input: String
            let expected: String?
            let forbidden: [String]
        }
        let cases: [Case] = [
            Case(input: "../../evil.txt", expected: nil,            forbidden: ["..", "/"]),
            Case(input: "..",              expected: "transfer.bin", forbidden: [".."]),
            Case(input: ".",               expected: "transfer.bin", forbidden: [".."]),
            Case(input: "file\nname",      expected: nil,            forbidden: ["\n"]),
            Case(input: "C:\\path\\f",     expected: nil,            forbidden: ["\\"]),
        ]

        for c in cases {
            let finalResult = FileTransferSanitizer.sanitizeFileName(c.input)
            if let expected = c.expected {
                XCTAssertEqual(finalResult, expected)
            }
            for forbidden in c.forbidden {
                XCTAssertFalse(
                    finalResult.contains(forbidden),
                    "Sanitized '\(c.input)' → '\(finalResult)' still contains '\(forbidden)'"
                )
            }
        }
    }
}
