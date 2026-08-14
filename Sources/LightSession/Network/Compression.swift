import Foundation
import zlib

/// Compresses request bodies, once the server says it can take them.
///
/// ## What this buys, measured
///
/// Everything the SDK sends is text or masked flat-UI JPEG, and both deflate. The Android SDK
/// measured it off a real recording session at gzip's default level: a frame batch shrinks 37% —
/// the JPEGs inside are pictures of a masked, flat UI, whose entropy-coded stream still repeats —
/// a breadcrumb batch 87%, a skeleton send 63%. Over the whole session, 2.29 MB down to 1.22 MB:
/// 47% of the app's upstream bandwidth, which on a phone is also radio time and therefore battery.
/// The price there was 0.32 ms for a 26 KB batch, on threads already paying milliseconds for JPEG
/// and disk. Level 6 is the whole trade: 9 buys under one percent for up to half again the time.
///
/// ## Why the SDK asks first
///
/// A gzipped body at a server that does not decompress is not degradation, it is a hard parse
/// failure — every batch 400s, spools, retries and dies. So nothing is compressed until the server
/// *advertises*: every response from a service that can decompress carries
/// `X-LS-Accept-Encoding: gzip`, the first (always plain) send of the process reads it, and the
/// latch flips for good. An old server never says it and never receives gzip; a new SDK against it
/// costs exactly one uncompressed session, forever correct. No deploy order, no configuration flag
/// to forget.
///
/// The latch never unlatches. A server that advertised and then stopped decompressing is a
/// rollback across an incompatible boundary, and the SDK cannot tell it apart from a server that
/// is briefly unreachable — the deploy that removes the layer is the deploy that owns that outage.
///
/// ## What is left alone
///
/// Bodies under [minBytes]: a 139-byte flow send grows under gzip's header. Bodies already
/// carrying a `Content-Encoding`: they know something this module does not.
///
/// One seam, three callers. Android hangs this on an OkHttp interceptor because all its traffic
/// crosses one; this SDK's three senders each build their own `URLRequest`, so each hands it
/// through [prepared(_:)] on the way out and reports what came back through [noteResponse(_:)].
enum Compression {

    /// `X-LS-Accept-Encoding`, sent by servers whose request path decompresses.
    static let advertisement = "X-LS-Accept-Encoding"

    /// Below this, the gzip wrapper costs more than it saves: header plus trailer is ~23 bytes
    /// and small JSON barely deflates past its own noise.
    static let minBytes = 1_024

    /// Guards the latch: responses land on URLSession's queues, requests leave from wherever the
    /// caller was, and a torn read of a Bool is the kind of bug that reproduces never.
    private static let lock = NSLock()
    private static var latched = false

    /// Whether any response this process has seen advertised gzip.
    static var serverAccepts: Bool {
        lock.lock()
        defer { lock.unlock() }
        return latched
    }

    /// For tests. Production never lowers the latch.
    static func resetForTest() {
        lock.lock()
        defer { lock.unlock() }
        latched = false
    }

    /// Reads the advertisement off a response. Cheap when already latched: one lock, no parsing.
    static func noteResponse(_ response: URLResponse?) {
        guard !serverAccepts,
              let http = response as? HTTPURLResponse,
              let value = http.value(forHTTPHeaderField: advertisement),
              value.range(of: "gzip", options: .caseInsensitive) != nil
        else { return }
        lock.lock()
        defer { lock.unlock() }
        latched = true
    }

    /// The request as it should leave the device: compressed when the server can take it and the
    /// body is worth it, untouched otherwise. Never fails — a body gzip cannot handle goes out
    /// plain, which is always correct.
    static func prepared(_ request: URLRequest) -> URLRequest {
        guard serverAccepts,
              let body = request.httpBody,
              body.count >= minBytes,
              request.value(forHTTPHeaderField: "Content-Encoding") == nil,
              let squeezed = gzip(body)
        else { return request }

        var compressed = request
        compressed.httpBody = squeezed
        compressed.setValue("gzip", forHTTPHeaderField: "Content-Encoding")
        return compressed
    }

    /// One-shot gzip at level 6, via the zlib the SDK ships with the OS.
    ///
    /// `windowBits` 31 is 15 + 16, which is zlib's way of saying "the gzip container": the same
    /// deflate stream wrapped in the header and CRC the server's decompression layer expects.
    /// Sized with `deflateBound` so a single `deflate(Z_FINISH)` always fits — the bound is a few
    /// dozen bytes over the input for incompressible data, and these bodies are at most a few
    /// megabytes.
    static func gzip(_ data: Data, level: Int32 = 6) -> Data? {
        guard !data.isEmpty else { return nil }

        var stream = z_stream()
        guard deflateInit2_(
            &stream, level, Z_DEFLATED, 31, 8, Z_DEFAULT_STRATEGY,
            ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)
        ) == Z_OK else { return nil }
        defer { deflateEnd(&stream) }

        let bound = Int(deflateBound(&stream, uLong(data.count)))
        var input = data
        var output = Data(count: bound)

        let written: Int? = input.withUnsafeMutableBytes { rawInput -> Int? in
            output.withUnsafeMutableBytes { rawOutput -> Int? in
                guard let inputBase = rawInput.bindMemory(to: Bytef.self).baseAddress,
                      let outputBase = rawOutput.bindMemory(to: Bytef.self).baseAddress
                else { return nil }
                stream.next_in = inputBase
                stream.avail_in = uInt(data.count)
                stream.next_out = outputBase
                stream.avail_out = uInt(bound)
                guard deflate(&stream, Z_FINISH) == Z_STREAM_END else { return nil }
                return bound - Int(stream.avail_out)
            }
        }

        guard let written else { return nil }
        output.removeSubrange(written..<output.count)
        return output
    }
}
