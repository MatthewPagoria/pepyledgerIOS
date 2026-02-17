import Foundation
import Domain

public protocol SyncEndpointing {
  func pull() async throws -> SyncPullResult
  func mutate(_ mutation: SyncMutationRequest) async throws -> SyncMutationResult
  func push(snapshot: SyncSnapshot, replace: Bool) async throws -> SyncPushSnapshotResult
}

public enum SyncEndpointClientError: Error, Sendable {
  case invalidURL
  case transport(String)
  case decode(String)
}

private struct PullResponse: Decodable {
  let peptides: [JSONObject]?
  let vials: [JSONObject]?
  let oilBottles: [JSONObject]?
  let pillPacks: [JSONObject]?
  let doseLogs: [JSONObject]?
  let cycles: [JSONObject]?
  let scheduleRules: [JSONObject]?
  let dashboardNotes: [JSONObject]?
  let accountScope: AccountScopeMeta?
  let tombstones: [SyncTombstone]?
  let serverTimestamp: String?
}

private struct MutationResponse: Decodable {
  let ok: Bool?
  let errorCode: String?
  let error: String?
  let accountScope: AccountScopeMeta?
  let appliedAt: String?
}

private struct PushResponse: Decodable {
  let ok: Bool?
  let errorCode: String?
  let error: String?
  let replaceRequested: Bool?
  let mode: String?
  let accountScope: AccountScopeMeta?
}

private struct ErrorResponse: Decodable {
  let error: String?
  let errorCode: String?
}

public struct SyncEndpointClient: SyncEndpointing {
  public let baseURL: URL
  public let session: URLSession
  private let tokenProvider: @Sendable () async throws -> String

  public init(
    baseURL: URL,
    session: URLSession = .shared,
    tokenProvider: @escaping @Sendable () async throws -> String
  ) {
    self.baseURL = baseURL
    self.session = session
    self.tokenProvider = tokenProvider
  }

  public func pull() async throws -> SyncPullResult {
    let response: HTTPResponse<PullResponse> = try await post(path: "sync-pull", body: EmptyRequest())
    let payload = response.body ?? PullResponse(
      peptides: [],
      vials: [],
      oilBottles: [],
      pillPacks: [],
      doseLogs: [],
      cycles: [],
      scheduleRules: [],
      dashboardNotes: [],
      accountScope: nil,
      tombstones: [],
      serverTimestamp: nil
    )

    return SyncPullResult(
      snapshot: SyncSnapshot(
        peptides: payload.peptides ?? [],
        vials: payload.vials ?? [],
        oilBottles: payload.oilBottles ?? [],
        pillPacks: payload.pillPacks ?? [],
        doseLogs: payload.doseLogs ?? [],
        cycles: payload.cycles ?? [],
        scheduleRules: payload.scheduleRules ?? [],
        dashboardNotes: payload.dashboardNotes ?? []
      ),
      accountScope: payload.accountScope,
      tombstones: payload.tombstones ?? [],
      serverTimestamp: payload.serverTimestamp
    )
  }

  public func mutate(_ mutation: SyncMutationRequest) async throws -> SyncMutationResult {
    let response: HTTPResponse<MutationResponse> = try await post(path: "sync-mutate", body: mutation)
    return SyncMutationResult(
      ok: response.statusCode < 300 && (response.body?.ok ?? false),
      status: response.statusCode,
      errorCode: response.error?.errorCode ?? response.body?.errorCode,
      error: response.error?.error ?? response.body?.error,
      accountScope: response.body?.accountScope,
      appliedAt: response.body?.appliedAt
    )
  }

  public func push(snapshot: SyncSnapshot, replace: Bool) async throws -> SyncPushSnapshotResult {
    let request = PushRequest(snapshot: snapshot, replace: replace)
    let response: HTTPResponse<PushResponse> = try await post(path: "sync-push", body: request)
    return SyncPushSnapshotResult(
      ok: response.statusCode < 300 && (response.body?.ok ?? false),
      status: response.statusCode,
      errorCode: response.error?.errorCode ?? response.body?.errorCode,
      error: response.error?.error ?? response.body?.error,
      replaceRequested: response.body?.replaceRequested,
      mode: response.body?.mode,
      accountScope: response.body?.accountScope
    )
  }

  private func endpointURL(path: String) -> URL? {
    baseURL
      .appendingPathComponent("functions")
      .appendingPathComponent("v1")
      .appendingPathComponent(path)
  }

  private func post<RequestBody: Encodable, ResponseBody: Decodable>(
    path: String,
    body: RequestBody
  ) async throws -> HTTPResponse<ResponseBody> {
    guard let url = endpointURL(path: path) else {
      throw SyncEndpointClientError.invalidURL
    }

    let token = try await tokenProvider()
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

    let encoder = JSONEncoder()
    let decoder = JSONDecoder()

    do {
      request.httpBody = try encoder.encode(body)
    } catch {
      throw SyncEndpointClientError.decode(error.localizedDescription)
    }

    do {
      let (data, urlResponse) = try await session.data(for: request)
      guard let httpResponse = urlResponse as? HTTPURLResponse else {
        throw SyncEndpointClientError.transport("Non-HTTP response")
      }

      let decodedBody: ResponseBody?
      if data.isEmpty {
        decodedBody = nil
      } else {
        decodedBody = try? decoder.decode(ResponseBody.self, from: data)
      }

      let decodedError = try? decoder.decode(ErrorResponse.self, from: data)
      return HTTPResponse(
        statusCode: httpResponse.statusCode,
        body: decodedBody,
        error: decodedError
      )
    } catch {
      throw SyncEndpointClientError.transport(error.localizedDescription)
    }
  }
}

private struct HTTPResponse<Body: Decodable>: Sendable {
  let statusCode: Int
  let body: Body?
  let error: ErrorResponse?
}

private struct EmptyRequest: Encodable {}

private struct PushRequest: Encodable {
  let peptides: [JSONObject]
  let vials: [JSONObject]
  let oilBottles: [JSONObject]
  let pillPacks: [JSONObject]
  let doseLogs: [JSONObject]
  let cycles: [JSONObject]
  let scheduleRules: [JSONObject]
  let dashboardNotes: [JSONObject]
  let replace: Bool

  init(snapshot: SyncSnapshot, replace: Bool) {
    peptides = snapshot.peptides
    vials = snapshot.vials
    oilBottles = snapshot.oilBottles
    pillPacks = snapshot.pillPacks
    doseLogs = snapshot.doseLogs
    cycles = snapshot.cycles
    scheduleRules = snapshot.scheduleRules
    dashboardNotes = snapshot.dashboardNotes
    self.replace = replace
  }
}
