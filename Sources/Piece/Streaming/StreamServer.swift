import Foundation
import Network

struct HTTPRequest {
    var method: String
    var path: String
    var headers: [String: String]

    /// Parses the head of an HTTP/1.1 request (everything before the blank line).
    init?(head: String) {
        let lines = head.components(separatedBy: "\r\n")
        let parts = lines.first?.split(separator: " ") ?? []
        guard parts.count >= 2 else { return nil }
        method = String(parts[0]).uppercased()
        path = String(parts[1])
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        self.headers = headers
    }

    /// Resolves a `Range` header against a resource of `size` bytes. Returns nil when unsatisfiable.
    static func byteRange(header: String?, size: Int64) -> ClosedRange<Int64>? {
        guard size > 0 else { return nil }
        guard let header, header.lowercased().hasPrefix("bytes=") else { return 0...(size - 1) }
        let spec = header.dropFirst(6).split(separator: ",").first.map(String.init) ?? ""
        let bounds = spec.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false).map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        guard bounds.count == 2 else { return nil }
        if bounds[0].isEmpty {
            guard let suffix = Int64(bounds[1]), suffix > 0 else { return nil }
            return max(0, size - suffix)...(size - 1)
        }
        guard let start = Int64(bounds[0]), start < size else { return nil }
        let end = bounds[1].isEmpty ? size - 1 : min(Int64(bounds[1]) ?? size - 1, size - 1)
        guard end >= start else { return nil }
        return start...end
    }
}

