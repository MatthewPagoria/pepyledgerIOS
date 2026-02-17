import Foundation
import GRDB
import Domain

public enum GRDBSyncStoreError: Error, Sendable {
  case missingEndpointClient
}

public final class GRDBSyncStore: SyncRepository {
  private let dbQueue: DatabaseQueue
  private let endpointClient: (any SyncEndpointing)?
  private let encoder = JSONEncoder()
  private let decoder = JSONDecoder()

  public init(path: String, endpointClient: (any SyncEndpointing)? = nil) throws {
    dbQueue = try DatabaseQueue(path: path)
    self.endpointClient = endpointClient
    try dbQueue.write { db in
      try installSchema(in: db)
    }
  }

  public func pull() async throws -> SyncPullResult {
    guard let endpointClient else { throw GRDBSyncStoreError.missingEndpointClient }
    let pullResult = try await endpointClient.pull()

    try await dbQueue.write { db in
      try db.inTransaction {
        try self.applyTombstones(pullResult.tombstones, in: db)
        try self.replaceRows(for: .peptides, rows: pullResult.snapshot.peptides, fallbackUpdatedAt: pullResult.serverTimestamp, in: db)
        try self.replaceRows(for: .vials, rows: pullResult.snapshot.vials, fallbackUpdatedAt: pullResult.serverTimestamp, in: db)
        try self.replaceRows(for: .oilBottles, rows: pullResult.snapshot.oilBottles, fallbackUpdatedAt: pullResult.serverTimestamp, in: db)
        try self.replaceRows(for: .pillPacks, rows: pullResult.snapshot.pillPacks, fallbackUpdatedAt: pullResult.serverTimestamp, in: db)
        try self.replaceRows(for: .doseLogs, rows: pullResult.snapshot.doseLogs, fallbackUpdatedAt: pullResult.serverTimestamp, in: db)
        try self.replaceRows(for: .cycles, rows: pullResult.snapshot.cycles, fallbackUpdatedAt: pullResult.serverTimestamp, in: db)
        try self.replaceRows(for: .scheduleRules, rows: pullResult.snapshot.scheduleRules, fallbackUpdatedAt: pullResult.serverTimestamp, in: db)
        try self.replaceRows(for: .dashboardNotes, rows: pullResult.snapshot.dashboardNotes, fallbackUpdatedAt: pullResult.serverTimestamp, in: db)
        return .commit
      }
    }

    return pullResult
  }

  public func pushSnapshot(_ snapshot: SyncSnapshot, replace: Bool) async throws -> SyncPushSnapshotResult {
    guard let endpointClient else { throw GRDBSyncStoreError.missingEndpointClient }
    return try await endpointClient.push(snapshot: snapshot, replace: replace)
  }

  @discardableResult
  public func enqueueMutation(
    entity: SyncEntity,
    op: SyncMutationOperation,
    recordId: String,
    payload: JSONObject?,
    clientMutationId: String?
  ) async throws -> SyncOutboxItem {
    let now = nowISO()
    let outboxRecord = OutboxRecord(
      id: UUID().uuidString.lowercased(),
      clientMutationId: clientMutationId ?? UUID().uuidString.lowercased(),
      entity: entity.rawValue,
      op: op.rawValue,
      recordId: recordId,
      payloadJson: try encodeJSONObject(payload),
      status: SyncOutboxStatus.pending.rawValue,
      attempts: 0,
      lastError: nil,
      nextAttemptAt: now,
      createdAt: now,
      updatedAt: now
    )

    try await dbQueue.write { db in
      try outboxRecord.insert(db)
    }

    return try toSyncOutboxItem(from: outboxRecord)
  }

  public func listOutboxItems(limit: Int) async throws -> [SyncOutboxItem] {
    let safeLimit = max(1, limit)
    let records = try await dbQueue.read { db in
      try OutboxRecord.fetchAll(
        db,
        sql: """
          SELECT *
          FROM sync_outbox
          ORDER BY created_at ASC
          LIMIT ?
        """,
        arguments: [safeLimit]
      )
    }
    return try records.map { try self.toSyncOutboxItem(from: $0) }
  }

