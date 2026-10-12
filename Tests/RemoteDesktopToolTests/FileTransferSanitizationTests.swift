import XCTest
@testable import SharedProtocol

final class FileTransferSanitizationTests: XCTestCase {

    // MARK: - Normal filenames

    func testNormalFilenamePassesThrough() {
        XCTAssertEqual(FileTransferSanitizer.sanitizeFileName("report.pdf"), "report.pdf")
    }

    func testFilenameWithSpacesPassesThrough() {
        XCTAssertEqual(FileTransferSanitizer.sanitizeFileName("my document.docx"), "my document.docx")
    }

    // MARK: - Path traversal / injection

    func testPathSeparatorReplacedWithUnderscore() {
        let result = FileTransferSanitizer.sanitizeFileName("../../evil.txt")
        XCTAssertFalse(result.contains("/"), "Sanitized name must not contain /")
        XCTAssertFalse(result.contains(".."), "Sanitized name must not contain ..")
    }

    func testBackslashReplacedWithUnderscore() {
        let result = FileTransferSanitizer.sanitizeFileName("C:\\Windows\\evil.exe")
        XCTAssertFalse(result.contains("\\"), "Sanitized name must not contain \\")
    }

    func testDotDotAloneReturnsFallback() {
        XCTAssertEqual(FileTransferSanitizer.sanitizeFileName(".."), "transfer.bin")
    }

    func testSingleDotAloneReturnsFallback() {
        XCTAssertEqual(FileTransferSanitizer.sanitizeFileName("."), "transfer.bin")
    }

    func testColonReplacedWithUnderscore() {
        let result = FileTransferSanitizer.sanitizeFileName("file:name.txt")
        XCTAssertFalse(result.contains(":"), "Sanitized name must not contain :")
    }

    func testNewlineStripped() {
        let result = FileTransferSanitizer.sanitizeFileName("file\nname.txt")
        XCTAssertFalse(result.contains("\n"), "Sanitized name must not contain newlines")
    }

    // MARK: - Edge cases

    func testEmptyStringReturnsFallback() {
        XCTAssertEqual(FileTransferSanitizer.sanitizeFileName(""), "transfer.bin")
    }

    func testWhitespaceOnlyReturnsFallback() {
        XCTAssertEqual(FileTransferSanitizer.sanitizeFileName("   "), "transfer.bin")
    }

    func testLongFilenameTruncatedTo120Characters() {
        let long = String(repeating: "a", count: 200) + ".txt"
        let result = FileTransferSanitizer.sanitizeFileName(long)
        XCTAssertLessThanOrEqual(result.count, 120)
    }

    func testLegitimateUnicodeFilenamePreserved() {
        let name = "照片.jpg"
        let result = FileTransferSanitizer.sanitizeFileName(name)
        XCTAssertEqual(result, name)
    }

    func testTabReplacedWithUnderscore() {
        let result = FileTransferSanitizer.sanitizeFileName("file\tname.txt")
        XCTAssertFalse(result.contains("\t"), "Sanitized name must not contain tabs")
    }

    func testAllInvalidCharsProduceFallback() {
        XCTAssertEqual(FileTransferSanitizer.sanitizeFileName("/:\\"), "transfer.bin")
    }
}
