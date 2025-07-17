import XCTest
import AVFoundation
import ReadiumShared
@testable import PalaceAudiobookToolkit

class LCPStreamingTests: XCTestCase {
    
    var mockHTTPClient: MockHTTPClient!
    var httpRangeRetriever: HTTPRangeRetriever!
    var mockDecryptor: MockDRMDecryptor!
    var mockPublication: Publication!
    
    override func setUp() {
        super.setUp()
        mockHTTPClient = MockHTTPClient()
        httpRangeRetriever = HTTPRangeRetriever(httpClient: mockHTTPClient)
        mockDecryptor = MockDRMDecryptor()
        let manifest = Manifest(metadata: Metadata(title: "fakeMetadata"))
        mockPublication = Publication(manifest: manifest)
    }
    
    override func tearDown() {
        super.tearDown()
    }
    
    // MARK: - HTTPRangeRetriever Tests
    
    func testHTTPRangeRetriever_SuccessfulRangeRequest() {
        let expectation = XCTestExpectation(description: "Range request completed")
        let testURL = HTTPURL(string: "https://example.com/test.mp3")!
        let testRange = 0..<1024
        let expectedData = Data(repeating: 0x41, count: 1024)
        
        // Setup mock fetch response
        let headers = ["Content-Length": "\(expectedData.count)"]
        let response = HTTPResponse(
            request: HTTPRequest(url: testURL, method: .get, headers: ["Range": "bytes=0-1023"]),
            url: testURL,
            status: .partialContent,
            headers: headers,
            mediaType: .mpegAudio,
            body: expectedData
        )
        mockHTTPClient.mockFetchResponse = .success(response)
        
        httpRangeRetriever.fetchRange(from: testURL, range: testRange) { result in
            switch result {
            case .success(let data):
                XCTAssertEqual(data, expectedData)
                XCTAssertEqual(data.count, 1024)
                expectation.fulfill()
            case .failure(let error):
                XCTFail("Range request failed: \(error)")
            }
        }
        
        wait(for: [expectation], timeout: 5.0)
        // Verify header on last fetch
        XCTAssertEqual(mockHTTPClient.lastFetchRequest?.headers["Range"], "bytes=0-1023")
    }
    
    func testHTTPRangeRetriever_CacheHit() {
        let expectation = XCTestExpectation(description: "Cached range request completed")
        let testURL = HTTPURL(string: "https://example.com/test.mp3")!
        let testRange = 0..<512
        let expectedData = Data(repeating: 0x42, count: 512)
        
        // First fetch
        let response = HTTPResponse(
            request: HTTPRequest(url: testURL, method: .get, headers: ["Range": "bytes=0-511"]),
            url: testURL,
            status: .partialContent,
            headers: ["Content-Length": "512"],
            mediaType: .mpegAudio,
            body: expectedData
        )
        mockHTTPClient.mockFetchResponse = .success(response)
        
        httpRangeRetriever.fetchRange(from: testURL, range: testRange) { _ in
            // Clear mock and count
            self.mockHTTPClient.mockFetchResponse = nil
            self.mockHTTPClient.fetchCount = 0
            
            self.httpRangeRetriever.fetchRange(from: testURL, range: testRange) { result in
                switch result {
                case .success(let data):
                    XCTAssertEqual(data, expectedData)
                    XCTAssertEqual(self.mockHTTPClient.fetchCount, 0)
                    expectation.fulfill()
                case .failure(let error):
                    XCTFail("Cached request failed: \(error)")
                }
            }
        }
        
        wait(for: [expectation], timeout: 5.0)
    }
    
    func testHTTPRangeRetriever_ContentLength() {
        let expectation = XCTestExpectation(description: "Content length request completed")
        let testURL = HTTPURL(string: "https://example.com/test.mp3")!
        let expectedLength = 1048576
        
        let response = HTTPResponse(
            request: HTTPRequest(url: testURL, method: .head),
            url: testURL,
            status: .ok,
            headers: ["Content-Length": "\(expectedLength)"],
            mediaType: .mpegAudio,
            body: nil
        )
        mockHTTPClient.mockFetchResponse = .success(response)
        
        httpRangeRetriever.getContentLength(for: testURL) { result in
            switch result {
            case .success(let length):
                XCTAssertEqual(length, expectedLength)
                expectation.fulfill()
            case .failure(let error):
                XCTFail("Content length request failed: \(error)")
            }
        }
        
        wait(for: [expectation], timeout: 5.0)
        XCTAssertEqual(mockHTTPClient.lastFetchRequest?.method, .head)
    }
}

// MARK: - Mock Classes

class MockHTTPClient: HTTPClient {
    var mockFetchResponse: HTTPResult<HTTPResponse>?
    var lastFetchRequest: HTTPRequest?
    var fetchCount = 0
    
    func stream(request: HTTPRequestConvertible, consume: @escaping (Data, Double?) -> HTTPResult<Void>) async -> HTTPResult<HTTPResponse> {
        // Not used in these tests
        return .failure(.other(NSError(domain: "", code: -1)))
    }
    func fetch(_ request: HTTPRequestConvertible) async -> HTTPResult<HTTPResponse> {
        if let httpReq = request as? HTTPRequest {
            lastFetchRequest = httpReq
        }
        fetchCount += 1
        return mockFetchResponse
            ?? .failure(.other(NSError(domain: "", code: -1)))
    }
}

class MockDRMDecryptor: DRMDecryptor {
    func decrypt(url: URL, to resultUrl: URL, completion: @escaping (Error?) -> Void) {
        completion(nil)
    }
}
