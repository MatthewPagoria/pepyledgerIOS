import XCTest
@testable import Data
import Domain

final class GRDBSyncStoreTests: XCTestCase {
  func testMutationFailureMarksOutboxFailedWithRetryBackoff() async throws {
    let endpoint = MockEndpoint()
    endpoint.mutateQueue = [
      .success(
        SyncMutationResult(
          ok: false,
          status: 400,
          errorCode: nil,
          error: "boom",
          accountScope: nil,
          appliedAt: nil
        )
      ),
    ]
    let store = try makeStore(endpoint: endpoint)

    _ = try await store.enqueueMutation(
      entity: .peptides,
      op: .update,
      recordId: "p1",
      payload: ["name": .string("A")],
      clientMutationId: "m1"
    )

    let drain = try await store.pushPendingMutations(maxBatch: 1)
    XCTAssertEqual(drain.processedCount, 0)
    XCTAssertEqual(drain.failedCount, 1)
    XCTAssertFalse(drain.requiresFreshPull)
    XCTAssertFalse(drain.accountScopeAmbiguous)

    let outbox = try await store.listOutboxItems(limit: 10)
    XCTAssertEqual(outbox.count, 1)
    let item = try XCTUnwrap(outbox.first)
    XCTAssertEqual(item.status, .failed)
    XCTAssertEqual(item.attempts, 1)
    XCTAssertEqual(item.lastError, "boom")
    XCTAssertGreaterThan(isoDate(item.nextAttemptAt), isoDate(item.createdAt))
  }

  func testStaleMutationAcknowledgesAndRequestsFreshPull() async throws {
    let endpoint = MockEndpoint()
    endpoint.mutateQueue = [
      .success(
        SyncMutationResult(
          ok: false,
          status: 409,
          errorCode: "STALE_MUTATION",
          error: "stale",
          accountScope: nil,
          appliedAt: nil
        )
      ),
    ]
    let store = try makeStore(endpoint: endpoint)

    _ = try await store.enqueueMutation(
      entity: .doseLogs,
      op: .update,
      recordId: "d1",
      payload: nil,
      clientMutationId: "m2"
    )

    let drain = try await store.pushPendingMutations(maxBatch: 1)
    XCTAssertEqual(drain.processedCount, 1)
    XCTAssertEqual(drain.failedCount, 0)
    XCTAssertTrue(drain.requiresFreshPull)
    XCTAssertFalse(drain.accountScopeAmbiguous)
    XCTAssertTrue(try await store.listOutboxItems(limit: 10).isEmpty)
  }

  func testAccountScopeAmbiguousStopsDrainAndLeavesLaterItemsPending() async throws {
    let endpoint = MockEndpoint()
    endpoint.mutateQueue = [
      .success(
        SyncMutationResult(
          ok: false,
          status: 409,
          errorCode: "ACCOUNT_SCOPE_AMBIGUOUS",
          error: "ambiguous",
          accountScope: AccountScopeMeta(
            canonicalSub: "auth0|1",
            memberSubs: ["auth0|1"],
            normalizedEmail: nil,
            consolidated: false,
            ambiguous: true,
            ambiguityReason: "too_many_member_subs"
          ),
          appliedAt: nil
        )
      ),
      .success(
        SyncMutationResult(
          ok: true,
          status: 200,
          errorCode: nil,
          error: nil,
          accountScope: nil,
          appliedAt: nowIso()
        )
      ),
    ]
    let store = try makeStore(endpoint: endpoint)

    _ = try await store.enqueueMutation(
      entity: .vials,
      op: .create,
      recordId: "v1",
      payload: nil,
      clientMutationId: "m3"
    )
    _ = try await store.enqueueMutation(
      entity: .vials,
      op: .update,
      recordId: "v2",
      payload: nil,
      clientMutationId: "m4"
    )

    let drain = try await store.pushPendingMutations(maxBatch: 10)
    XCTAssertEqual(drain.processedCount, 0)
    XCTAssertEqual(drain.failedCount, 1)
    XCTAssertFalse(drain.requiresFreshPull)
    XCTAssertTrue(drain.accountScopeAmbiguous)

    let outbox = try await store.listOutboxItems(limit: 10)
    XCTAssertEqual(outbox.count, 2)
    XCTAssertEqual(outbox[0].status, .failed)
    XCTAssertEqual(outbox[0].attempts, 1)
    XCTAssertEqual(outbox[1].status, .pending)
    XCTAssertEqual(outbox[1].attempts, 0)
  }

  func testResetStaleInFlightMutationsRecoversTimedOutItems() async throws {
    let endpoint = MockEndpoint()
    endpoint.mutateQueue = [.failure(MockError.transport)]
    let store = try makeStore(endpoint: endpoint)

    _ = try await store.enqueueMutation(
      entity: .cycles,
      op: .update,
      recordId: "c1",
      payload: nil,
      clientMutationId: "m5"
    )

    do {
      _ = try await store.pushPendingMutations(maxBatch: 1)
      XCTFail("Expected pushPendingMutations to throw")
    } catch {
      // Expected.
    }

    var outbox = try await store.listOutboxItems(limit: 10)
    XCTAssertEqual(outbox.count, 1)
    XCTAssertEqual(outbox[0].status, .inFlight)

    try await Task.sleep(nanoseconds: 20_000_000)
    try await store.resetStaleInFlightMutations(maxAgeSeconds: 0)

    outbox = try await store.listOutboxItems(limit: 10)
    XCTAssertEqual(outbox.count, 1)
    XCTAssertEqual(outbox[0].status, .failed)
    XCTAssertEqual(outbox[0].lastError, "Timed out while in flight.")
  }
}

private enum MockError: Error {
  case transport
}

private final class MockEndpoint: SyncEndpointing {
  var pullResult = SyncPullResult(
    snapshot: SyncSnapshot(),
    accountScope: nil,
    tombstones: [],
    serverTimestamp: nil
  )

  var mutateQueue: [Result<SyncMutationResult, Error>] = []

  var pushResult = SyncPushSnapshotResult(
    ok: true,
    status: 200,
    errorCode: nil,
    error: nil,
    replaceRequested: nil,
    mode: nil,
    accountScope: nil
  )

  func pull() async throws -> SyncPullResult {
    pullResult
  }

  func mutate(_ mutation: SyncMutationRequest) async throws -> SyncMutationResult {
    _ = mutation
    guard !mutateQueue.isEmpty else {
      return SyncMutationResult(
        ok: true,
        status: 200,
        errorCode: nil,
        error: nil,
        accountScope: nil,
        appliedAt: nowIso()
      )
    }
    let next = mutateQueue.removeFirst()
    return try next.get()
  }

  func push(snapshot: SyncSnapshot, replace: Bool) async throws -> SyncPushSnapshotResult {
    _ = snapshot
    _ = replace
    return pushResult
  }
}

private func makeStore(endpoint: any SyncEndpointing) throws -> GRDBSyncStore {
  let dbURL = FileManager.default.temporaryDirectory
    .appendingPathComponent("grdb-sync-store-\(UUID().uuidString.lowercased()).sqlite")
  return try GRDBSyncStore(path: dbURL.path, endpointClient: endpoint)
}

private func isoDate(_ value: String) -> Date {
  let formatter = ISO8601DateFormatter()
  formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
  if let parsed = formatter.date(from: value) {
    return parsed
  }
  XCTFail("Failed to parse ISO date: \(value)")
  return Date.distantPast
}

private func nowIso() -> String {
  let formatter = ISO8601DateFormatter()
  formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
  return formatter.string(from: Date())
}
