import Foundation
import StrataSupport

/// Covers and document previews share one allowance. Archive listings and surveys before Extract have their own.
/// Cancellation drains the actual worker before returning its slot.
package actor ArchiveReadAllowance {
    package static let shared = ArchiveReadAllowance()
    package static let listings = ArchiveReadAllowance()
    package static let surveys = ArchiveReadAllowance()
    private let slots = WorkAllowance(limit: 2)
    package func enter(_ id: UUID) async throws { try await slots.enter(id) }
    package func cancel(_ id: UUID) async { await slots.cancel(id) }
    package func leave(_ id: UUID) async { await slots.leave(id) }
}
