


//
import Foundation


// LocalModelTransport — one validated request and one throwaway session per call


enum LocalModelTransport {
    /*
    Validate before constructing a session or starting a task. Keep the literal IPv4 address: accepting
    localhost, other loopback addresses or DNS names would weaken the single-runtime endpoint contract.
    */
    static func validate(_ request: URLRequest) throws {
        guard let url = request.url,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme == "http", components.host == "127.0.0.1", components.port == 11434,
              components.user == nil, components.password == nil else {
            throw URLError(.unsupportedURL)
        }
    }

    /*
    Ephemeral alone can still use in-memory cookies and credentials; explicitly disable both stores.
    No cache or proxy participates, even when the user's system networking preferences enable them.
    */
    static func configuration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        configuration.urlCredentialStorage = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return configuration
    }

    static func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try validate(request)
        let session = URLSession(configuration: configuration(), delegate: LocalOnlySession(), delegateQueue: nil)
        /*
        Each completed, failed or cancelled call releases its own session. Callers retain their request
        timeout and their status/JSON handling; transport does not turn a 3xx into a successful response.
        */
        defer { session.invalidateAndCancel() }
        return try await session.data(for: request)
    }
}


// LocalOnlySession — deny every redirect, including redirects back to the allowed origin


/*
A nil redirect request returns the original HTTP response to the caller without following Location.
This delegate has no mutable state and is safe for URLSession's delegate queue.
*/
final class LocalOnlySession: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

