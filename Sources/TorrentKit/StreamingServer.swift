import Foundation
import Network

/// Serves a downloading file over HTTP on localhost, so a media player can
/// start watching before the download finishes.
///
/// The player asks for byte ranges; this maps each range onto the pieces
/// covering it, sets deadlines so libtorrent fetches those first, waits for
/// them to land, and streams the bytes back.
///
/// Built on `NWListener` rather than pulling in a web-server dependency: this
/// answers one kind of request on one local socket.
public actor StreamingServer {
    /// How long to wait for a piece before giving up on a request.
    private static let pieceTimeout = Duration.seconds(30)
    /// Deadline handed to libtorrent for pieces the player needs imminently.
    private static let urgentDeadline = Duration.milliseconds(700)
    /// Bytes per write. Large enough to be efficient, small enough that seeking
    /// does not wait on a huge chunk.
    private static let chunkSize = 256 * 1_024

    private let session: TorrentSession
    private var listener: NWListener?
    private var routes: [String: Route] = [:]

    private struct Route: Sendable {
        let infoHash: InfoHash
        let fileIndex: Int
        let name: String
    }

    public private(set) var port: UInt16 = 0

    public init(session: TorrentSession) {
        self.session = session
    }

    /// Starts listening on an ephemeral loopback port.
    public func start() throws {
        guard listener == nil else { return }
        let parameters = NWParameters.tcp
        // Loopback only: this serves local playback, not the network.
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        parameters.allowLocalEndpointReuse = true

        let listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in
            connection.start(queue: .global(qos: .userInitiated))
            Task { await self?.handle(connection) }
        }
        listener.stateUpdateHandler = { [weak self] state in
            guard case .ready = state else { return }
            Task { await self?.recordPort() }
        }
        listener.start(queue: .global(qos: .userInitiated))
        self.listener = listener
    }

    private func recordPort() {
        port = listener?.port?.rawValue ?? 0
    }

    public func stop() {
        listener?.cancel()
        listener = nil
        routes.removeAll()
        port = 0
    }

    /// Publishes a file for streaming and returns the URL to hand a player.
    public func url(forFileAt index: Int, in infoHash: InfoHash, name: String) -> URL? {
        guard port > 0 else { return nil }
        let token = "\(infoHash.value)-\(index)"
        routes[token] = Route(infoHash: infoHash, fileIndex: index, name: name)
        return URL(string: "http://127.0.0.1:\(port)/\(token)")
    }

    // MARK: - Request handling

    private func handle(_ connection: NWConnection) async {
        defer { connection.cancel() }
        guard let request = await readRequest(connection) else { return }

        guard let route = routes[request.token],
              let location = await session.locateFile(at: route.fileIndex, in: route.infoHash)
        else {
            await send(connection, status: "404 Not Found", headers: [:], body: Data())
            return
        }

        let total = location.size
        let requested = request.range ?? 0..<total
        let start = min(max(0, requested.lowerBound), max(0, total - 1))
        let end = min(requested.upperBound, total)
        guard end > start else {
            await send(connection, status: "416 Range Not Satisfiable",
                       headers: ["Content-Range": "bytes */\(total)"], body: Data())
            return
        }

        var headers = [
            "Content-Type": Self.mimeType(for: route.name),
            "Accept-Ranges": "bytes",
            "Content-Length": "\(end - start)",
            // VLC breaks if told keep-alive on a socket that closes per
            // request, which is exactly what this server does.
            "Connection": "close",
        ]
        if request.range != nil {
            headers["Content-Range"] = "bytes \(start)-\(end - 1)/\(total)"
        }

        await sendHeader(connection,
                         status: request.range != nil ? "206 Partial Content" : "200 OK",
                         headers: headers)
        if request.isHeadRequest { return }

        await streamBody(connection, route: route, location: location, from: start, to: end)
    }

    private func streamBody(
        _ connection: NWConnection, route: Route, location: FileLocation,
        from start: Int64, to end: Int64
    ) async {
        var cursor = start
        while cursor < end {
            let chunkEnd = min(cursor + Int64(Self.chunkSize), end)
            guard await waitForPieces(covering: cursor..<chunkEnd,
                                      route: route, location: location) else {
                return  // timed out; closing the socket tells the player
            }
            guard let data = Self.read(location.path, offset: cursor, count: Int(chunkEnd - cursor)),
                  await sendData(connection, data)
            else {
                return
            }
            cursor = chunkEnd
        }
    }

    /// Prioritises and then waits for the pieces covering `range`.
    private func waitForPieces(
        covering range: Range<Int64>, route: Route, location: FileLocation
    ) async -> Bool {
        let pieces = location.pieces(covering: range)
        let deadline = ContinuousClock.now.advanced(by: Self.pieceTimeout)

        while ContinuousClock.now < deadline {
            let availability = await session.pieceAvailability(of: route.infoHash)
            guard !availability.isEmpty else { return false }

            let missing = pieces.filter { $0 < availability.count && !availability[$0] }
            if missing.isEmpty { return true }

            // Ask for the missing ones soonest-first, so the piece the player
            // needs next outranks the one after it.
            for (position, piece) in missing.enumerated() {
                let urgency = Self.urgentDeadline * (position + 1)
                try? await session.setDeadline(urgency, forPiece: piece, in: route.infoHash)
            }
            try? await Task.sleep(for: .milliseconds(150))
        }
        return false
    }

    /// Reads a slice without mapping the whole file, which matters because the
    /// file is large and still being written.
    private static func read(_ path: String, offset: Int64, count: Int) -> Data? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: UInt64(offset))
            return try handle.read(upToCount: count)
        } catch {
            return nil
        }
    }

    static func mimeType(for name: String) -> String {
        switch (name as NSString).pathExtension.lowercased() {
        case "mp4", "m4v": return "video/mp4"
        case "mkv": return "video/x-matroska"
        case "avi": return "video/x-msvideo"
        case "mov": return "video/quicktime"
        case "webm": return "video/webm"
        case "ts": return "video/mp2t"
        case "mp3": return "audio/mpeg"
        case "flac": return "audio/flac"
        case "m4a": return "audio/mp4"
        default: return "application/octet-stream"
        }
    }

    // MARK: - Minimal HTTP

    struct Request {
        let token: String
        let range: Range<Int64>?
        let isHeadRequest: Bool
    }

    /// Parses just enough HTTP for a media player: the method, the path, and a
    /// single Range header.
    static func parse(_ text: String) -> Request? {
        let lines = text.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else { return nil }

        let method = String(parts[0]).uppercased()
        guard method == "GET" || method == "HEAD" else { return nil }
        let token = String(parts[1].drop(while: { $0 == "/" }))
            .removingPercentEncoding ?? String(parts[1].dropFirst())

        var range: Range<Int64>?
        for line in lines.dropFirst() where line.lowercased().hasPrefix("range:") {
            let spec = line.dropFirst("range:".count)
                .trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: "bytes=", with: "")
            let bounds = spec.split(separator: "-", omittingEmptySubsequences: false)
            guard let lower = Int64(bounds.first ?? "") else { break }
            // An open-ended range means "to the end"; Int64.max is clamped to
            // the file size by the caller.
            let upper = bounds.count > 1 ? Int64(bounds[1]).map { $0 + 1 } : nil
            range = lower..<(upper ?? Int64.max)
            break
        }
        return Request(token: token, range: range, isHeadRequest: method == "HEAD")
    }

    private func readRequest(_ connection: NWConnection) async -> Request? {
        await withCheckedContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1_024) {
                data, _, _, _ in
                guard let data, let text = String(data: data, encoding: .utf8) else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: Self.parse(text))
            }
        }
    }

    private func sendHeader(
        _ connection: NWConnection, status: String, headers: [String: String]
    ) async {
        var response = "HTTP/1.1 \(status)\r\n"
        for (key, value) in headers.sorted(by: { $0.key < $1.key }) {
            response += "\(key): \(value)\r\n"
        }
        response += "\r\n"
        _ = await sendData(connection, Data(response.utf8))
    }

    private func send(
        _ connection: NWConnection, status: String, headers: [String: String], body: Data
    ) async {
        var allHeaders = headers
        allHeaders["Content-Length"] = "\(body.count)"
        allHeaders["Connection"] = "close"
        await sendHeader(connection, status: status, headers: allHeaders)
        if !body.isEmpty { _ = await sendData(connection, body) }
    }

    @discardableResult
    private func sendData(_ connection: NWConnection, _ data: Data) async -> Bool {
        await withCheckedContinuation { continuation in
            connection.send(content: data, completion: .contentProcessed { error in
                continuation.resume(returning: error == nil)
            })
        }
    }
}
