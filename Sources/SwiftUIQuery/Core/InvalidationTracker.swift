import Foundation

/// Tracks invalidation chains to detect cyclical dependencies at runtime.
///
/// Cycles can occur when:
/// - Query A's refetch triggers a mutation that invalidates Query A
/// - Invalidating tag A triggers refetches whose success handlers invalidate tags that cascade back to A
/// - Complex chains: A → B → C → A
///
/// The tracker maintains a call stack of active invalidations and detects when
/// a tag or key is re-entered within the same invalidation chain.
@MainActor
final class InvalidationTracker: Sendable {

    // MARK: - Configuration

    /// Configuration for cycle detection behavior
    struct Configuration: Sendable {
        /// Maximum allowed invalidation depth before triggering a warning
        var maxDepth: Int

        /// Whether to throw an error when a cycle is detected (vs just logging)
        var throwOnCycle: Bool

        /// Whether to log cycle warnings
        var logWarnings: Bool

        /// Custom handler for cycle detection events
        var onCycleDetected: (@Sendable (CycleInfo) -> Void)?

        init(
            maxDepth: Int = 5,
            throwOnCycle: Bool = true,
            logWarnings: Bool = true,
            onCycleDetected: (@Sendable (CycleInfo) -> Void)? = nil
        ) {
            self.maxDepth = maxDepth
            self.throwOnCycle = throwOnCycle
            self.logWarnings = logWarnings
            self.onCycleDetected = onCycleDetected
        }

        static let `default` = Configuration()

        /// Strict mode: throws on cycles, lower depth limit
        static let strict = Configuration(
            maxDepth: 5,
            throwOnCycle: true,
            logWarnings: true
        )

        /// Permissive mode: only logs, higher depth limit
        static let permissive = Configuration(
            maxDepth: 20,
            throwOnCycle: false,
            logWarnings: true
        )
    }

    // MARK: - Types

    /// Information about a detected cycle
    struct CycleInfo: Sendable, CustomStringConvertible {
        /// The tag or key that was re-entered
        let trigger: String

        /// The full invalidation chain leading to the cycle
        let chain: [InvalidationEntry]

        /// Current depth when cycle was detected
        let depth: Int

        /// Timestamp of detection
        let detectedAt: Date

        var description: String {
            let chainStr = chain.map(\.description).joined(separator: " → ")
            return "Cycle detected: \(trigger) (depth: \(depth))\nChain: \(chainStr) → [\(trigger)]"
        }
    }

    /// An entry in the invalidation chain
    struct InvalidationEntry: Sendable, CustomStringConvertible {
        enum Kind: Sendable {
            case tag(QueryTag)
            case key(String)
        }

        let kind: Kind
        let timestamp: Date
        let source: String?

        var identifier: String {
            switch kind {
            case .tag(let tag): return "tag:\(tag.description)"
            case .key(let key): return "key:\(key)"
            }
        }

        var description: String {
            if let source {
                return "\(identifier) (from: \(source))"
            }
            return identifier
        }
    }

    /// Errors thrown by the tracker
    enum TrackerError: LocalizedError {
        case cycleDetected(CycleInfo)
        case maxDepthExceeded(depth: Int, maxDepth: Int, chain: [InvalidationEntry])

        var errorDescription: String? {
            switch self {
            case .cycleDetected(let info):
                return "Invalidation cycle detected: \(info.description)"
            case .maxDepthExceeded(let depth, let maxDepth, let chain):
                let chainStr = chain.suffix(5).map(\.description).joined(separator: " → ")
                return "Invalidation depth (\(depth)) exceeded maximum (\(maxDepth)). Recent chain: \(chainStr)"
            }
        }
    }

    // MARK: - State

    /// Current configuration
    var configuration: Configuration

    /// Instance stack backing the token-based `beginInvalidation`/`endInvalidation`
    /// API. Correct for sequential, single-task use; hardened against out-of-order
    /// completion via remove-by-identity in `endInvalidation`.
    private var instanceChain: [InvalidationEntry] = []
    private var instanceIdentifiers: Set<String> = []

