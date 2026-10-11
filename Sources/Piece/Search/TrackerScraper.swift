import Foundation
import Network

/// Asks a magnet link's UDP trackers (BEP 15) how many seeders and leechers each torrent has,
/// for sources whose listings don't include them.
enum TrackerScraper {
    private static let batchSize = 60
    private static let trackersPerRun = 4

    /// Fills `seeders` / `leechers` on results that lack them. Best effort: failures leave results untouched.
    static func fill(_ results: [SearchResult], timeout: TimeInterval = 4) async -> [SearchResult] {
        let wanted = results.filter { $0.seeders == nil && $0.infoHash != nil && $0.magnet != nil }
        guard !wanted.isEmpty else { return results }

        // The trackers most magnets list are the ones most likely to know about them.
        var votes: [String: Int] = [:]
        for result in wanted { for tracker in trackers(in: result.magnet ?? "") { votes[tracker, default: 0] += 1 } }
        let chosen = votes.sorted { $0.value > $1.value }.prefix(trackersPerRun).map(\.key)
        guard !chosen.isEmpty else { return results }

        let hashes = Array(Set(wanted.compactMap(\.infoHash)))
        var best: [String: (seeders: Int, leechers: Int)] = [:]
        await withTaskGroup(of: [String: (Int, Int)].self) { group in
            for tracker in chosen {
                for start in stride(from: 0, to: hashes.count, by: batchSize) {
                    let batch = Array(hashes[start..<min(start + batchSize, hashes.count)])
                    group.addTask { (try? await scrape(tracker: tracker, hashes: batch, timeout: timeout)) ?? [:] }
                }
            }
            for await found in group {
                for (hash, counts) in found where counts.0 >= (best[hash]?.seeders ?? -1) {
                    best[hash] = (counts.0, counts.1)
                }
            }
        }

        return results.map { result in
            guard result.seeders == nil, let hash = result.infoHash, let counts = best[hash] else { return result }
            var filled = result
            filled.seeders = counts.seeders
            filled.leechers = counts.leechers
            return filled
        }
    }

    static func trackers(in magnet: String) -> [String] {
        (URLComponents(string: magnet)?.queryItems ?? [])
            .filter { $0.name == "tr" }
            .compactMap(\.value)
            .filter { $0.lowercased().hasPrefix("udp://") }
    }

    // MARK: - Protocol

    private static func scrape(tracker: String, hashes: [String], timeout: TimeInterval) async throws -> [String: (Int, Int)] {
        guard let url = URL(string: tracker), let host = url.host, let port = url.port.flatMap({ NWEndpoint.Port(rawValue: UInt16($0)) })
        else { return [:] }
        let connection = NWConnection(host: .init(host), port: port, using: .udp)
        let socket = UDPExchange(connection)
        defer { connection.cancel() }

        // 1. Connect.
        let transaction1 = UInt32.random(in: 0...UInt32.max)
        var connect = Data()
        connect.append(be: UInt64(0x41727101980))
        connect.append(be: UInt32(0))
        connect.append(be: transaction1)
        let reply = try await socket.exchange(connect, timeout: timeout)
        guard reply.count >= 16, reply.u32(at: 0) == 0, reply.u32(at: 4) == transaction1 else { return [:] }
        let connectionID = reply.u64(at: 8)

        // 2. Scrape.
        let transaction2 = UInt32.random(in: 0...UInt32.max)
        var request = Data()
        request.append(be: connectionID)
        request.append(be: UInt32(2))
        request.append(be: transaction2)
        var ordered: [String] = []
        for hash in hashes {
            guard let bytes = hexBytes(hash) else { continue }
            request.append(contentsOf: bytes)
            ordered.append(hash)
        }
        let answer = try await socket.exchange(request, timeout: timeout)
        guard answer.count >= 8, answer.u32(at: 0) == 2, answer.u32(at: 4) == transaction2 else { return [:] }
        var out: [String: (Int, Int)] = [:]
        for (index, hash) in ordered.enumerated() {
            let offset = 8 + index * 12
            guard answer.count >= offset + 12 else { break }
            out[hash] = (Int(answer.u32(at: offset)), Int(answer.u32(at: offset + 8)))
        }
        return out
    }

    private static func hexBytes(_ hex: String) -> [UInt8]? {
        guard hex.count == 40 else { return nil }
        var bytes: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        return bytes
    }
}

/// One request/response round trip over a UDP connection.
private final class UDPExchange: @unchecked Sendable {
    private let connection: NWConnection
    private var started = false

    init(_ connection: NWConnection) { self.connection = connection }

    func exchange(_ payload: Data, timeout: TimeInterval) async throws -> Data {
        try await withThrowingTaskGroup(of: Data.self) { group in
            group.addTask { try await self.roundTrip(payload) }
            group.addTask {
                try await Task.sleep(for: .seconds(timeout))
                // Cancelling the socket fails the pending receive so the other child can finish.
                self.connection.cancel()
                throw URLError(.timedOut)
            }
            defer { group.cancelAll() }
            return try await group.next() ?? Data()
        }
    }

    private func roundTrip(_ payload: Data) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            let resume = Once(continuation)
            if !started {
                started = true
                connection.stateUpdateHandler = { state in
                    if case .failed(let error) = state { resume.fail(error) }
                }
                connection.start(queue: .global())
            }
            connection.send(content: payload, completion: .contentProcessed { error in
                if let error { resume.fail(error) }
            })
            connection.receiveMessage { data, _, _, error in
                if let data { resume.succeed(data) } else { resume.fail(error ?? URLError(.badServerResponse)) }
            }
        }
    }
}

private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Data, Error>?
    init(_ continuation: CheckedContinuation<Data, Error>) { self.continuation = continuation }

    func succeed(_ data: Data) { take()?.resume(returning: data) }
    func fail(_ error: Error) { take()?.resume(throwing: error) }
    private func take() -> CheckedContinuation<Data, Error>? {
        lock.lock(); defer { lock.unlock() }
        defer { continuation = nil }
        return continuation
    }
}

private extension Data {
    mutating func append<T: FixedWidthInteger>(be value: T) {
        Swift.withUnsafeBytes(of: value.bigEndian) { append(contentsOf: $0) }
    }
    func u32(at offset: Int) -> UInt32 {
        self[(startIndex + offset)..<(startIndex + offset + 4)].reduce(0) { $0 << 8 | UInt32($1) }
    }
    func u64(at offset: Int) -> UInt64 {
        self[(startIndex + offset)..<(startIndex + offset + 8)].reduce(0) { $0 << 8 | UInt64($1) }
    }
}
