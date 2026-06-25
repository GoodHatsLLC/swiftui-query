import Foundation

/// Pure, backend-agnostic tag-matching logic shared by every ``CacheStorage``.
///
/// Lifting this out of the (formerly GRDB-bound) cache entry guarantees all
/// backends use exactly one matching primitive — the GRDB backend fetches
/// candidate rows and filters them in Swift here, never pushing matching into
/// SQL, identical to the previous behavior.
///
/// Public so out-of-module backends (e.g. `SwiftUIQueryGRDB`) reuse the exact
/// same matching and tag (de)serialization.
public enum TagMatching {
    /// True if `tag` is an ancestor (path-prefix) of any of the record's tags.
    ///
    /// This is the invalidation predicate: an invalidation `tag` matches a record
    /// when the tag is a prefix of one of the record's tag paths (parent → child
    /// cascade). Mirrors `Set<QueryTag>.containsMatch(for:)`.
    public static func matches(tag: QueryTag, tagSegments: [[String]]) -> Bool {
        tagSegments.contains { tag.matches(QueryTag(segments: $0)) }
    }

    /// Decode tag segments from the JSON representation persisted by backends.
    ///
    /// Tags are stored as a JSON array-of-arrays (`[["users"], ["users","123"]]`).
    /// A legacy flat string array (`["users","123"]`) is tolerated and treated as
    /// a set of single-segment tags, matching the historical `decodedTags` behavior.
    public static func decodeSegments(fromJSON json: String) -> [[String]] {
        guard let data = json.data(using: .utf8) else { return [] }

        if let nested = try? JSONDecoder().decode([[String]].self, from: data) {
            return nested.filter { !$0.isEmpty }
        }

        // Legacy compatibility: historical format stored a flat segment list.
        if let flat = try? JSONDecoder().decode([String].self, from: data) {
            return flat.filter { !$0.isEmpty }.map { [$0] }
        }

        return []
    }

    /// Encode tag segments to the deterministic JSON representation used for storage.
    ///
    /// Sorting matches `Set<QueryTag>.jsonEncoded` so payloads remain stable.
    public static func encodeSegments(_ segments: [[String]]) -> String {
        let normalized = segments.sorted { lhs, rhs in
            lhs.joined(separator: "\u{001F}") < rhs.joined(separator: "\u{001F}")
        }
        let data = try? JSONEncoder().encode(normalized)
        return data.flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
    }
}
