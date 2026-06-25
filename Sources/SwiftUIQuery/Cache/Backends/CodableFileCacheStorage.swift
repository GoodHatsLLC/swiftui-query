import Foundation

/// File-based ``CacheStorage`` that persists one Codable file per cache key.
///
/// Each record is stored at `<directory>/<sha256(cacheKey)>.json`. Hashing the
/// key avoids filesystem-illegal characters and path-length limits. Writes are
/// atomic (`Data.write(options: .atomic)` → write-aux-then-rename), so a crash
/// mid-write cannot leave a torn file at the real path.
///
/// This is a `struct` over a directory `URL`; it holds no mutable state. The
/// `QueryCache` actor serializes access within the process. **Cross-process use
/// is not supported** (no inter-process locking) — atomic renames prevent torn
/// reads but not lost updates.
///
/// Corruption handling: a file that fails to decode is treated as a cache miss
/// and removed, so the observer refetches and recovers.
struct CodableFileCacheStorage: CacheStorage {
    private let directory: URL

    // `FileManager.default` is the shared, thread-safe instance; not stored
    // because `FileManager` is not `Sendable`.
    private var fileManager: FileManager { .default }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()
    private static let decoder = JSONDecoder()

    init(directory: URL) throws {
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    // MARK: - File addressing

    private func fileURL(for key: String) -> URL {
        let name = Data(key.utf8).sha256Hash + ".json"
        return directory.appendingPathComponent(name)
    }

    /// Decode the record at `url`, deleting and reporting a miss on corruption.
    private func decodeRecord(at url: URL) -> CacheRecord? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        guard let record = try? Self.decoder.decode(CacheRecord.self, from: data) else {
            // Corrupt / partial file: treat as a miss and remove it.
            try? fileManager.removeItem(at: url)
            return nil
        }
        return record
    }

    /// Decode every record currently on disk (skipping unreadable files).
    private func allRecords() -> [(url: URL, record: CacheRecord)] {
        guard let urls = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ) else {
            return []
        }
        return urls
            .filter { $0.pathExtension == "json" }
            .compactMap { url in decodeRecord(at: url).map { (url, $0) } }
    }

    private func write(_ record: CacheRecord) throws {
        let data = try Self.encoder.encode(record)
        try data.write(to: fileURL(for: record.cacheKey), options: .atomic)
    }

    // MARK: - Reads

    public func read(key: String, now: Date) async throws -> CacheRecord? {
        guard let record = decodeRecord(at: fileURL(for: key)) else { return nil }
        return record.isExpired(at: now) ? nil : record
    }

    public func readIgnoringExpiry(key: String) async throws -> CacheRecord? {
        decodeRecord(at: fileURL(for: key))
    }

    public func exists(key: String, now: Date) async throws -> Bool {
        guard let record = decodeRecord(at: fileURL(for: key)) else { return false }
        return !record.isExpired(at: now)
    }

    // MARK: - Writes

    public func upsert(_ record: CacheRecord) async throws {
        var record = record
        if let existing = decodeRecord(at: fileURL(for: record.cacheKey)) {
            record.createdAt = existing.createdAt   // preserve original creation time
        }
        try write(record)
    }

    @discardableResult
    public func invalidate(tag: QueryTag, now: Date) async throws -> [String] {
        var matched: [String] = []
        for (_, record) in allRecords()
        where TagMatching.matches(tag: tag, tagSegments: record.tagSegments) {
            var updated = record
            updated.isInvalidated = true
            try write(updated)
            matched.append(record.cacheKey)   // include expired (fix #7)
        }
        return matched
    }

    public func markStale(key: String) async throws {
        guard var record = decodeRecord(at: fileURL(for: key)) else { return }
        record.isInvalidated = true
        try write(record)
    }

    public func remove(key: String) async throws {
        try? fileManager.removeItem(at: fileURL(for: key))
    }

    public func clear() async throws {
        for (url, _) in allRecords() {
            try? fileManager.removeItem(at: url)
        }
    }

    @discardableResult
    public func deleteExpired(now: Date) async throws -> [String] {
        var deleted: [String] = []
        for (url, record) in allRecords() where record.isExpired(at: now) {
            try? fileManager.removeItem(at: url)
            deleted.append(record.cacheKey)
        }
        return deleted
    }

    // MARK: - Stats

    public func statsCounts(now: Date) async throws -> CacheStorageCounts {
        let records = allRecords().map(\.record)
        return CacheStorageCounts(
            total: records.count,
            stale: records.filter { $0.isStale(at: now) }.count,
            expired: records.filter { $0.isExpired(at: now) }.count
        )
    }
}