/// Small HTTP server that feeds AVPlayer, AirPlay receivers and ffmpeg.
///
/// - `/<token>/t/<hash>/<file>/<name>` streams a file from a torrent, waiting for (and
///   prioritising) pieces that haven't arrived yet.
/// - `/<token>/h/<session>/<name>` serves files from an HLS session directory.
final class StreamServer {
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "Piece.stream", attributes: .concurrent)
    private let lock = NSLock()
    private var hlsDirectories: [String: URL] = [:]
    private(set) var port: UInt16 = 0

    /// Unguessable path prefix, so other devices on the network can't browse the server.
    let token: String = (0..<16).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()

    let session: KTSession

    /// How far ahead of the read position pieces are requested.
    static let readAhead: Int64 = 24 * 1024 * 1024

    init(session: KTSession) {
        self.session = session
    }

    func start() {
        guard listener == nil else { return }
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        guard let listener = try? NWListener(using: parameters, on: .any) else { return }
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready, .failed, .cancelled: ready.signal()
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            connection.start(queue: self.queue)
            Thread.detachNewThread { self.serve(connection) }
        }
        listener.start(queue: queue)
        _ = ready.wait(timeout: .now() + 3)
        port = listener.port?.rawValue ?? 0
        self.listener = listener
    }

    // MARK: - URLs

    /// Address AirPlay receivers can reach; loopback when the Mac has no network.
    private var host: String { NetworkInfo.primaryIPv4 ?? "127.0.0.1" }

    func torrentFileURL(hash: String, fileIndex: Int, name: String, loopback: Bool = false) -> URL {
        let safe = name.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(.init(charactersIn: "._-"))) ?? "file"
        return URL(string: "http://\(loopback ? "127.0.0.1" : host):\(port)/\(token)/t/\(hash)/\(fileIndex)/\(safe)")!
    }

    func hlsURL(sessionID: String, file: String) -> URL {
        URL(string: "http://\(host):\(port)/\(token)/h/\(sessionID)/\(file)")!
    }

    func registerHLS(id: String, directory: URL) {
        lock.lock(); hlsDirectories[id] = directory; lock.unlock()
    }

    func unregisterHLS(id: String) {
        lock.lock(); hlsDirectories[id] = nil; lock.unlock()
    }

    // MARK: - Connection handling

    private func serve(_ connection: NWConnection) {
        defer { connection.cancel() }
        guard let head = readHead(connection), let request = HTTPRequest(head: head) else { return }
        guard request.method == "GET" || request.method == "HEAD" else {
            sendStatus(connection, 405, "Method Not Allowed")
            return
        }
        // Nothing more is expected from the client, so a completed read means it hung up.
        let closed = ClosedFlag()
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1024) { _, _, isComplete, error in
            if isComplete || error != nil { closed.set() }
        }
        let path = request.path.split(separator: "?").first.map(String.init) ?? request.path
        let parts = path.split(separator: "/").map { String($0).removingPercentEncoding ?? String($0) }
        guard parts.count >= 4, parts[0] == token else {
            sendStatus(connection, 404, "Not Found")
            return
        }
        switch parts[1] {
        case "t":
            guard parts.count >= 4, let index = Int(parts[3]) else { return sendStatus(connection, 404, "Not Found") }
            serveTorrentFile(connection, request: request, hash: parts[2], fileIndex: index, closed: closed)
        case "h":
            serveHLS(connection, request: request, sessionID: parts[2], file: parts[3], closed: closed)
        default:
            sendStatus(connection, 404, "Not Found")
        }
    }

    private func readHead(_ connection: NWConnection) -> String? {
        var buffer = Data()
        let terminator = Data("\r\n\r\n".utf8)
        while buffer.count < 64 * 1024 {
            let semaphore = DispatchSemaphore(value: 0)
            var chunk: Data?
            var finished = false
            connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { data, _, isComplete, error in
                chunk = data
                finished = isComplete || error != nil
                semaphore.signal()
            }
            if semaphore.wait(timeout: .now() + 15) == .timedOut { return nil }
            if let chunk { buffer.append(chunk) }
            if let range = buffer.range(of: terminator) {
                return String(data: buffer[..<range.lowerBound], encoding: .utf8)
            }
            if finished { return nil }
        }
        return nil
    }

    @discardableResult
    private func send(_ connection: NWConnection, _ data: Data) -> Bool {
        let semaphore = DispatchSemaphore(value: 0)
        var ok = false
        connection.send(content: data, completion: .contentProcessed { error in
            ok = error == nil
            semaphore.signal()
        })
        if semaphore.wait(timeout: .now() + 60) == .timedOut { return false }
        return ok
    }

    private func sendStatus(_ connection: NWConnection, _ code: Int, _ text: String) {
        send(connection, Data("HTTP/1.1 \(code) \(text)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8))
    }

    private func sendHead(_ connection: NWConnection, status: String, headers: [(String, String)]) -> Bool {
        var text = "HTTP/1.1 \(status)\r\n"
        for (name, value) in headers { text += "\(name): \(value)\r\n" }
        text += "Connection: close\r\n\r\n"
        return send(connection, Data(text.utf8))
    }

    // MARK: - Torrent files

    private func serveTorrentFile(_ connection: NWConnection, request: HTTPRequest, hash: String, fileIndex: Int, closed: ClosedFlag) {
        guard let file = session.files(forTorrent: hash).first(where: { Int($0.index) == fileIndex }),
              let status = session.statuses().first(where: { $0.infoHash == hash }) else {
            return sendStatus(connection, 404, "Not Found")
        }
        let size = file.size
        guard let range = HTTPRequest.byteRange(header: request.headers["range"], size: size) else {
            _ = sendHead(connection, status: "416 Range Not Satisfiable", headers: [("Content-Range", "bytes */\(size)")])
            return
        }
        let partial = request.headers["range"] != nil
        var headers = [
            ("Content-Type", Self.contentType(for: file.path)),
            ("Accept-Ranges", "bytes"),
            ("Content-Length", String(range.count)),
        ]
        if partial { headers.append(("Content-Range", "bytes \(range.lowerBound)-\(range.upperBound)/\(size)")) }
        guard sendHead(connection, status: partial ? "206 Partial Content" : "200 OK", headers: headers),
              request.method == "GET" else { return }

        let path = (status.savePath as NSString).appendingPathComponent(file.path)
        let index = Int32(fileIndex)
        var handle: FileHandle?
        defer { try? handle?.close() }
        var position = range.lowerBound
        var lastPrioritized: Int64 = -1

        while position <= range.upperBound {
            if closed.isSet { return }

            // Keep the download window moving just ahead of the reader.
            if lastPrioritized < 0 || position - lastPrioritized > 2 * 1024 * 1024 {
                session.prioritizeTorrent(hash, file: index, offset: position, window: Self.readAhead)
                lastPrioritized = position
            }
            let available = session.contiguousBytes(inTorrent: hash, file: index, offset: position)
            if available <= 0 {
                Thread.sleep(forTimeInterval: 0.2)
                continue
            }
            if handle == nil { handle = FileHandle(forReadingAtPath: path) }
            guard let handle else {
                Thread.sleep(forTimeInterval: 0.2)
                continue
            }
            let length = Int(min(available, range.upperBound - position + 1, 256 * 1024))
            do {
                try handle.seek(toOffset: UInt64(position))
                guard let data = try handle.read(upToCount: length), !data.isEmpty else {
                    Thread.sleep(forTimeInterval: 0.2)
                    continue
                }
                guard send(connection, data) else { return }
                position += Int64(data.count)
            } catch {
                return
            }
        }
    }

    // MARK: - HLS

    private func serveHLS(_ connection: NWConnection, request: HTTPRequest, sessionID: String, file: String, closed: ClosedFlag) {
        lock.lock()
        let directory = hlsDirectories[sessionID]
        lock.unlock()
        guard let directory, !file.contains("/"), !file.contains("..") else {
            return sendStatus(connection, 404, "Not Found")
        }
        let url = directory.appendingPathComponent(file)
        // The player asks for the playlist before ffmpeg has written its first segment.
        var waited = 0.0
        while !FileManager.default.fileExists(atPath: url.path), waited < 90 {
            lock.lock()
            let alive = hlsDirectories[sessionID] != nil
            lock.unlock()
            if !alive { return }
            if closed.isSet { return }
            Thread.sleep(forTimeInterval: 0.25)
            waited += 0.25
        }
        guard let data = try? Data(contentsOf: url) else { return sendStatus(connection, 404, "Not Found") }
        // Receivers often fetch init segments and media with Range requests; answer them properly.
        let size = Int64(data.count)
        guard let range = HTTPRequest.byteRange(header: request.headers["range"], size: size) else {
            _ = sendHead(connection, status: "416 Range Not Satisfiable", headers: [("Content-Range", "bytes */\(size)")])
            return
        }
        let partial = request.headers["range"] != nil && size > 0
        var headers = [
            ("Content-Type", Self.contentType(for: file)),
            ("Accept-Ranges", "bytes"),
            ("Content-Length", String(size == 0 ? 0 : range.count)),
            ("Cache-Control", file.hasSuffix(".m3u8") ? "no-cache" : "max-age=3600"),
        ]
        if partial { headers.append(("Content-Range", "bytes \(range.lowerBound)-\(range.upperBound)/\(size)")) }
        guard sendHead(connection, status: partial ? "206 Partial Content" : "200 OK", headers: headers),
              request.method == "GET", size > 0 else { return }
        send(connection, partial ? data.subdata(in: Int(range.lowerBound)..<Int(range.upperBound) + 1) : data)
    }

    static func contentType(for path: String) -> String {
        switch (path as NSString).pathExtension.lowercased() {
        case "m3u8": "application/vnd.apple.mpegurl"
        case "mp4", "m4v", "m4s": "video/mp4"
        case "mov": "video/quicktime"
        case "mkv": "video/x-matroska"
        case "webm": "video/webm"
        case "avi": "video/x-msvideo"
        case "ts": "video/mp2t"
        case "vtt": "text/vtt"
        case "mp3": "audio/mpeg"
        case "m4a", "m4b": "audio/mp4"
        case "aac": "audio/aac"
        case "flac": "audio/flac"
        case "wav": "audio/wav"
        case "aiff", "aif": "audio/aiff"
        case "ogg", "oga", "opus": "audio/ogg"
        default: "application/octet-stream"
        }
    }
}

final class ClosedFlag {
    private let lock = NSLock()
    private var value = false

    var isSet: Bool {
        lock.lock(); defer { lock.unlock() }
        return value
    }

    func set() {
        lock.lock(); value = true; lock.unlock()
    }
}

enum NetworkInfo {
    /// Name of the interface macOS currently routes through (Wi-Fi or Ethernet), kept up to date as the network changes.
    private static let preferred = PreferredInterface()

    /// IPv4 address AirPlay receivers should use to reach this Mac: the active route's interface, skipping VPN and bridge
    /// interfaces, falling back to the first Ethernet/Wi-Fi style interface.
    static var primaryIPv4: String? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return nil }
        defer { freeifaddrs(list) }
        let wanted = preferred.name
        var byName: [String: String] = [:]
        var order: [String] = []
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let interface = pointer.pointee
            let flags = Int32(interface.ifa_flags)
            guard let address = interface.ifa_addr, address.pointee.sa_family == UInt8(AF_INET),
                  flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0,
                              NI_NUMERICHOST) == 0 else { continue }
            let ip = String(cString: host)
            if ip.hasPrefix("169.254.") { continue }
            let name = String(cString: interface.ifa_name)
            if byName[name] == nil { byName[name] = ip; order.append(name) }
        }
        if let wanted, let ip = byName[wanted] { return ip }
        // utun*/bridge*/awdl*/llw* are VPNs, VM bridges and AirDrop links that receivers can't reach.
        let usable = order.filter { !["utun", "bridge", "awdl", "llw", "ap", "gif", "stf", "anpi"].contains(where: $0.hasPrefix) }
        return (usable.first { $0.hasPrefix("en") } ?? usable.first).flatMap { byName[$0] }
    }
}

private final class PreferredInterface {
    private let monitor = NWPathMonitor()
    private let lock = NSLock()
    private var value: String?

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let name = path.availableInterfaces.first { $0.type == .wifi || $0.type == .wiredEthernet }?.name
            self.lock.lock(); self.value = name; self.lock.unlock()
        }
        monitor.start(queue: DispatchQueue(label: "Piece.network"))
    }

    var name: String? {
        lock.lock(); defer { lock.unlock() }
        return value
    }
}
