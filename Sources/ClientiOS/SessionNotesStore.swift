import Foundation

@MainActor
final class SessionNotesStore: ObservableObject {
    @Published var isPresented = false
    @Published var draftText = ""
    @Published var messageDraft = ""
    @Published private(set) var exportURL: URL?
    @Published private(set) var activeHostKey: String?

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func clear() {
        draftText = ""
        exportURL = nil
        if let activeHostKey {
            defaults.removeObject(forKey: activeHostKey)
        }
    }

    func load(hostName: String?) {
        let key = notesKey(hostName: hostName)
        guard activeHostKey != key else { return }
        activeHostKey = key
        draftText = defaults.string(forKey: key) ?? ""
        exportURL = nil
    }

    func saveDraft() {
        guard let activeHostKey else { return }
        defaults.set(draftText, forKey: activeHostKey)
    }

    func export(hostName: String?) throws -> URL {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let hostComponent = (hostName ?? "session")
            .replacingOccurrences(of: " ", with: "-")
            .lowercased()
        let timestamp = formatter.string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("notes-\(hostComponent)-\(timestamp)")
            .appendingPathExtension("txt")

        let text = """
        Session Notes
        Host: \(hostName ?? "Unknown")
        Exported: \(formatter.string(from: Date()))

        \(draftText)
        """
        try text.write(to: url, atomically: true, encoding: .utf8)
        exportURL = url
        return url
    }

    private func notesKey(hostName: String?) -> String {
        let hostComponent = (hostName ?? "default")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: " ", with: "-")
        return "uk.mesut.screenharbor.ios.sessionNotes.\(hostComponent)"
    }
}
