import Foundation

public enum SyncEntity: String, Codable, CaseIterable, Sendable {
  case peptides
  case vials
  case oilBottles
  case pillPacks
  case doseLogs
  case cycles
  case scheduleRules
  case dashboardNotes
}

public enum SyncMutationOperation: String, Codable, Sendable {
  case create
  case update
  case delete
}

public enum SyncOutboxStatus: String, Codable, Sendable {
  case pending
  case inFlight = "in_flight"
  case failed
}

public enum JSONValue: Codable, Sendable, Equatable {
  case string(String)
  case number(Double)
  case bool(Bool)
  case object([String: JSONValue])
  case array([JSONValue])
  case null

  public init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    if container.decodeNil() {
      self = .null
      return
    }
    if let value = try? container.decode(Bool.self) {
      self = .bool(value)
      return
    }
    if let value = try? container.decode(Double.self) {
      self = .number(value)
      return
    }
    if let value = try? container.decode(String.self) {
      self = .string(value)
      return
    }
    if let value = try? container.decode([String: JSONValue].self) {
      self = .object(value)
      return
    }
    if let value = try? container.decode([JSONValue].self) {
      self = .array(value)
      return
    }
    throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .string(let value):
      try container.encode(value)
    case .number(let value):
      try container.encode(value)
    case .bool(let value):
      try container.encode(value)
    case .object(let value):
      try container.encode(value)
    case .array(let value):
      try container.encode(value)
    case .null:
      try container.encodeNil()
    }
  }

  public var stringValue: String? {
    if case .string(let value) = self { return value }
    return nil
  }
}

public typealias JSONObject = [String: JSONValue]

public struct AccountScopeMeta: Codable, Sendable, Equatable {
  public let canonicalSub: String
  public let memberSubs: [String]
  public let normalizedEmail: String?
  public let consolidated: Bool
  public let ambiguous: Bool?
  public let ambiguityReason: String?

  public init(
    canonicalSub: String,
    memberSubs: [String],
    normalizedEmail: String?,
    consolidated: Bool,
    ambiguous: Bool?,
    ambiguityReason: String?
  ) {
    self.canonicalSub = canonicalSub
    self.memberSubs = memberSubs
    self.normalizedEmail = normalizedEmail
    self.consolidated = consolidated
    self.ambiguous = ambiguous
    self.ambiguityReason = ambiguityReason
  }
}

public struct SyncTombstone: Codable, Sendable, Equatable {
  public let entity: SyncEntity
  public let id: String
  public let deletedAt: String

  public init(entity: SyncEntity, id: String, deletedAt: String) {
    self.entity = entity
    self.id = id
    self.deletedAt = deletedAt
  }
}

public struct SyncSnapshot: Codable, Sendable, Equatable {
  public var peptides: [JSONObject]
  public var vials: [JSONObject]
  public var oilBottles: [JSONObject]
  public var pillPacks: [JSONObject]
  public var doseLogs: [JSONObject]
  public var cycles: [JSONObject]
  public var scheduleRules: [JSONObject]
  public var dashboardNotes: [JSONObject]

  public init(
    peptides: [JSONObject] = [],
    vials: [JSONObject] = [],
    oilBottles: [JSONObject] = [],
    pillPacks: [JSONObject] = [],
    doseLogs: [JSONObject] = [],
    cycles: [JSONObject] = [],
    scheduleRules: [JSONObject] = [],
    dashboardNotes: [JSONObject] = []
  ) {
    self.peptides = peptides
    self.vials = vials
    self.oilBottles = oilBottles
    self.pillPacks = pillPacks
    self.doseLogs = doseLogs
    self.cycles = cycles
    self.scheduleRules = scheduleRules
    self.dashboardNotes = dashboardNotes
  }
}

public struct SyncPullResult: Sendable {
  public let snapshot: SyncSnapshot
  public let accountScope: AccountScopeMeta?
  public let tombstones: [SyncTombstone]
  public let serverTimestamp: String?

  public init(
    snapshot: SyncSnapshot,
    accountScope: AccountScopeMeta?,
    tombstones: [SyncTombstone],
    serverTimestamp: String?
  ) {
    self.snapshot = snapshot
    self.accountScope = accountScope
    self.tombstones = tombstones
    self.serverTimestamp = serverTimestamp
  }
}

public struct SyncOutboxItem: Sendable, Equatable, Identifiable {
  public let id: String
  public let clientMutationId: String
  public let entity: SyncEntity
  public let op: SyncMutationOperation
  public let recordId: String
  public let payload: JSONObject?
  public let status: SyncOutboxStatus
  public let attempts: Int
  public let lastError: String?
  public let nextAttemptAt: String
  public let createdAt: String
  public let updatedAt: String

  public init(
    id: String,
    clientMutationId: String,
    entity: SyncEntity,
    op: SyncMutationOperation,
    recordId: String,
    payload: JSONObject?,
    status: SyncOutboxStatus,
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
    self.payload = payload
    self.status = status
    self.attempts = attempts
    self.lastError = lastError
    self.nextAttemptAt = nextAttemptAt
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }
}

public struct SyncMutationRequest: Codable, Sendable {
  public let clientMutationId: String
  public let entity: SyncEntity
  public let op: SyncMutationOperation
  public let id: String
  public let payload: JSONObject?
  public let clientTimestamp: String

  public init(
    clientMutationId: String,
    entity: SyncEntity,
    op: SyncMutationOperation,
    id: String,
    payload: JSONObject?,
    clientTimestamp: String
  ) {
    self.clientMutationId = clientMutationId
    self.entity = entity
    self.op = op
    self.id = id
    self.payload = payload
    self.clientTimestamp = clientTimestamp
  }
}

public struct SyncMutationResult: Sendable {
  public let ok: Bool
  public let status: Int?
  public let errorCode: String?
  public let error: String?
  public let accountScope: AccountScopeMeta?
  public let appliedAt: String?

  public init(
    ok: Bool,
    status: Int?,
    errorCode: String?,
    error: String?,
    accountScope: AccountScopeMeta?,
    appliedAt: String?
  ) {
    self.ok = ok
    self.status = status
    self.errorCode = errorCode
    self.error = error
    self.accountScope = accountScope
    self.appliedAt = appliedAt
  }
}

public struct SyncPushSnapshotResult: Sendable {
  public let ok: Bool
  public let status: Int?
  public let errorCode: String?
  public let error: String?
  public let replaceRequested: Bool?
  public let mode: String?
  public let accountScope: AccountScopeMeta?

  public init(
    ok: Bool,
    status: Int?,
    errorCode: String?,
    error: String?,
    replaceRequested: Bool?,
    mode: String?,
    accountScope: AccountScopeMeta?
  ) {
    self.ok = ok
    self.status = status
    self.errorCode = errorCode
    self.error = error
    self.replaceRequested = replaceRequested
    self.mode = mode
    self.accountScope = accountScope
  }
}

public struct SyncDrainResult: Sendable, Equatable {
  public let processedCount: Int
  public let failedCount: Int
  public let requiresFreshPull: Bool
  public let accountScopeAmbiguous: Bool

  public init(
    processedCount: Int,
    failedCount: Int,
    requiresFreshPull: Bool,
    accountScopeAmbiguous: Bool
  ) {
    self.processedCount = processedCount
    self.failedCount = failedCount
    self.requiresFreshPull = requiresFreshPull
    self.accountScopeAmbiguous = accountScopeAmbiguous
  }
}

public enum SyncRepositoryError: Error, Sendable {
  case malformedRecord(String)
  case accountScopeAmbiguous
  case invalidTimestamp(String)
}
