


//
import Foundation
import Testing
@testable import Tokens


// LocalModelTransportTests — deterministic privacy boundary checks without a server


struct LocalModelTransportTests {
    @Test func configurationDisablesSharedNetworkState() {
        let configuration = LocalModelTransport.configuration()
        #expect(configuration.connectionProxyDictionary?.isEmpty == true)
        #expect(configuration.urlCredentialStorage == nil)
        #expect(configuration.httpCookieStorage == nil)
        #expect(!configuration.httpShouldSetCookies)
        #expect(configuration.httpCookieAcceptPolicy == .never)
        #expect(configuration.urlCache == nil)
        #expect(configuration.requestCachePolicy == .reloadIgnoringLocalCacheData)
        #expect(configuration.identifier == nil)

        // Each call obtains a fresh configuration, so one caller cannot relax the next caller's policy.
        configuration.httpShouldSetCookies = true
        #expect(!LocalModelTransport.configuration().httpShouldSetCookies)
    }

    @Test func allowedRequestsKeepTheirTimeoutMethodAndBody() throws {
        for (path, timeout) in [("/api/generate", 15.0), ("/api/tags", 3.0), ("/api/tags", 1.0)] {
            var request             = URLRequest(url: try #require(URL(string: "http://127.0.0.1:11434" + path)))
            request.timeoutInterval = timeout
            request.httpMethod      = path == "/api/generate" ? "POST" : "GET"
            request.httpBody        = path == "/api/generate" ? Data("{}".utf8) : nil
            let original            = request
            try LocalModelTransport.validate(request)
            #expect(request == original)
        }
    }

    @Test func invalidOriginsFailBeforeNetwork() async throws {
        let invalidURLs = [
            "https://127.0.0.1:11434/api/tags", "http://localhost:11434/api/tags",
            "http://127.0.0.2:11434/api/tags", "http://[::1]:11434/api/tags",
            "http://127.0.0.1:80/api/tags", "http://127.0.0.1/api/tags",
            "http://example.invalid:11434/api/tags", "http://127.0.0.1.example.invalid:11434/api/tags",
            "http://user@127.0.0.1:11434/api/tags", "http://user:password@127.0.0.1:11434/api/tags",
            "file:///tmp/api/tags"
        ]
        for address in invalidURLs {
            let request = URLRequest(url: try #require(URL(string: address)))
            await expectUnsupportedURL(request)
        }
        var missingURL = URLRequest(url: try #require(URL(string: "http://127.0.0.1:11434/api/tags")))
        missingURL.url = nil
        await expectUnsupportedURL(missingURL)
    }

    private func expectUnsupportedURL(_ request: URLRequest) async {
        do {
            _ = try await LocalModelTransport.data(for: request)
            Issue.record("Invalid endpoint unexpectedly reached the transport")
        } catch {
            /*
            Unsupported URL is produced by validation, before session creation. A DNS, connection or
            timeout error would reveal that the request crossed the boundary and fails this assertion.
            */
            #expect((error as? URLError)?.code == .unsupportedURL)
        }
    }

    @Test func redirectDelegateRejectsExternalAndLocalDestinations() throws {
        let source  = try #require(URL(string: "http://127.0.0.1:11434/api/tags"))
        let session = URLSession(configuration: LocalModelTransport.configuration())
        defer { session.invalidateAndCancel() }
        // Construct a suspended task only to supply URLSession's delegate signature. Never resume it.
        let task     = session.dataTask(with: source)
        let delegate = LocalOnlySession()
        for address in ["https://example.invalid/api/tags", "http://127.0.0.1:11434/api/generate"] {
            let destination = try #require(URL(string: address))
            for code in [301, 302, 303, 307, 308] {
                let response = try #require(HTTPURLResponse(url: source, statusCode: code,
                    httpVersion: "HTTP/1.1", headerFields: ["Location": address]))
                var callbacks = 0
                delegate.urlSession(session, task: task, willPerformHTTPRedirection: response,
                                    newRequest: URLRequest(url: destination)) { redirectedRequest in
                    callbacks += 1
                    #expect(redirectedRequest == nil)
                }
                #expect(callbacks == 1)
            }
        }
    }
}

