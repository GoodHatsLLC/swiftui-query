import Foundation
#if canImport(Observation)
import Observation
#endif

/// The status of a mutation
public enum MutationStatus: String, Sendable, Equatable {
    case idle
    case pending
    case success
    case error
}

/// Observable mutation state for SwiftUI integration.
///
/// Mutations are used for create/update/delete operations that modify server state.
/// Unlike queries, mutations:
/// - Are not cached
/// - Must be explicitly triggered
/// - Can invalidate related queries after completion
///
/// ```swift
/// @State private var createPost = MutationState<CreatePostInput, Post>(
///     mutationFn: api.createPost,
///     invalidateTags: [.posts]
/// )
///
/// Button("Create") {
///     Task {
///         try await createPost.mutate(input)
///     }
/// }
/// .disabled(createPost.isPending)
/// ```
#if canImport(Observation)
@Observable
#endif
@MainActor
public final class MutationState<Input: Sendable, Output: Sendable> {
    // MARK: - Core State
    
    /// The last successful mutation result
    public private(set) var data: Output?
    
    /// The last error, if any
    public private(set) var error: Error?
    
    /// The current status of the mutation
    public private(set) var status: MutationStatus = .idle
    
    /// The input variables of the current/last mutation (useful for optimistic UI)
    public private(set) var variables: Input?
    
    /// When the mutation was submitted
    public private(set) var submittedAt: Date?

    /// Bumped by `reset()` and each `mutate(_:)`. Lets a superseded in-flight
    /// mutation's late completion avoid clobbering reset/newer state (#16).
    private var generation = 0

    // MARK: - Derived State
    
    public var isIdle: Bool { status == .idle }
    public var isPending: Bool { status == .pending }
    public var isSuccess: Bool { status == .success }
    public var isError: Bool { status == .error }
    
    // MARK: - Configuration

    private let mutationFn: @MainActor (Input) async throws -> Output
    private let invalidateTags: [QueryTag]
    private let onMutate: (@MainActor (Input) async -> Any?)?
    private let onSuccess: (@MainActor (Output, Input) async -> Void)?
    private let onError: (@MainActor (Error, Input, Any?) async -> Void)?
    private let onSettled: (@MainActor (Output?, Error?, Input) async -> Void)?

    /// Optional name for this mutation (used in cycle detection diagnostics)
    public let name: String?

    /// The client used for cache invalidation after a mutation succeeds.
    ///
    /// If you configure invalidation tags, you must provide a client (either via
    /// SwiftUI environment injection or by initializing/attaching one manually).
    internal weak var client: QueryClient?

    // MARK: - Initialization

    public init(
        name: String? = nil,
        mutationFn: @escaping @MainActor (Input) async throws -> Output,
        invalidateTags: [QueryTag] = [],
        onMutate: (@MainActor (Input) async -> Any?)? = nil,
        onSuccess: (@MainActor (Output, Input) async -> Void)? = nil,
        onError: (@MainActor (Error, Input, Any?) async -> Void)? = nil,
        onSettled: (@MainActor (Output?, Error?, Input) async -> Void)? = nil,
        client: QueryClient? = nil
    ) {
        self.name = name
        self.mutationFn = mutationFn
        self.invalidateTags = invalidateTags
        self.onMutate = onMutate
        self.onSuccess = onSuccess
        self.onError = onError
        self.onSettled = onSettled
        self.client = client
    }
    
    // MARK: - Mutation Execution
    
