import Foundation
import Testing

@testable import TorrentKit

@Suite("Streaming")
struct StreamingTests {

    // MARK: - Request parsing

    @Test func parsesASimpleGet() throws {
        let request = try #require(StreamingServer.parse("GET /abc-0 HTTP/1.1\r\nHost: x\r\n\r\n"))
        #expect(request.token == "abc-0")
        #expect(request.range == nil)
        #expect(!request.isHeadRequest)
    }

    @Test func parsesAClosedRange() throws {
        let request = try #require(StreamingServer.parse(
            "GET /abc-0 HTTP/1.1\r\nRange: bytes=100-199\r\n\r\n"))
        // HTTP ranges are inclusive; ours are half-open.
        #expect(request.range == 100..<200)
    }

    @Test func parsesAnOpenEndedRange() throws {
        let request = try #require(StreamingServer.parse(
            "GET /abc-0 HTTP/1.1\r\nRange: bytes=500-\r\n\r\n"))
        #expect(request.range?.lowerBound == 500)
        #expect(request.range?.upperBound == Int64.max)
    }

    @Test func recognisesHeadRequests() throws {
        let request = try #require(StreamingServer.parse("HEAD /abc-0 HTTP/1.1\r\n\r\n"))
        #expect(request.isHeadRequest)
    }

    @Test func rejectsUnsupportedMethods() {
        #expect(StreamingServer.parse("POST /abc-0 HTTP/1.1\r\n\r\n") == nil)
        #expect(StreamingServer.parse("garbage") == nil)
    }

    @Test func mapsMediaExtensionsToMimeTypes() {
        #expect(StreamingServer.mimeType(for: "a.mp4") == "video/mp4")
        #expect(StreamingServer.mimeType(for: "a.mkv") == "video/x-matroska")
        #expect(StreamingServer.mimeType(for: "a.MP3") == "audio/mpeg")
        #expect(StreamingServer.mimeType(for: "a.bin") == "application/octet-stream")
    }

    // MARK: - Byte range to piece mapping

    @Test func mapsByteRangesOntoCoveringPieces() {
        // A file starting 1000 bytes into a torrent with 512-byte pieces, so
        // the file is not piece-aligned — the case that is easy to get wrong.
        let location = FileLocation(
            offset: 1_000, size: 2_000, pieceLength: 512,
            firstPiece: 1, lastPiece: 5, path: "/tmp/x")

        // File byte 0 is torrent byte 1000, inside piece 1 (bytes 512-1023).
        #expect(location.pieces(covering: 0..<1) == 1...1)
        // File bytes 0-99 are torrent bytes 1000-1099, which straddles the
        // boundary at 1024 — the case an offset-aware mapping has to get right,
        // and which a naive `byteOffset / pieceLength` would miss.
        #expect(location.pieces(covering: 0..<100) == 1...2)
        // File byte 24 is torrent byte 1024, the first byte of piece 2.
        #expect(location.pieces(covering: 24..<25) == 2...2)
        // Torrent bytes 1000-1599 span pieces 1, 2 and 3.
        #expect(location.pieces(covering: 0..<600) == 1...3)
        // Clamped to the file, so the range cannot run past its last piece.
        #expect(location.pieces(covering: 0..<10_000).upperBound <= 5)
    }

    // MARK: - End to end

    /// Serves a fully-downloaded file over HTTP and checks the bytes match,
    /// including a mid-file range request of the kind a player issues on seek.
    @Test(.timeLimit(.minutes(1)))
    func servesFileContentOverHTTP() async throws {
        let content = try LoopbackTransferTests.makeDirectory("stream-content")
        let work = try LoopbackTransferTests.makeDirectory("stream-work")
        defer {
            try? FileManager.default.removeItem(at: content)
            try? FileManager.default.removeItem(at: work)
        }

        let payload = LoopbackTransferTests.makePayload(bytes: 512 * 1_024)
        let mediaURL = content.appendingPathComponent("movie.mp4")
        try payload.write(to: mediaURL)

        let torrentURL = work.appendingPathComponent("movie.torrent")
        try TorrentEngine.createTorrentFile(
            describing: mediaURL, writingTo: torrentURL, pieceLength: 32_768)

        let session = try TorrentSession(configuration: LoopbackTransferTests.isolated)
        defer { Task { await session.shutdown() } }
        let hash = try await session.addTorrentFile(at: torrentURL, savePath: content)

        // Wait until every piece verifies, so the server is not racing a
        // download — that path is covered by the deadline logic separately.
        var ready = false
        for _ in 0..<60 {
            let pieces = await session.pieceAvailability(of: hash)
            if !pieces.isEmpty, pieces.allSatisfy({ $0 }) { ready = true; break }
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(ready, "seeded torrent never finished checking")

        let server = StreamingServer(session: session)
        try await server.start()

        var port: UInt16 = 0
        for _ in 0..<50 where port == 0 {
            port = await server.port
            if port == 0 { try await Task.sleep(for: .milliseconds(100)) }
        }
        #expect(port > 0, "server never bound a port")

        let url = try #require(await server.url(forFileAt: 0, in: hash, name: "movie.mp4"))
        defer { Task { await server.stop() } }

        // Whole file.
        let (whole, wholeResponse) = try await URLSession.shared.data(from: url)
        let http = try #require(wholeResponse as? HTTPURLResponse)
        #expect(http.statusCode == 200)
        #expect(http.value(forHTTPHeaderField: "Accept-Ranges") == "bytes")
        // VLC misbehaves on keep-alive when the socket closes per request.
        #expect(http.value(forHTTPHeaderField: "Connection")?.lowercased() == "close")
        #expect(whole == payload)

        // A mid-file range, as a player issues when seeking.
        var request = URLRequest(url: url)
        request.setValue("bytes=100000-100099", forHTTPHeaderField: "Range")
        let (slice, sliceResponse) = try await URLSession.shared.data(for: request)
        let sliceHTTP = try #require(sliceResponse as? HTTPURLResponse)
        #expect(sliceHTTP.statusCode == 206)
        #expect(sliceHTTP.value(forHTTPHeaderField: "Content-Range")
            == "bytes 100000-100099/\(payload.count)")
        #expect(slice == payload[100_000..<100_100])
    }

    @Test(.timeLimit(.minutes(1)))
    func returnsNotFoundForAnUnknownToken() async throws {
        let session = try TorrentSession(configuration: .offline)
        defer { Task { await session.shutdown() } }
        let server = StreamingServer(session: session)
        try await server.start()
        defer { Task { await server.stop() } }

        var port: UInt16 = 0
        for _ in 0..<50 where port == 0 {
            port = await server.port
            if port == 0 { try await Task.sleep(for: .milliseconds(100)) }
        }
        let url = try #require(URL(string: "http://127.0.0.1:\(port)/nope-0"))
        let (_, response) = try await URLSession.shared.data(from: url)
        #expect((response as? HTTPURLResponse)?.statusCode == 404)
    }
}
