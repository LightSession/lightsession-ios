import XCTest
import zlib
@testable import LightSession

/// The latch and the wrapper, pinned separately from the senders that use them.
///
/// The rule under test is the handshake: nothing compresses until a response advertises
/// `X-LS-Accept-Encoding: gzip`, everything eligible compresses after, and the latch never
/// unlatches. Get the first half wrong and every batch 400s at an old server, spools, retries and
/// dies; get the last half wrong and a blip in a proxy turns compression off for the life of the
/// process with nothing logged.
final class CompressionTests: XCTestCase {

    override func setUp() {
        super.setUp()
        Compression.resetForTest()
    }

    override func tearDown() {
        Compression.resetForTest()
        super.tearDown()
    }

    /// A body that both clears [Compression.minBytes] and actually deflates: repetitive JSON, the
    /// shape the SDK really sends.
    private var bigBody: Data {
        Data(String(repeating: #"{"kind":"TEXT","l":16,"t":60,"r":304,"b":92},"#, count: 200).utf8)
    }

    private func request(body: Data?) -> URLRequest {
        var request = URLRequest(url: URL(string: "https://example.test/upload_batch")!)
        request.httpMethod = "POST"
        request.httpBody = body
        return request
    }

    private func advertisement(_ value: String?) -> HTTPURLResponse {
        HTTPURLResponse(
            url: URL(string: "https://example.test/upload_batch")!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: value.map { [Compression.advertisement: $0] }
        )!
    }

    /// Test-side inflate, so the roundtrip is proven against zlib itself rather than against the
    /// same code that compressed.
    private func gunzip(_ data: Data) -> Data? {
        var stream = z_stream()
        guard inflateInit2_(
            &stream, 31, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)
        ) == Z_OK else { return nil }
        defer { inflateEnd(&stream) }

        var input = data
        var output = Data()
        let chunkSize = 64 * 1024
        var chunk = [UInt8](repeating: 0, count: chunkSize)

        return input.withUnsafeMutableBytes { rawInput -> Data? in
            stream.next_in = rawInput.bindMemory(to: Bytef.self).baseAddress
            stream.avail_in = uInt(data.count)
            while true {
                var status: Int32 = Z_OK
                var produced = 0
                chunk.withUnsafeMutableBufferPointer { buffer in
                    stream.next_out = buffer.baseAddress
                    stream.avail_out = uInt(chunkSize)
                    status = inflate(&stream, Z_NO_FLUSH)
                    produced = chunkSize - Int(stream.avail_out)
                }
                if produced > 0 { output.append(contentsOf: chunk[0..<produced]) }
                if status == Z_STREAM_END { return output }
                guard status == Z_OK else { return nil }
            }
        }
    }

    func testNothingCompressesBeforeTheServerAdvertises() {
        let out = Compression.prepared(request(body: bigBody))
        XCTAssertEqual(out.httpBody, bigBody, "a plain first send is the handshake's cost")
        XCTAssertNil(out.value(forHTTPHeaderField: "Content-Encoding"))
    }

    func testTheAdvertisementFlipsTheLatchAndTheBodyRoundTrips() {
        Compression.noteResponse(advertisement("gzip"))
        XCTAssertTrue(Compression.serverAccepts)

        let out = Compression.prepared(request(body: bigBody))
        let sent = out.httpBody ?? Data()
        XCTAssertEqual(out.value(forHTTPHeaderField: "Content-Encoding"), "gzip")
        XCTAssertLessThan(sent.count, bigBody.count, "repetitive JSON must actually shrink")
        XCTAssertEqual([UInt8](sent.prefix(2)), [0x1f, 0x8b], "the gzip container, not bare deflate")
        XCTAssertEqual(gunzip(sent), bigBody, "the server must get back exactly what was sent")
    }

    func testAnAdvertisementWithoutGzipDoesNotLatch() {
        Compression.noteResponse(advertisement("br"))
        XCTAssertFalse(Compression.serverAccepts)
    }

    func testAResponseWithoutTheHeaderDoesNotLatch() {
        Compression.noteResponse(advertisement(nil))
        XCTAssertFalse(Compression.serverAccepts)
    }

    func testTheLatchNeverUnlatches() {
        Compression.noteResponse(advertisement("gzip"))
        Compression.noteResponse(advertisement(nil))
        XCTAssertTrue(
            Compression.serverAccepts,
            "a server that stopped advertising is indistinguishable from a proxy blip; "
                + "the deploy that removes the layer owns that outage"
        )
    }

    func testASmallBodyStaysPlain() {
        Compression.noteResponse(advertisement("gzip"))
        let small = Data(#"{"from":"Home","to":"Detail"}"#.utf8)
        let out = Compression.prepared(request(body: small))
        XCTAssertEqual(out.httpBody, small, "under the threshold the wrapper costs more than it saves")
        XCTAssertNil(out.value(forHTTPHeaderField: "Content-Encoding"))
    }

    func testABodyAlreadyEncodedIsLeftAlone() {
        Compression.noteResponse(advertisement("gzip"))
        var req = request(body: bigBody)
        req.setValue("identity", forHTTPHeaderField: "Content-Encoding")
        let out = Compression.prepared(req)
        XCTAssertEqual(out.httpBody, bigBody)
        XCTAssertEqual(out.value(forHTTPHeaderField: "Content-Encoding"), "identity")
    }
}
