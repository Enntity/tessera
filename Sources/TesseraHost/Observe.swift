import Foundation
import Observation

/// Calls `apply` with `value()` now, and again whenever anything `value` read changes. Changes made
/// within one pass of the main queue arrive as one call.
@MainActor
public func observe<T>(_ value: @escaping @MainActor () -> T, apply: @escaping @MainActor (T) -> Void) {
    let current = withObservationTracking(value) {
        DispatchQueue.main.async { MainActor.assumeIsolated { observe(value, apply: apply) } }
    }
    apply(current)
}
