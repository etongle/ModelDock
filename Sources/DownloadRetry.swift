import Foundation

struct DownloadRetryStatus {
    var attempt: Int
    var limit: Int
    var delay: TimeInterval
}

enum DownloadRetryPolicy {
    static let delays: [TimeInterval] = [2, 4, 8, 16, 30]
    static func allows(_ error: Error) -> Bool {
        let value = error as NSError
        guard value.domain == NSURLErrorDomain else { return false }
        return [URLError.timedOut, .networkConnectionLost, .notConnectedToInternet,
                .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed].contains { $0.rawValue == value.code }
    }
}
