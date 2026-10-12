#if os(macOS)
import XCTest
import Foundation
@testable import HostApp
@testable import SharedProtocol

private final class WorkspaceTestBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value

    init(_ value: Value) {
        storage = value
    }

    var value: Value {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func set(_ value: Value) {
        lock.lock()
        storage = value
        lock.unlock()
    }
}

final class HostWorkspaceServiceTests: XCTestCase {
    func testDiscoveryFindsGitWorkspaceAndReturnsSafeRoots() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("VampWorkspaceTests-\(UUID().uuidString)", isDirectory: true)
        let project = root.appendingPathComponent("Projects/Vamp", isDirectory: true)
        try fileManager.createDirectory(at: project.appendingPathComponent(".git", isDirectory: true), withIntermediateDirectories: true)
        try Data("// test workspace\n".utf8).write(to: project.appendingPathComponent("Package.swift"))
        defer { try? fileManager.removeItem(at: root) }

        let service = HostWorkspaceService(hostID: UUID(), homePath: root.path)
        let expectation = expectation(description: "workspace discovery")
        let workspacesBox = WorkspaceTestBox<[RemoteWorkspace]>([])
        let rootsBox = WorkspaceTestBox<[WorkspaceBrowseRoot]>([])

        service.listWorkspaces(refresh: true) { discovered, browseRoots, errorMessage in
            XCTAssertNil(errorMessage)
            workspacesBox.set(discovered)
            rootsBox.set(browseRoots)
            expectation.fulfill()
        }
        // Hosted arm64 runners can spend several seconds warming filesystem
        // metadata before the first recursive discovery callback arrives.
        wait(for: [expectation], timeout: 8)

        let workspaces = workspacesBox.value
        let roots = rootsBox.value
        let canonicalProjectPath = try XCTUnwrap(service.validatedWorkingDirectory(project.path))
        let vamp = try XCTUnwrap(workspaces.first { $0.path == canonicalProjectPath })
        XCTAssertEqual(vamp.kind, .gitRepository)
        XCTAssertEqual(vamp.gitInfo?.projectHints, ["Swift", "Swift Package"])
        XCTAssertEqual(roots.first?.name, "Home")
        XCTAssertTrue(roots.contains { $0.name == "Projects" })
    }

    func testDirectoryBrowsingAndWorkingDirectoryBoundary() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("VampWorkspaceTests-\(UUID().uuidString)", isDirectory: true)
        let projects = root.appendingPathComponent("Projects", isDirectory: true)
        let one = projects.appendingPathComponent("One", isDirectory: true)
        try fileManager.createDirectory(at: one, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let service = HostWorkspaceService(hostID: UUID(), homePath: root.path)
        let expectation = expectation(description: "directory listing")
        let entriesBox = WorkspaceTestBox<[WorkspaceDirectoryEntry]>([])
        service.listDirectory(path: projects.path) { _, listed, errorMessage in
            XCTAssertNil(errorMessage)
            entriesBox.set(listed)
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 2)

        let entries = entriesBox.value
        XCTAssertEqual(entries.map(\.name), ["One"])
        XCTAssertEqual(service.validatedWorkingDirectory("~/Projects"), projects.path)
        XCTAssertNil(service.validatedWorkingDirectory("/tmp"))
        XCTAssertNil(service.validatedWorkingDirectory(root.path + "/../outside"))
    }

    func testDirectoryBrowsingDoesNotWaitForBackgroundDiscovery() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("VampWorkspaceTests-\(UUID().uuidString)", isDirectory: true)
        let projects = root.appendingPathComponent("Projects", isDirectory: true)
        try fileManager.createDirectory(at: projects, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let service = HostWorkspaceService(
            hostID: UUID(),
            homePath: root.path,
            discoveryDelayForTesting: 1
        )
        let discoveryStarted = expectation(description: "discovery completes")
        service.listWorkspaces(refresh: true) { _, _, _ in discoveryStarted.fulfill() }

        let browseReturned = expectation(description: "interactive browse returns immediately")
        service.listDirectory(path: root.path) { _, _, errorMessage in
            XCTAssertNil(errorMessage)
            browseReturned.fulfill()
        }

        wait(for: [browseReturned], timeout: 0.5)
        wait(for: [discoveryStarted], timeout: 2)
    }
}
#endif
