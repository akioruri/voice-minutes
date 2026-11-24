import Foundation

/// A named, reusable meeting-minutes prompt template kept in the user's
/// prompt library.
struct MinutesPrompt: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var name: String
    var body: String

    init(id: UUID = UUID(), name: String, body: String) {
        self.id = id
        self.name = name
        self.body = body
    }
}

/// Resolves which minutes prompt body applies to a meeting: folder override
/// → global default → built-in. IDs missing from the library fall through to
/// the next level, so a not-yet-synced assignment never breaks generation.
enum MinutesPromptResolver {
    static func body(
        folderPromptID: UUID?,
        defaultPromptID: UUID?,
        library: [MinutesPrompt],
        builtIn: String
    ) -> String {
        if let folderPromptID,
           let prompt = library.first(where: { $0.id == folderPromptID }) {
            return prompt.body
        }
        if let defaultPromptID,
           let prompt = library.first(where: { $0.id == defaultPromptID }) {
            return prompt.body
        }
        return builtIn
    }

    /// Returns a unique prompt name: the trimmed base (or fallback when
    /// empty), auto-suffixed " 2", " 3", … until it collides with no other
    /// entry. `excluding` lets a prompt keep its own name while renaming.
    static func uniqueName(
        _ base: String,
        in library: [MinutesPrompt],
        excluding id: UUID? = nil,
        fallback: String
    ) -> String {
        let trimmed = base.trimmingCharacters(in: .whitespacesAndNewlines)
        let root = trimmed.isEmpty ? fallback : trimmed
        let taken = Set(library.filter { $0.id != id }.map(\.name))
        if !taken.contains(root) {
            return root
        }
        var suffix = 2
        while taken.contains("\(root) \(suffix)") {
            suffix += 1
        }
        return "\(root) \(suffix)"
    }
}
