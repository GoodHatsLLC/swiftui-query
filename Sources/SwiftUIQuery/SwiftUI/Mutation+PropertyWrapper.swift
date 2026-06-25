#if canImport(SwiftUI)
import SwiftUI

/// Property wrapper for declarative mutations in SwiftUI.
///
/// `@Mutation` provides a way to perform create/update/delete operations
/// with automatic cache invalidation.
///
/// ```swift
/// struct CreatePostView: View {
///     @Mutation(invalidates: .posts) { input, env in
///         _ = env
///         try await api.createPost(input)
///     } var createPost
///
///     var body: some View {
///         Button("Create") {
///             Task {
///                 try await createPost.mutate(CreatePostInput(title: title))
///             }
///         }
///         .disabled(createPost.isPending)
///     }
/// }
/// ```
@propertyWrapper
@MainActor
public struct Mutation<Input: Sendable, Output: Sendable, Context: Sendable>: @preconcurrency DynamicProperty {
    @Environment(\.queryClient) private var client
    @Environment(\.self) private var env
    @State private var state: MutationState<Input, Output, Context>
    @State private var environmentSnapshot: Synchronized<Transferring<EnvironmentValues>?>
    
    public init(
        invalidates tags: [QueryTag] = [],
        onMutate: (@MainActor (Input, EnvironmentValues) async -> Context)? = nil,
        onSuccess: (@MainActor (Output, Input, EnvironmentValues) async -> Void)? = nil,
        onError: (@MainActor (Error, Input, Context?, EnvironmentValues) async -> Void)? = nil,
        onSettled: (@MainActor (Output?, Error?, Input, EnvironmentValues) async -> Void)? = nil,
        mutationFn: @escaping @MainActor (Input, EnvironmentValues) async throws -> Output
    ) {
        let environmentSnapshot = Synchronized<Transferring<EnvironmentValues>?>(nil)
        @MainActor
        func currentEnvironment() -> EnvironmentValues {
            environmentSnapshot.withLock { $0 }?.value ?? EnvironmentValues()
        }

        let wrappedOnMutate: (@MainActor (Input) async -> Context)?
        if let onMutate {
            wrappedOnMutate = { input in
                await onMutate(input, currentEnvironment())
            }
        } else {
            wrappedOnMutate = nil
        }

        let wrappedOnSuccess: (@MainActor (Output, Input) async -> Void)?
        if let onSuccess {
            wrappedOnSuccess = { output, input in
                await onSuccess(output, input, currentEnvironment())
            }
        } else {
            wrappedOnSuccess = nil
        }

        let wrappedOnError: (@MainActor (Error, Input, Context?) async -> Void)?
        if let onError {
            wrappedOnError = { error, input, context in
                await onError(error, input, context, currentEnvironment())
            }
        } else {
            wrappedOnError = nil
        }

        let wrappedOnSettled: (@MainActor (Output?, Error?, Input) async -> Void)?
        if let onSettled {
            wrappedOnSettled = { output, error, input in
                await onSettled(output, error, input, currentEnvironment())
            }
        } else {
            wrappedOnSettled = nil
        }

        self._environmentSnapshot = State(initialValue: environmentSnapshot)
        self._state = State(
            initialValue: MutationState(
                mutationFn: { input in
                    guard let environment = environmentSnapshot.withLock({ $0 })?.value else {
                        throw MutationStateError.missingEnvironment
                    }
                    return try await mutationFn(input, environment)
                },
                invalidateTags: tags,
                onMutate: wrappedOnMutate,
                onSuccess: wrappedOnSuccess,
                onError: wrappedOnError,
                onSettled: wrappedOnSettled
            )
        )
    }
    
    public var wrappedValue: MutationState<Input, Output, Context> {
        state
    }
    
    public var projectedValue: MutationActions<Input, Output, Context> {
        MutationActions(state: state)
    }

    public func update() {
        environmentSnapshot.withLock { $0 = Transferring(env) }
        state.attach(client: client)
    }
}

extension Mutation where Context == Void {
    public init(
        invalidates tags: QueryTag...,
        mutationFn: @escaping @MainActor (Input, EnvironmentValues) async throws -> Output
    ) {
        self.init(invalidates: tags, mutationFn: mutationFn)
    }
}

// MARK: - Mutation Actions

/// Actions available via the projected value ($mutation)
@MainActor
public struct MutationActions<Input: Sendable, Output: Sendable, Context: Sendable> {
    fileprivate let state: MutationState<Input, Output, Context>

    public init(state: MutationState<Input, Output, Context>) {
        self.state = state
    }
    
    /// Execute the mutation
    @discardableResult
    public func mutate(_ input: Input) async throws -> Output {
        try await state.mutate(input)
    }
    
    /// Reset the mutation state
    public func reset() {
        state.reset()
    }
}

// MARK: - Void Input Convenience

extension Mutation where Input == Void, Context == Void {
    /// Initialize a mutation with no input
    public init(
        invalidates tags: QueryTag...,
        mutationFn: @escaping @MainActor (EnvironmentValues) async throws -> Output
    ) {
        self.init(invalidates: tags) { _, env in
            try await mutationFn(env)
        }
    }
}

extension MutationActions where Input == Void {
    /// Execute a mutation with no input
    @discardableResult
    public func mutate() async throws -> Output {
        try await state.mutate(())
    }
}
#endif
