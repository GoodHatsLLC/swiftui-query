import AsyncAlgorithms

#if canImport(Synchronization)
  import Synchronization
#else
  import os
#endif

@dynamicMemberLookup
public final class Synchronized<Value>: Sendable {
  public init(_ value: consuming sending Value) {
    self.mut = .init(value)
  }

  private let mut: Mut<Value>

  public borrowing func withLock<Result, E>(
    _ body: (inout sending Value) throws(E) -> sending Result
  ) throws(E) -> sending Result where E: Error {
    do {
      return try mut.withLock(body)
    } catch let error {
      throw error
    }
  }

  @discardableResult
  public nonisolated func callAsFunction<T>(_ action: (inout Value) -> T) -> T {
    withLock { state in
      var s = state
      let it = action(&s)
      state = s
      return it
    }
  }
  private nonisolated func place<T: Sendable>(_ path: consuming WritableKeyPath<Value, T>, value: T)
  {
    self { [value] s in
      s[keyPath: path] = value
    }
  }
  private nonisolated func pick<T: Sendable>(_ path: consuming KeyPath<Value, T>) -> T {
    withLock(\.self)[keyPath: path]
  }

  public nonisolated subscript<T: Sendable>(dynamicMember keyPath: WritableKeyPath<Value, T>) -> T {
    get { pick(keyPath) }
    set { place(keyPath, value: newValue) }
  }

  public nonisolated subscript<T: Sendable>(dynamicMember keyPath: KeyPath<Value, T>) -> T {
    get { pick(keyPath) }
  }

  consuming public func consume<T: Sendable>(_ path: consuming WritableKeyPath<Value, T?>) -> T? {
    self { state in
      defer { state[keyPath: path] = nil }
      return state[keyPath: path]
    }
  }
}


struct Mut<Value>: Sendable, ~Copyable {
  #if canImport(Synchronization)
    let lock: Mutex<Value>
  #else
    let lock: OSAllocatedUnfairLock<Value>
  #endif
}

extension Mut {
  init(_ initialValue: consuming sending Value) {
    #if canImport(Synchronization)
      self.lock = Mutex(initialValue)
    #else
      self.lock = OSAllocatedUnfairLock(uncheckedState: initialValue)
    #endif
  }

  borrowing func withLock<Result, E>(
    _ body: (inout sending Value) throws(E) -> sending Result
  ) throws(E) -> sending Result where E: Error {
    do {
      #if canImport(Synchronization)
        return try lock.withLock { (v) -> Transferring<Result> in
          nonisolated(unsafe) var copy = v
          defer { v = copy }
          return try Transferring(body(&copy))
        }.value
      #else
        return try lock.withLockUnchecked { (v) -> Transferring<Result> in
          nonisolated(unsafe) var copy = v
          defer { v = copy }
          return try Transferring(body(&copy))
        }.value
      #endif
    } catch let error as E {
      throw error
    } catch {
      preconditionFailure("cannot occur")
    }
  }

  borrowing func withLockIfAvailable<Result, E>(
    _ body: (inout sending Value) throws(E) -> sending Result
  ) throws(E) -> sending Result? where E: Error {
    do {
      #if canImport(Synchronization)
        return try lock.withLockIfAvailable { (v) -> Transferring<Result> in
          nonisolated(unsafe) var copy = v
          defer { v = copy }
          return try Transferring(body(&copy))
        }?.value
      #else
        return try lock.withLockIfAvailableUnchecked { (v) -> Transferring<Result> in
          nonisolated(unsafe) var copy = v
          defer { v = copy }
          return try Transferring(body(&copy))
        }?.value
      #endif
    } catch let error as E {
      throw error
    } catch {
      preconditionFailure("cannot occur")
    }
  }
}
struct Transferring<T>: Sendable {
  nonisolated(unsafe) var value: T

  init(_ value: T) {
    self.value = value
  }
}