    /// Execute the mutation with the given input
    @discardableResult
    public func mutate(_ input: Input) async throws -> Output {
        // Validate configuration up-front so a missing client fails BEFORE the
        // mutation runs, instead of throwing after it already succeeded and
        // corrupting onSettled (#14). Capture a strong reference so the client
        // can't vanish mid-mutation.
        let resolvedClient: QueryClient?
        if invalidateTags.isEmpty {
            resolvedClient = nil
        } else {
            guard let client else { throw MutationStateError.missingQueryClient }
            resolvedClient = client
        }

        // Mark this attempt; a reset() (or newer mutate) bumps `generation` so a
        // superseded late completion won't overwrite the observable state (#16).
        generation &+= 1
        let token = generation

        variables = input
        status = .pending
        submittedAt = Date()

        // onMutate callback (for optimistic updates, returns context for rollback)
        let context = await onMutate?(input)

        do {
            let result = try await mutationFn(input)

            if token == generation {
                data = result
                error = nil
                status = .success
            }

            // onSuccess callback
            await onSuccess?(result, input)

            // Invalidate related queries (with source tracking for cycle detection)
            let source = name ?? "MutationState<\(Input.self), \(Output.self)>"
            if let resolvedClient {
                for tag in invalidateTags {
                    await resolvedClient.invalidate(tag: tag, source: source)
                }
            }

            // onSettled callback
            await onSettled?(result, nil, input)

            return result
        } catch {
            if token == generation {
                self.error = error
                status = .error
            }

            // onError callback (with context for rollback)
            await onError?(error, input, context)

            // onSettled callback
            await onSettled?(nil, error, input)

            throw error
        }
    }

    /// Reset the mutation state
    public func reset() {
        // Supersede any in-flight mutation so its late completion can't restore
        // stale state after this reset (#16).
        generation &+= 1
        data = nil
        error = nil
        status = .idle
        variables = nil
        submittedAt = nil
    }

    internal func attach(client: QueryClient) {
        self.client = client
    }
}

public enum MutationStateError: Error, Sendable {
    case missingQueryClient
}

// MARK: - Convenience Initializers

extension MutationState where Input == Void {
    /// Convenience for mutations with no input
    public func mutate() async throws -> Output {
        try await mutate(())
    }
}

// MARK: - Mutation Builder

/// Builder for creating mutations with configuration
public struct MutationBuilder<Input: Sendable, Output: Sendable> {
    private var name: String?
    private var mutationFn: (@MainActor (Input) async throws -> Output)?
    private var invalidateTags: [QueryTag] = []
    private var onMutate: (@MainActor (Input) async -> Any?)?
    private var onSuccess: (@MainActor (Output, Input) async -> Void)?
    private var onError: (@MainActor (Error, Input, Any?) async -> Void)?
    private var onSettled: (@MainActor (Output?, Error?, Input) async -> Void)?
    private var client: QueryClient?

    public init() {}

    public func name(_ name: String) -> Self {
        var copy = self
        copy.name = name
        return copy
    }
    
    public func mutationFn(_ fn: @escaping @MainActor (Input) async throws -> Output) -> Self {
        var copy = self
        copy.mutationFn = fn
        return copy
    }
    
    public func invalidates(_ tags: QueryTag...) -> Self {
        var copy = self
        copy.invalidateTags = tags
        return copy
    }
    
    public func onMutate(_ handler: @escaping @MainActor (Input) async -> Any?) -> Self {
        var copy = self
        copy.onMutate = handler
        return copy
    }
    
    public func onSuccess(_ handler: @escaping @MainActor (Output, Input) async -> Void) -> Self {
        var copy = self
        copy.onSuccess = handler
        return copy
    }
    
    public func onError(_ handler: @escaping @MainActor (Error, Input, Any?) async -> Void) -> Self {
        var copy = self
        copy.onError = handler
        return copy
    }
    
    public func onSettled(_ handler: @escaping @MainActor (Output?, Error?, Input) async -> Void) -> Self {
        var copy = self
        copy.onSettled = handler
        return copy
    }

    public func client(_ client: QueryClient) -> Self {
        var copy = self
        copy.client = client
        return copy
    }
    
    @MainActor
    public func build() -> MutationState<Input, Output> {
        guard let mutationFn else {
            fatalError("MutationBuilder requires a mutationFn")
        }
        return MutationState(
            name: name,
            mutationFn: mutationFn,
            invalidateTags: invalidateTags,
            onMutate: onMutate,
            onSuccess: onSuccess,
            onError: onError,
            onSettled: onSettled,
            client: client
        )
    }
}