    /// Per-invalidation-tree chain backing `withInvalidation`. Scoped with
    /// `@TaskLocal` so concurrent invalidations (which interleave on the MainActor
    /// across `await`s) each get their own chain — fixing the corruption where a
    /// shared stack leaked entries and then wedged all future invalidation (#1).
    /// It inherits into child tasks (real A→B→C cascades) but is isolated between
    /// sibling trees.
    private struct ChainState: Sendable {
        var entries: [InvalidationEntry] = []
        var identifiers: Set<String> = []
    }
    @TaskLocal private static var taskChain = ChainState()

    /// Statistics
    private var _stats = Stats()

    // MARK: - Combined views (instance stack ∪ task-local chain)

    private var combinedEntries: [InvalidationEntry] {
        instanceChain + Self.taskChain.entries
    }
    private var combinedIdentifiers: Set<String> {
        instanceIdentifiers.union(Self.taskChain.identifiers)
    }
    private var combinedDepth: Int {
        instanceChain.count + Self.taskChain.entries.count
    }

    /// Statistics about invalidation tracking
    struct Stats: Sendable {
        var totalInvalidations: Int = 0
        var cyclesDetected: Int = 0
        var maxDepthReached: Int = 0
        var depthExceededCount: Int = 0
    }

    var stats: Stats { _stats }

    // MARK: - Initialization

    init(configuration: Configuration = .default) {
        self.configuration = configuration
    }

    // MARK: - Public API

    /// Begin tracking an invalidation. Returns a token that must be used to end tracking.
    ///
    /// - Parameters:
    ///   - tag: The tag being invalidated
    ///   - source: Optional source identifier for debugging (e.g., "MutationState.createPost")
    /// - Returns: A token to pass to `endInvalidation`
    /// - Throws: `TrackerError.cycleDetected` if a cycle is detected and `throwOnCycle` is true
    @discardableResult
    func beginInvalidation(tag: QueryTag, source: String? = nil) throws -> InvalidationToken {
        try beginInvalidation(entry: InvalidationEntry(kind: .tag(tag), timestamp: Date(), source: source))
    }

    /// Begin tracking an invalidation by key.
    @discardableResult
    func beginInvalidation(key: String, source: String? = nil) throws -> InvalidationToken {
        try beginInvalidation(entry: InvalidationEntry(kind: .key(key), timestamp: Date(), source: source))
    }

    /// End tracking an invalidation.
    func endInvalidation(_ token: InvalidationToken) {
        guard !token.isNoOp else { return }

        // Remove the matching entry from anywhere in the stack so out-of-order
        // completion cannot leak entries (a token may not be on top).
        if let idx = instanceChain.lastIndex(where: { $0.identifier == token.identifier }) {
            instanceChain.remove(at: idx)
        }
        // Only drop the identifier once no entry with it remains.
        if !instanceChain.contains(where: { $0.identifier == token.identifier }) {
            instanceIdentifiers.remove(token.identifier)
        }
    }

    /// Execute a block within an invalidation tracking context.
    ///
    /// This is the preferred way to track invalidations as it ensures proper cleanup.
    func withInvalidation<T>(
        tag: QueryTag,
        source: String? = nil,
        operation: () async throws -> T
    ) async throws -> T {
        try await runTaskScoped(
            entry: InvalidationEntry(kind: .tag(tag), timestamp: Date(), source: source),
            operation: operation
        )
    }

    /// Execute a block within an invalidation tracking context (by key).
    func withInvalidation<T>(
        key: String,
        source: String? = nil,
        operation: () async throws -> T
    ) async throws -> T {
        try await runTaskScoped(
            entry: InvalidationEntry(kind: .key(key), timestamp: Date(), source: source),
            operation: operation
        )
    }

    /// Check if we're currently in an invalidation chain
    var isInvalidating: Bool {
        combinedDepth > 0
    }

    /// Current invalidation depth
    var currentDepth: Int {
        combinedDepth
    }

    /// Get the current invalidation chain (for debugging)
    var currentChain: [InvalidationEntry] {
        combinedEntries
    }

    /// Reset the tracker state (useful for testing).
    ///
    /// Clears the instance stack and statistics. The task-local chain used by
    /// `withInvalidation` is scope-based and unwinds automatically, so it is not
    /// (and need not be) cleared here.
    func reset() {
        instanceChain.removeAll()
        instanceIdentifiers.removeAll()
        _stats = Stats()
    }