  public func pushPendingMutations(maxBatch: Int) async throws -> SyncDrainResult {
    guard let endpointClient else { throw GRDBSyncStoreError.missingEndpointClient }
    try await resetStaleInFlightMutations(maxAgeSeconds: 45)

    var processedCount = 0
    var failedCount = 0
    var requiresFreshPull = false
    var accountScopeAmbiguous = false

    while processedCount < max(1, maxBatch) {
      let next = try await dbQueue.read { db in
        try self.nextReadyOutbox(in: db, nowIso: self.nowISO())
      }
      guard let next else { break }

      try await dbQueue.write { db in
        try self.markInFlight(id: next.id, nowIso: self.nowISO(), in: db)
      }

      let mutationRequest = try SyncMutationRequest(
        clientMutationId: next.clientMutationId,
        entity: parseSyncEntity(next.entity),
        op: parseMutationOperation(next.op),
        id: next.recordId,
        payload: try decodeJSONObject(next.payloadJson),
        clientTimestamp: next.createdAt
      )

      let result = try await endpointClient.mutate(mutationRequest)

      if result.ok {
        try await dbQueue.write { db in
          try OutboxRecord.deleteOne(db, key: next.id)
        }
        processedCount += 1
        continue
      }

      if result.errorCode == "STALE_MUTATION" {
        try await dbQueue.write { db in
          try OutboxRecord.deleteOne(db, key: next.id)
        }
        processedCount += 1
        requiresFreshPull = true
        continue
      }

      let nextAttempts = next.attempts + 1
      try await dbQueue.write { db in
        try self.markFailed(
          id: next.id,
          attempts: nextAttempts,
          lastError: result.error ?? result.errorCode ?? "Mutation failed",
          nowIso: self.nowISO(),
          in: db
        )
      }
      failedCount += 1

      if result.errorCode == "ACCOUNT_SCOPE_AMBIGUOUS" || result.accountScope?.ambiguous == true {
        accountScopeAmbiguous = true
        break
      }

      // Match web behavior: bail after first non-stale failure to avoid hammering the endpoint.
      break
    }

    return SyncDrainResult(
      processedCount: processedCount,
      failedCount: failedCount,
      requiresFreshPull: requiresFreshPull,
      accountScopeAmbiguous: accountScopeAmbiguous
    )
  }

  public func resetStaleInFlightMutations(maxAgeSeconds: TimeInterval) async throws {
    let cutoff = Date().addingTimeInterval(-max(0, maxAgeSeconds))
    let cutoffIso = isoFormatter.string(from: cutoff)
    let now = nowISO()

    try await dbQueue.write { db in
      try db.execute(
        sql: """
          UPDATE sync_outbox
          SET status = ?, last_error = COALESCE(last_error, ?), next_attempt_at = ?, updated_at = ?
          WHERE status = ? AND updated_at < ?
        """,
        arguments: [
          SyncOutboxStatus.failed.rawValue,
          "Timed out while in flight.",
          now,
          now,
          SyncOutboxStatus.inFlight.rawValue,
          cutoffIso,
        ]
      )
    }
  }

  public func clearAllForAccountSwitch() async throws {
    try await dbQueue.write { db in
      for table in EntityTable.allTableNames {
        try db.execute(sql: "DELETE FROM \(table)")
      }
      try db.execute(sql: "DELETE FROM sync_outbox")
      try db.execute(sql: "DELETE FROM sync_meta")
    }
  }

  private func installSchema(in db: Database) throws {
    for table in EntityTable.allTableNames {
      try db.create(table: table, ifNotExists: true) { t in
        t.column("id", .text).primaryKey()
        t.column("payload_json", .text).notNull()
        t.column("updated_at", .text).notNull()
      }
      try db.create(index: "idx_\(table)_updated_at", on: table, columns: ["updated_at"], ifNotExists: true)
    }

    try db.create(table: "sync_outbox", ifNotExists: true) { t in
      t.column("id", .text).primaryKey()
      t.column("client_mutation_id", .text).notNull().unique(onConflict: .ignore)
      t.column("entity", .text).notNull()
      t.column("op", .text).notNull()
      t.column("record_id", .text).notNull()
      t.column("payload_json", .text)
      t.column("status", .text).notNull()
      t.column("attempts", .integer).notNull().defaults(to: 0)
      t.column("last_error", .text)
      t.column("next_attempt_at", .text).notNull()
      t.column("created_at", .text).notNull()
      t.column("updated_at", .text).notNull()
    }
    try db.create(index: "idx_sync_outbox_status_next_attempt", on: "sync_outbox", columns: ["status", "next_attempt_at"], ifNotExists: true)
    try db.create(index: "idx_sync_outbox_created_at", on: "sync_outbox", columns: ["created_at"], ifNotExists: true)

    try db.create(table: "sync_meta", ifNotExists: true) { t in
      t.column("key", .text).primaryKey()
      t.column("value", .text).notNull()
      t.column("updated_at", .text).notNull()
    }
  }

