import Foundation

/// The two app-wide tracker lists. A tracker can be in only one of them.
enum TrackerRule {
    /// Added to every transfer.
    case merge
    /// Removed from every transfer.
    case filter
}

/// What happened when a batch of trackers was added to a list.
struct TrackerImportResult {
    var added = 0
    var duplicates = 0
    var invalid = 0

    var summary: String {
        var parts: [String] = []
        if added > 0 { parts.append(added == 1 ? "Added 1 tracker" : "Added \(added) trackers") }
        if duplicates > 0 { parts.append("\(duplicates) already listed") }
        if invalid > 0 { parts.append(invalid == 1 ? "1 line wasn't a tracker" : "\(invalid) lines weren't trackers") }
        return parts.isEmpty ? "No trackers found" : parts.joined(separator: " · ")
    }
}

enum TrackerList {
    /// Two addresses that differ only in case, surrounding spaces or a trailing slash are the same tracker.
    /// Matches `trackerKey` in TorrentBridge.mm.
    static func key(_ url: String) -> String {
        var text = url.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasSuffix("/") { text.removeLast() }
        return text.lowercased()
    }

    static func isValid(_ url: String) -> Bool {
        guard let components = URLComponents(string: url),
              let scheme = components.scheme?.lowercased(), ["udp", "http", "https", "ws", "wss"].contains(scheme),
              let host = components.host, !host.isEmpty else { return false }
        return true
    }

    /// One tracker per line; `#` starts a comment and blank lines are skipped.
    static func parse(_ text: String) -> [String] {
        text.split(whereSeparator: \.isNewline).compactMap { line in
            let content = line.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
            let url = content.trimmingCharacters(in: .whitespaces)
            return url.isEmpty ? nil : url
        }
    }

    static func decode(_ data: Data) -> String {
        String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
    }

    /// Downloads a plain-text tracker list from an http(s) address.
    static func fetch(_ url: URL) async throws -> [String] {
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue(HTTP.userAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw URLError(.badServerResponse,
                           userInfo: [NSLocalizedDescriptionKey: "The server answered with status \(http.statusCode)."])
        }
        return parse(decode(data))
    }
}
