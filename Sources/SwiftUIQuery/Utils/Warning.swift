#if canImport(os)
import os
#endif
import Foundation


@_transparent
@inlinable
public func warn(_ message: String, file: StaticString = #file, line: UInt = #line) {
  Warn.default.warning(message, fileID: file, line: line)
}

/// A type representing an issue reporter that emits "purple" runtime warnings and test failures.
///
/// Use `warn(...)` or ``Warn/default`` to emit one of these warnings.
public struct Warn: Sendable {

  /// An issue reporter that emits "purple" runtime warnings to Xcode and logs fault-level messages
  /// to the console.
  ///
  /// This is the default issue reporter. On non-Apple platforms it logs messages to `stderr`.
  /// During test runs it emits test failures, instead.
  ///
  /// If this issue reporter receives an expected issue, it will log an info-level message to the
  /// console, instead.
  public static let `default`: Self = Warn()

  #if canImport(os)
//    @UncheckedSendable
    #if canImport(Darwin)
      @_transparent
    #endif
  @usableFromInline var dso: UnsafeRawPointer { #dsohandle }
  #endif

  public func warning(
    _ message: @autoclosure () -> String?,
    fileID: StaticString = #file,
    line: UInt
  ) {
    #if canImport(os)
      let moduleName = String(
        Substring("\(fileID)".utf8.prefix(while: { $0 != UTF8.CodeUnit(ascii: "/") }))
      )
      var message = message() ?? ""
      os_log(
        .fault,
        dso: dso,
        log: OSLog(subsystem: "com.apple.runtime-issues", category: moduleName),
        "%@",
        "\("\(fileID):\(line): ")\(message)"
      )
    #else
      printError("\(fileID):\(line): \(message() ?? "")")
    #endif

  }
}
