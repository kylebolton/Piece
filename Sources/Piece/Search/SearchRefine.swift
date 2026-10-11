import Foundation

/// Sorting and filtering for torrent search results, kept apart from the view so it can be tested.
enum SearchSort: String, CaseIterable, Identifiable {
    case bestMatch = "Best Match", seeds = "Seeds", size = "Size", date = "Date Added", name = "Name", source = "Source"
    var id: String { rawValue }
}

enum SizeBand: String, CaseIterable, Identifiable {
    case any = "Any size", small = "Under 1 GB", medium = "1–5 GB", large = "5–20 GB", huge = "Over 20 GB"
    var id: String { rawValue }

    func contains(_ bytes: Int64?) -> Bool {
        guard self != .any else { return true }
        guard let bytes else { return false }
        let gb = Double(bytes) / 1_073_741_824
        switch self {
        case .any: return true
        case .small: return gb < 1
        case .medium: return gb >= 1 && gb < 5
        case .large: return gb >= 5 && gb < 20
        case .huge: return gb >= 20
        }
    }
}

enum Quality: String, CaseIterable, Identifiable {
    case uhd = "4K", fullHD = "1080p", hd = "720p", hdr = "HDR", hevc = "x265"
    var id: String { rawValue }
}

struct SearchFilter: Equatable {
    var minSeeds = 0
    var size = SizeBand.any
    var qualities: Set<Quality> = []
    var hideDuplicates = false

    var isActive: Bool { minSeeds > 0 || size != .any || !qualities.isEmpty || hideDuplicates }
}

extension SearchResult {
    var qualities: Set<Quality> {
        let lower = title.lowercased()
        var found: Set<Quality> = []
        if lower.contains("2160p") || lower.contains("4k") || lower.contains("uhd") { found.insert(.uhd) }
        if lower.contains("1080p") || lower.contains("1080i") { found.insert(.fullHD) }
        if lower.contains("720p") { found.insert(.hd) }
        if lower.contains("hdr") || lower.contains("dolby vision") || lower.contains("dovi") { found.insert(.hdr) }
        if lower.contains("x265") || lower.contains("h265") || lower.contains("h.265") || lower.contains("hevc") { found.insert(.hevc) }
        return found
    }

    /// How well this result answers `query`: every word must start a word in the title, an exact phrase counts
    /// for more, and seeders (log-scaled) break ties so dead torrents sink.
    func relevance(for query: String) -> Double {
        let words = query.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        let lower = title.lowercased()
        let tokens = lower.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        var score = 0.0
        if !words.isEmpty {
            let hits = words.filter { word in tokens.contains { $0.hasPrefix(word) } }.count
            score += 40 * Double(hits) / Double(words.count)
            if hits == words.count { score += 20 }
            if lower.contains(words.joined(separator: " ")) || lower.replacingOccurrences(of: ".", with: " ").contains(words.joined(separator: " ")) {
                score += 25
            }
            // Titles that start with the query read as the thing itself rather than something mentioning it.
            if tokens.first.map({ $0.hasPrefix(words[0]) }) == true { score += 8 }
        }
        let seeds = Double(max(seeders ?? 0, 0))
        score += min(25, log2(1 + seeds) * 3)
        if (seeders ?? 0) == 0 { score -= 15 }
        return score
    }
}

enum SearchRefine {
    static func filter(_ results: [SearchResult], with filter: SearchFilter) -> [SearchResult] {
        var kept = results.filter { result in
            (result.seeders ?? 0) >= filter.minSeeds
                && filter.size.contains(result.size)
                && (filter.qualities.isEmpty || filter.qualities.isSubset(of: result.qualities))
        }
        if filter.hideDuplicates { kept = dedupe(kept) }
        return kept
    }

    /// Keeps the best-seeded copy of anything with the same info-hash, or the same normalised title and size.
    static func dedupe(_ results: [SearchResult]) -> [SearchResult] {
        var best: [String: SearchResult] = [:]
        var order: [String] = []
        for result in results {
            let key = result.infoHash?.lowercased()
                ?? "\(result.title.lowercased().filter { $0.isLetter || $0.isNumber })|\(result.size ?? -1)"
            if let existing = best[key] {
                if (result.seeders ?? -1) > (existing.seeders ?? -1) { best[key] = result }
            } else {
                best[key] = result
                order.append(key)
            }
        }
        return order.compactMap { best[$0] }
    }

    static func sort(_ results: [SearchResult], by sort: SearchSort, ascending: Bool, query: String) -> [SearchResult] {
        let sorted: [SearchResult]
        switch sort {
        case .bestMatch:
            let scored = results.map { ($0, $0.relevance(for: query)) }
            sorted = scored.sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.sortSeeders > $1.0.sortSeeders }.map(\.0)
            return ascending ? sorted.reversed() : sorted
        case .seeds: sorted = results.sorted { $0.sortSeeders > $1.sortSeeders }
        case .size: sorted = results.sorted { $0.sortSize > $1.sortSize }
        case .date: sorted = results.sorted { $0.sortDate > $1.sortDate }
        case .name: sorted = results.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        case .source: sorted = results.sorted { ($0.provider, $1.sortSeeders) < ($1.provider, $0.sortSeeders) }
        }
        // Each sort has a natural order (most first, A→Z); the direction toggle reverses it.
        return ascending ? sorted.reversed() : sorted
    }
}