  private func replaceRows(
    for entity: SyncEntity,
    rows: [JSONObject],
    fallbackUpdatedAt: String?,
    in db: Database
  ) throws {
    let table = EntityTable.tableName(for: entity)
    try db.execute(sql: "DELETE FROM \(table)")

    for row in rows {
      guard let id = recordID(from: row) else {
        throw SyncRepositoryError.malformedRecord("Missing id for entity \(entity.rawValue)")
      }

      try db.execute(
        sql: "INSERT OR REPLACE INTO \(table) (id, payload_json, updated_at) VALUES (?, ?, ?)",
        arguments: [
          id,
          try encodeJSONObject(row) ?? "{}",
          updatedAtForRow(row, fallback: fallbackUpdatedAt),
        ]
      )
    }
  }

  private func applyTombstones(_ tombstones: [SyncTombstone], in db: Database) throws {
    for tombstone in tombstones {
      let table = EntityTable.tableName(for: tombstone.entity)
      try db.execute(
        sql: "DELETE FROM \(table) WHERE id = ?",
        arguments: [tombstone.id]
      )
    }
  }

  private func nextReadyOutbox(in db: Database, nowIso: String) throws -> OutboxRecord? {
    try OutboxRecord.fetchOne(
      db,
      sql: """
        SELECT *
        FROM sync_outbox
        WHERE status IN (?, ?) AND next_attempt_at <= ?
        ORDER BY created_at ASC
        LIMIT 1
      """,
      arguments: [SyncOutboxStatus.pending.rawValue, SyncOutboxStatus.failed.rawValue, nowIso]
    )
  }

  private func markInFlight(id: String, nowIso: String, in db: Database) throws {
    try db.execute(
      sql: "UPDATE sync_outbox SET status = ?, updated_at = ? WHERE id = ?",
      arguments: [SyncOutboxStatus.inFlight.rawValue, nowIso, id]
    )
  }

  private func markFailed(id: String, attempts: Int, lastError: String, nowIso: String, in db: Database) throws {
    let nextRetryAt = isoFormatter.string(from: Date().addingTimeInterval(backoffDelay(attempts: attempts)))
    try db.execute(
      sql: """
        UPDATE sync_outbox
        SET status = ?, attempts = ?, last_error = ?, next_attempt_at = ?, updated_at = ?
        WHERE id = ?
      """,
      arguments: [
        SyncOutboxStatus.failed.rawValue,
        attempts,
        lastError,
        nextRetryAt,
        nowIso,
        id,
      ]
    )
  }

  private func encodeJSONObject(_ object: JSONObject?) throws -> String? {
    guard let object else { return nil }
    let data = try encoder.encode(object)
    return String(data: data, encoding: .utf8)
  }

  private func decodeJSONObject(_ json: String?) throws -> JSONObject? {
    guard let json, !json.isEmpty else { return nil }
    guard let data = json.data(using: .utf8) else {
      throw SyncRepositoryError.malformedRecord("Invalid UTF-8 payload_json")
    }
    return try decoder.decode(JSONObject.self, from: data)
  }

  private func updatedAtForRow(_ row: JSONObject, fallback: String?) -> String {
    let keyCandidates = [
      "updatedAt",
      "updated_at",
      "createdAt",
      "created_at_iso",
      "takenAt",
      "openedAt",
      "startDate",
      "endDate",
    ]
    for key in keyCandidates {
      if let value = row[key]?.stringValue, !value.isEmpty {
        return value
      }
    }
    return fallback ?? nowISO()
  }

  private func recordID(from row: JSONObject) -> String? {
    if let id = row["id"]?.stringValue, !id.isEmpty {
      return id
    }
    if case let .number(number)? = row["id"] {
      return String(number)
    }
    return nil
  }

  private func toSyncOutboxItem(from record: OutboxRecord) throws -> SyncOutboxItem {
    SyncOutboxItem(
      id: record.id,
      clientMutationId: record.clientMutationId,
      entity: try parseSyncEntity(record.entity),
      op: try parseMutationOperation(record.op),
      recordId: record.recordId,
      payload: try decodeJSONObject(record.payloadJson),
      status: try parseOutboxStatus(record.status),
      attempts: record.attempts,
      lastError: record.lastError,
      nextAttemptAt: record.nextAttemptAt,
      createdAt: record.createdAt,
      updatedAt: record.updatedAt
    )
  }

