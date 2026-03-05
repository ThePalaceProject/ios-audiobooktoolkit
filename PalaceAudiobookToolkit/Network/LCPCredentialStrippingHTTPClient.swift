//
//  LCPCredentialStrippingHTTPClient.swift
//  PalaceAudiobookToolkit
//
//  Copyright © 2024 The Palace Project. All rights reserved.
//
//  Strips credentials (cookies, Authorization) for requests to googleapis.com
//  so that LCP audiobook fetches to storage.googleapis.com do not receive
//  app credentials and avoid 401 errors (fulfillment spec: no credentials
//  required for storage.googleapis.com).
//

import Foundation
import ReadiumShared

/// HTTP client that uses an ephemeral session (no cookies, no credentials)
/// for requests to googleapis.com; delegates to the default client otherwise.
public final class LCPCredentialStrippingHTTPClient: HTTPClient, Loggable {
  private let defaultClient = DefaultHTTPClient()
  private let ephemeralClient = DefaultHTTPClient(ephemeral: true)

  public init() {}

  public func stream(
    request: any HTTPRequestConvertible,
    consume: @escaping (Data, Double?) -> HTTPResult<Void>
  ) async -> HTTPResult<HTTPResponse> {
    let reqResult = request.httpRequest()
    switch reqResult {
    case let .success(req):
      let host = req.url.url.host ?? ""
      if host.contains("googleapis.com") {
        log(.info, "LCP: using credential-free session for \(host) — \(req.url.string)")
        return await ephemeralClient.stream(request: req, consume: consume)
      }
      return await defaultClient.stream(request: request, consume: consume)
    case let .failure(error):
      return .failure(error)
    }
  }
}
