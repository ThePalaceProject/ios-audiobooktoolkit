//
//  RangeResource.swift
//  PalaceAudiobookToolkit
//
//  Copyright © 2024 The Palace Project. All rights reserved.
//

import Foundation
import ReadiumShared

public class RangeResource: Resource {
    public let sourceURL: AbsoluteURL?
    private let httpClient: HTTPClient
    private var lengthCache: UInt64?

    init(sourceURL: AbsoluteURL, httpClient: HTTPClient) {
        self.sourceURL  = sourceURL
        self.httpClient = httpClient
    }

    /// HEAD via `stream(request:consume:)` with an empty consume.
    public func properties() async -> ReadResult<ResourceProperties> {
        guard let httpURL = sourceURL?.httpURL else {
            return .failure(.access(.other(NSError(domain: "InvalidURL", code: -1))))
        }
        let req = HTTPRequest(url: httpURL, method: .head)

        do {
            // consume: just drop any (empty) body chunks
            let response = try await httpClient
                .stream(request: req, consume: { _chunk, _progress in
                    .success(())    // always continue
                })
                .get()

            // Build ResourceProperties from HTTPResponse headers
            var props = ResourceProperties()
            if let len = response.contentLength {
                props["length"] = UInt64(len)
            }
            if let mt = response.mediaType {
                props.mediaType = mt
            }
            return .success(props)

        } catch {
            return .failure(.access(.other(error)))
        }
    }

    /// GET via `stream(request:consume:)`, accumulate into `data`.
    public func read(range: Range<UInt64>? = nil) async -> ReadResult<Data> {
        guard let httpURL = sourceURL?.httpURL else {
            return .failure(.access(.other(NSError(domain: "InvalidURL", code: -1))))
        }

        // Build Range header
        var headers = [String:String]()
        if let r = range {
            headers["Range"] = "bytes=\(r.lowerBound)-\(r.upperBound-1)"
        } else if let len = try? await getLength() {
            headers["Range"] = "bytes=0-\(len-1)"
        }

        let req = HTTPRequest(url: httpURL, method: .get, headers: headers)
        var byteBuffer = Data()

        do {
            let _ = try await httpClient
                .stream(request: req, consume: { chunk, _ in
                    byteBuffer.append(chunk)
                    return .success(())
                })
                .get()

            return .success(byteBuffer)

        } catch {
            return .failure(.access(.other(error)))
        }
    }

    public func stream(range: Range<UInt64>?, consume: @escaping (Data) -> Void) async -> ReadResult<Void> {
        let result = await read(range: range)
        switch result {
        case .success(let data):
            consume(data)
            return .success(())
        case .failure(let err):
            return .failure(err)
        }
    }

    /// HEAD‐backed length
    private func getLength() async throws -> UInt64 {
        if let cached = lengthCache { return cached }
        let props = try await properties().get()
        guard let l = props.properties["length"] as? UInt64 else {
            throw NSError(domain: "NoContentLength", code: -1)
        }
        lengthCache = l
        return l
    }

    public func estimatedLength() async -> ReadResult<UInt64?> {
        do {
            let l = try await getLength()
            return .success(l)
        } catch {
            return .failure(.access(.other(error)))
        }
    }
}
