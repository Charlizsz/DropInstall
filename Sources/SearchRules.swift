import Foundation

struct ImageSearchRule: Identifiable, Codable, Equatable, Sendable {
    var id = UUID()
    var enabled = true
    var folderPattern: String
    var imagePattern: String

    static let defaults = [ImageSearchRule(folderPattern: "Manual Install", imagePattern: "*.dmg")]

    var isValid: Bool {
        [folderPattern, imagePattern].allSatisfy {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !$0.contains("/") && !$0.contains("\n") && $0.count <= 128
        }
    }

    /// Match one filename, not a path or regular expression. Only * and ? are special.
    static func matches(_ name: String, pattern: String) -> Bool {
        let escaped = NSRegularExpression.escapedPattern(for: pattern.trimmingCharacters(in: .whitespacesAndNewlines))
            .replacingOccurrences(of: "\\*", with: ".*")
            .replacingOccurrences(of: "\\?", with: ".")
        guard let expression = try? NSRegularExpression(pattern: "\\A" + escaped + "\\z", options: [.caseInsensitive]) else { return false }
        return expression.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)) != nil
    }
}

enum ImageSearchRuleStore {
    private static let key = "nestedImageSearchRules.v1"

    static func load(from preferences: UserDefaults = .standard) -> [ImageSearchRule] {
        guard let data = preferences.data(forKey: key),
              let rules = try? JSONDecoder().decode([ImageSearchRule].self, from: data) else { return ImageSearchRule.defaults }
        return rules.filter(\.isValid)
    }

    static func save(_ rules: [ImageSearchRule], to preferences: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(rules.filter(\.isValid)) else { return }
        preferences.set(data, forKey: key)
    }
}