    // MARK: - Private Implementation

    /// Token-API entry point: pushes onto the instance stack. Cycle/depth checks
    /// are evaluated against the combined (instance ∪ task-local) chain.
    private func beginInvalidation(entry: InvalidationEntry) throws -> InvalidationToken {
        _stats.totalInvalidations += 1

        let identifier = entry.identifier

        if combinedIdentifiers.contains(identifier) {
            let cycleInfo = CycleInfo(
                trigger: identifier,
                chain: combinedEntries,
                depth: combinedDepth,
                detectedAt: Date()
            )
            _stats.cyclesDetected += 1
            handleCycleDetected(cycleInfo)

            if configuration.throwOnCycle {
                throw TrackerError.cycleDetected(cycleInfo)
            }
            return InvalidationToken(identifier: identifier, isNoOp: true)
        }

        if combinedDepth >= configuration.maxDepth {
            _stats.depthExceededCount += 1
            let error = TrackerError.maxDepthExceeded(
                depth: combinedDepth + 1,
                maxDepth: configuration.maxDepth,
                chain: combinedEntries
            )
            if configuration.logWarnings {
                warn("⚠️ [SwiftUIQuery] \(error.localizedDescription)")
            }
            if configuration.throwOnCycle {
                throw error
            }
            return InvalidationToken(identifier: identifier, isNoOp: true)
        }

        instanceChain.append(entry)
        instanceIdentifiers.insert(identifier)

        if combinedDepth > _stats.maxDepthReached {
            _stats.maxDepthReached = combinedDepth
        }

        return InvalidationToken(identifier: identifier, isNoOp: false)
    }

    /// `withInvalidation` entry point: scopes the chain to the current task via
    /// `@TaskLocal`, so concurrent invalidation trees can't corrupt one another.
    private func runTaskScoped<T>(
        entry: InvalidationEntry,
        operation: () async throws -> T
    ) async throws -> T {
        _stats.totalInvalidations += 1

        let identifier = entry.identifier

        if combinedIdentifiers.contains(identifier) {
            let cycleInfo = CycleInfo(
                trigger: identifier,
                chain: combinedEntries,
                depth: combinedDepth,
                detectedAt: Date()
            )
            _stats.cyclesDetected += 1
            handleCycleDetected(cycleInfo)

            if configuration.throwOnCycle {
                throw TrackerError.cycleDetected(cycleInfo)
            }
            // Non-throwing: break the cycle by running without extending the chain.
            return try await operation()
        }

        if combinedDepth >= configuration.maxDepth {
            _stats.depthExceededCount += 1
            let error = TrackerError.maxDepthExceeded(
                depth: combinedDepth + 1,
                maxDepth: configuration.maxDepth,
                chain: combinedEntries
            )
            if configuration.logWarnings {
                warn("⚠️ [SwiftUIQuery] \(error.localizedDescription)")
            }
            if configuration.throwOnCycle {
                throw error
            }
            return try await operation()
        }

        var next = Self.taskChain
        next.entries.append(entry)
        next.identifiers.insert(identifier)

        let projectedDepth = instanceChain.count + next.entries.count
        if projectedDepth > _stats.maxDepthReached {
            _stats.maxDepthReached = projectedDepth
        }

        return try await Self.$taskChain.withValue(next) {
            try await operation()
        }
    }

    private func handleCycleDetected(_ info: CycleInfo) {
        if configuration.logWarnings {
          warn("⚠️ [SwiftUIQuery] Invalidation cycle. Chain(\(info.depth): \(info.chain.map(\.identifier).joined(separator: " → ")) → [\(info.trigger)]")
        }

        configuration.onCycleDetected?(info)
    }
}

// MARK: - Invalidation Token

/// Token returned by `beginInvalidation` to track the invalidation scope
struct InvalidationToken: Sendable {
    let identifier: String
    let isNoOp: Bool

    /// Whether this token represents a skipped invalidation (due to cycle/depth limit)
    var wasSkipped: Bool { isNoOp }
}
