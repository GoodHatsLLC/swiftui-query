import AsyncAlgorithms
#if canImport(MachO)
import MachO
#endif
import Synchronization

/// Suspend until the current task context is cancelled, then execute the operation.
public func withCancellationOperation<T: Sendable>(
  isolation: isolated (any Actor)? = #isolation,
  operation: () async throws -> T
) async rethrows -> T {
  let didCancel = AwaitableBox<Void>()
  return try await withTaskCancellationHandler(
    operation: {
      _ = await didCancel()
      return try await operation()
    },
    onCancel: {
      try? didCancel.yield(())
    },
    isolation: isolation
  )
}

/// An eventual value, whose availability can be awaited.
///
/// - Can be awaited by multiple callers.
/// - Only one value can be yielded.
private final class AwaitableBox<Value: Sendable>: Identifiable, Hashable, Sendable {
  // MARK: Lifecycle

  init() {}

  // MARK: Public

  typealias Failure = Never
  struct AlreadyYielded: Error {
    let id: UUID
    let value: Value
  }

  let id: UUID = .init()

  static func == (lhs: AwaitableBox, rhs: AwaitableBox) -> Bool {
    lhs.id == rhs.id
  }

  func hash(into hasher: inout Hasher) {
    hasher.combine(id)
  }

  @discardableResult
  func callAsFunction() async -> Value {
    await withCheckedContinuation { c in
      continuations.withLock { state in
        switch state {
        case .yielded(let t):
          c.resume(returning: t)
        case .awaiting(let others):
          state = .awaiting(others + [c])
        }
      }
    }
  }

  /// Yield a value for the continuation to return when awaited.
  ///
  /// - parameter value: The value that will be returned when the continuation called and awaited.
  /// - throws: The continuation's value can only be yielded once. Subsequent attempts will throw.
  nonisolated func yield(_ value: Value) throws(AlreadyYielded) {
    let continuations = try continuations.withLock { state throws(AlreadyYielded) in
      switch state {
      case .yielded(let value):
        throw AlreadyYielded(id: id, value: value)
      case .awaiting(let array):
        state = .yielded(value)
        return array
      }
    }
    for continuation in continuations {
      continuation.resume(returning: value)
    }
  }

  // MARK: Internal

  enum State {
    case yielded(Value)
    case awaiting([CheckedContinuation<Value, Never>])
  }

  let continuations: Mut<State> = .init(.awaiting([]))
}

extension AwaitableBox where Value == Void {
  func yield() throws { try yield(()) }
}

extension AwaitableBox.AlreadyYielded: Sendable, CustomStringConvertible {
  var description: String {
    "Error awaiting \(AwaitableBox<Value>.self) which has already yielded '\(String(describing: value))'"
  }
}

extension AwaitableBox.AlreadyYielded: Equatable where Value: Equatable {}
extension AwaitableBox.AlreadyYielded: Hashable where Value: Hashable {}
