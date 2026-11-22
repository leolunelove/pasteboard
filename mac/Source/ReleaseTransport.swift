import Foundation

// A bounded, ephemeral HTTPS transfer. Redirects may only reach GitHub's own
// release CDN. No browser cookies or GitHub sign-in are needed for public assets.
final class ReleaseTransport: NSObject, URLSessionDataDelegate {
    private let limit: Int
    private var data = Data()
    private var failure: Error?
    private let finished = DispatchSemaphore(value: 0)
    private init(limit: Int) { self.limit = limit }
    static func trusted(_ url: URL) -> Bool {
        url.scheme == "https" && url.user == nil && url.password == nil
            && (url.port == nil || url.port == 443)
            && [
                "github.com", "release-assets.githubusercontent.com", "releases.githubusercontent.com",
                "objects.githubusercontent.com",
            ].contains(url.host?.lowercased() ?? "")
    }
    static func fetch(
        _ url: URL, maxBytes: Int, timeout: TimeInterval = 15,
        configuration: URLSessionConfiguration = .ephemeral
    ) throws -> Data {
        guard trusted(url), maxBytes > 0 else {
            throw LocalUpdater.error("This update address isn’t trusted.")
        }
        let transfer = ReleaseTransport(limit: maxBytes)
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = min(timeout, 30)
        configuration.timeoutIntervalForResource = timeout
        let session = URLSession(configuration: configuration, delegate: transfer, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url)
        request.setValue("Pasteboard-Mac-Updater", forHTTPHeaderField: "User-Agent")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
        session.dataTask(with: request).resume()
        guard transfer.finished.wait(timeout: .now() + timeout + 1) == .success else {
            throw URLError(.timedOut)
        }
        if let failure = transfer.failure { throw failure }
        return transfer.data
    }
    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let url = request.url, Self.trusted(url) else {
            failure = LocalUpdater.error("The update redirected outside GitHub. Your app is unchanged.")
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
    func urlSession(
        _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
            let url = response.url, Self.trusted(url), response.expectedContentLength <= limit
        else {
            failure = LocalUpdater.error(
                "The GitHub download is unavailable or exceeds its expected size. Please try again.")
            completionHandler(.cancel)
            return
        }
        completionHandler(.allow)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive bytes: Data) {
        guard data.count <= limit - bytes.count else {
            failure = LocalUpdater.error("The update download exceeds its expected size.")
            dataTask.cancel()
            return
        }
        data.append(bytes)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if failure == nil { failure = error }
        finished.signal()
    }
}
