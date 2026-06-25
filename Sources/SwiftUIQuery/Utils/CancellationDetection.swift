import Foundation

// MARK: - Cancellation Error Detection

extension Error {
    /// Returns true if this error represents a cancelled operation.
    ///
    /// Covers standard cancellation patterns:
    /// - Swift structured concurrency `CancellationError`
    /// - `URLError.cancelled` (URLSession cancellation, code -999)
    /// - `NSError` with `NSURLErrorDomain` and `NSURLErrorCancelled`
    var isCancellation: Bool {
        // Swift structured concurrency cancellation
        if self is CancellationError {
            return true
        }

        // URLSession cancellation (NSURLErrorCancelled = -999)
        if let urlError = self as? URLError, urlError.code == .cancelled {
            return true
        }

        // NSError domain check for URL errors bridged from Obj-C
        let nsError = self as NSError
        if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled {
            return true
        }

        return false
    }
}
