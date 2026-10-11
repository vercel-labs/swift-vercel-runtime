/// One outbound HTTP request made while handling a request, shown in Vercel's Observability under
/// External APIs.
///
/// The fields and their JSON names match the `fetch-metric` payload the Vercel functions runtime
/// decodes (as sent by the Node.js and Python runtimes).
package struct FetchMetric: Sendable, Hashable, Decodable {
    /// Increments per process, starting at 1.
    package var id: UInt64
    package var method: String
    package var host: String
    package var pathname: String
    /// The query string without the leading `?`, or an empty string.
    package var search: String
    package var statusCode: UInt16
    /// When the request started, in milliseconds since the Unix epoch.
    package var start: UInt64
    /// How long the request took, in milliseconds.
    package var duration: UInt64

    package init(
        id: UInt64,
        method: String,
        host: String,
        pathname: String,
        search: String,
        statusCode: UInt16,
        start: UInt64,
        duration: UInt64
    ) {
        self.id = id
        self.method = method
        self.host = host
        self.pathname = pathname
        self.search = search
        self.statusCode = statusCode
        self.start = start
        self.duration = duration
    }

    /// The runtime's `fetch-metric` payload, in the field order the Python runtime uses.
    package var json: String {
        #"{"pathname":\#(JSON.string(pathname)),"search":\#(JSON.string(search)),"start":\#(start),"duration":\#(duration),"host":\#(JSON.string(host)),"statusCode":\#(statusCode),"method":\#(JSON.string(method)),"id":\#(id)}"#
    }
}