  private func parseSyncEntity(_ value: String) throws -> SyncEntity {
    guard let entity = SyncEntity(rawValue: value) else {
      throw SyncRepositoryError.malformedRecord("Unsupported sync entity: \(value)")
    }
    return entity
  }

  private func parseMutationOperation(_ value: String) throws -> SyncMutationOperation {
    guard let operation = SyncMutationOperation(rawValue: value) else {
      throw SyncRepositoryError.malformedRecord("Unsupported sync operation: \(value)")
    }
    return operation
  }

  private func parseOutboxStatus(_ value: String) throws -> SyncOutboxStatus {
    guard let status = SyncOutboxStatus(rawValue: value) else {
      throw SyncRepositoryError.malformedRecord("Unsupported outbox status: \(value)")
    }
    return status
  }

  private func backoffDelay(attempts: Int) -> TimeInterval {
    let base: TimeInterval = 0.4
    let maxDelay: TimeInterval = 30
    return min(maxDelay, base * pow(2.0, Double(max(0, attempts))))
  }

  private func nowISO() -> String {
    isoFormatter.string(from: Date())
  }
}

private enum EntityTable {
  static func tableName(for entity: SyncEntity) -> String {
    switch entity {
    case .peptides:
      return "peptides"
    case .vials:
      return "vials"
    case .oilBottles:
      return "oil_bottles"
    case .pillPacks:
      return "pill_packs"
    case .doseLogs:
      return "dose_logs"
    case .cycles:
      return "cycles"
    case .scheduleRules:
      return "schedule_rules"
    case .dashboardNotes:
      return "dashboard_notes"
    }
  }

  static let allTableNames: [String] = SyncEntity.allCases.map(tableName(for:))
}

private struct OutboxRecord: FetchableRecord, PersistableRecord {
  static let databaseTableName = "sync_outbox"

  let id: String
  let clientMutationId: String
  let entity: String
  let op: String
  let recordId: String
  let payloadJson: String?
  let status: String
  let attempts: Int
  let lastError: String?
  let nextAttemptAt: String
  let createdAt: String
  let updatedAt: String

  init(
    id: String,
    clientMutationId: String,
    entity: String,
    op: String,
    recordId: String,
    payloadJson: String?,
    status: String,
    attempts: Int,
    lastError: String?,
    nextAttemptAt: String,
    createdAt: String,
    updatedAt: String
  ) {
    self.id = id
    self.clientMutationId = clientMutationId
    self.entity = entity
    self.op = op
    self.recordId = recordId
    self.payloadJson = payloadJson
    self.status = status
    self.attempts = attempts
    self.lastError = lastError
    self.nextAttemptAt = nextAttemptAt
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }

  enum Columns: String, ColumnExpression {
    case id = "id"
    case clientMutationId = "client_mutation_id"
    case entity = "entity"
    case op = "op"
    case recordId = "record_id"
    case payloadJson = "payload_json"
    case status = "status"
    case attempts = "attempts"
    case lastError = "last_error"
    case nextAttemptAt = "next_attempt_at"
    case createdAt = "created_at"
    case updatedAt = "updated_at"
  }

  init(row: Row) {
    id = row[Columns.id]
    clientMutationId = row[Columns.clientMutationId]
    entity = row[Columns.entity]
    op = row[Columns.op]
    recordId = row[Columns.recordId]
    payloadJson = row[Columns.payloadJson]
    status = row[Columns.status]
    attempts = row[Columns.attempts]
    lastError = row[Columns.lastError]
    nextAttemptAt = row[Columns.nextAttemptAt]
    createdAt = row[Columns.createdAt]
    updatedAt = row[Columns.updatedAt]
  }

  func encode(to container: inout PersistenceContainer) {
    container[Columns.id] = id
    container[Columns.clientMutationId] = clientMutationId
    container[Columns.entity] = entity
    container[Columns.op] = op
    container[Columns.recordId] = recordId
    container[Columns.payloadJson] = payloadJson
    container[Columns.status] = status
    container[Columns.attempts] = attempts
    container[Columns.lastError] = lastError
    container[Columns.nextAttemptAt] = nextAttemptAt
    container[Columns.createdAt] = createdAt
    container[Columns.updatedAt] = updatedAt
  }
}

private let isoFormatter: ISO8601DateFormatter = {
  let formatter = ISO8601DateFormatter()
  formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
  return formatter
}()
