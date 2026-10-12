import Foundation

public enum FileTransferSanitizer {
    public static func sanitizeFileName(_ fileName: String) -> String {
        let fallback = "transfer.bin"
        let separators = CharacterSet(charactersIn: "/:\\")

        let filteredScalars = fileName.precomposedStringWithCanonicalMapping.unicodeScalars.map { scalar -> Character in
            if CharacterSet.controlCharacters.contains(scalar)
                || separators.contains(scalar)
                || scalar.properties.isBidiControl {
                return "_"
            }
            return Character(scalar)
        }

        let filtered = String(filteredScalars)
        let collapsedWhitespace = filtered.replacingOccurrences(
            of: #"\s+"#,
            with: " ",
            options: .regularExpression
        )

        var withoutTraversalDots = collapsedWhitespace
        while withoutTraversalDots.contains("..") {
            withoutTraversalDots = withoutTraversalDots.replacingOccurrences(of: "..", with: "_")
        }

        let trimmedPunctuation = withoutTraversalDots
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ". "))

        let noLeadingDots = String(trimmedPunctuation.drop(while: { $0 == "." }))
        let normalized = noLeadingDots.isEmpty ? fallback : noLeadingDots
        let hasMeaningfulCharacters = normalized
            .replacingOccurrences(of: "_", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty == false
        guard hasMeaningfulCharacters else { return fallback }
        let result = String(normalized.prefix(120))
        guard result != "." && result != ".." else { return fallback }
        return result
    }
}
