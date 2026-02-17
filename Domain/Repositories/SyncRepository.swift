import Foundation

public protocol SyncRepository {
  func pull() async throws -> SyncPullResult
  func pushSnapshot(_ snapshot: SyncSnapshot, replace: Bool) async throws -> SyncPushSnapshotResult
  func enqueueMutation(
    entity: SyncEntity,
    op: SyncMutationOperation,
    recordId: String,
    payload: JSONObject?,
    clientMutationId: String?
  ) async throws -> SyncOutboxItem
  func listOutboxItems(limit: Int) async throws -> [SyncOutboxItem]
  func pushPendingMutations(maxBatch: Int) async throws -> SyncDrainResult
  func resetStaleInFlightMutations(maxAgeSeconds: TimeInterval) async throws
  func clearAllForAccountSwitch() async throws
}
