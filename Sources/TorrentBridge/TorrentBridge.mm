#import "TorrentBridge.h"

#include <libtorrent/session.hpp>
#include <libtorrent/session_params.hpp>
#include <libtorrent/settings_pack.hpp>
#include <libtorrent/add_torrent_params.hpp>
#include <libtorrent/torrent_handle.hpp>
#include <libtorrent/torrent_status.hpp>
#include <libtorrent/torrent_info.hpp>
#include <libtorrent/torrent_flags.hpp>
#include <libtorrent/magnet_uri.hpp>
#include <libtorrent/alert_types.hpp>
#include <libtorrent/read_resume_data.hpp>
#include <libtorrent/write_resume_data.hpp>
#include <libtorrent/create_torrent.hpp>
#include <libtorrent/bencode.hpp>
#include <libtorrent/peer_info.hpp>
#include <libtorrent/announce_entry.hpp>
#include <libtorrent/fingerprint.hpp>
#include <libtorrent/error_code.hpp>
#include <libtorrent/ip_filter.hpp>
#include <libtorrent/address.hpp>

#include <arpa/inet.h>

#include <algorithm>
#include <atomic>
#include <cctype>
#include <chrono>
#include <fstream>
#include <limits>
#include <map>
#include <memory>
#include <mutex>
#include <optional>
#include <set>
#include <sstream>
#include <string>
#include <vector>

@implementation KTTorrentStatus
@end
@implementation KTFileEntry
@end
@implementation KTPeerInfo
@end
@implementation KTTrackerInfo
@end
@implementation KTEvent
@end

@implementation KTSessionSettings
- (instancetype)init {
    if ((self = [super init])) {
        _listenPort = 6881;
        _maxActiveDownloads = 5;
        _maxActiveSeeds = 5;
        _maxConnections = 300;
        _enableDHT = YES;
        _enableLSD = YES;
        _enablePortMapping = YES;
    }
    return self;
}
@end

namespace {

NSString *const KTErrorDomain = @"Piece.TorrentBridge";

NSString *toNS(const std::string &s) {
    NSString *r = [[NSString alloc] initWithBytes:s.data() length:s.size() encoding:NSUTF8StringEncoding];
    if (r) return r;
    r = [[NSString alloc] initWithBytes:s.data() length:s.size() encoding:NSISOLatin1StringEncoding];
    return r ?: @"";
}

std::string hashString(const lt::torrent_handle &h) {
    std::stringstream ss;
    ss << h.info_hashes().get_best();
    return ss.str();
}

std::string hashString(const lt::info_hash_t &ih) {
    std::stringstream ss;
    ss << ih.get_best();
    return ss.str();
}

NSError *makeError(const std::string &message) {
    return [NSError errorWithDomain:KTErrorDomain
                               code:1
                           userInfo:@{NSLocalizedDescriptionKey : toNS(message)}];
}

/// Two addresses that differ only in case, surrounding spaces or a trailing slash are the same tracker.
std::string trackerKey(const std::string &url) {
    std::size_t start = 0, end = url.size();
    while (start < end && std::isspace(static_cast<unsigned char>(url[start]))) ++start;
    while (end > start && (std::isspace(static_cast<unsigned char>(url[end - 1])) || url[end - 1] == '/')) --end;
    std::string key = url.substr(start, end - start);
    std::transform(key.begin(), key.end(), key.begin(), [](unsigned char c) { return std::tolower(c); });
    return key;
}

/// Each added tracker gets its own tier after the existing ones, so it never displaces them.
lt::announce_entry nextTierEntry(const std::string &url, int &maxTier) {
    lt::announce_entry entry(url);
    maxTier = std::min(maxTier + 1, 255);
    entry.tier = static_cast<std::uint8_t>(maxTier);
    return entry;
}

int maxTierOf(const std::vector<lt::announce_entry> &trackers) {
    int tier = -1;
    for (const lt::announce_entry &ae : trackers) tier = std::max(tier, static_cast<int>(ae.tier));
    return tier;
}

bool readFile(const std::string &path, std::vector<char> &out) {
    std::ifstream f(path, std::ios::binary);
    if (!f) return false;
    out.assign(std::istreambuf_iterator<char>(f), std::istreambuf_iterator<char>());
    return true;
}

void writeFile(const std::string &path, const std::vector<char> &buf) {
    std::string tmp = path + ".tmp";
    {
        std::ofstream f(tmp, std::ios::binary | std::ios::trunc);
        f.write(buf.data(), static_cast<std::streamsize>(buf.size()));
    }
    std::rename(tmp.c_str(), path.c_str());
}

// MARK: - Blocklists

std::string trimmed(const std::string &s) {
    size_t a = 0, b = s.size();
    while (a < b && std::isspace(static_cast<unsigned char>(s[a]))) ++a;
    while (b > a && std::isspace(static_cast<unsigned char>(s[b - 1]))) --b;
    return s.substr(a, b - a);
}

/// Parses an IPv4 or IPv6 address. IPv4 octets may carry leading zeros ("001.002.003.004"),
/// which eMule .dat lists use and inet_pton rejects.
bool parseAddress(const std::string &text, lt::address &out) {
    std::string s = trimmed(text);
    if (s.empty()) return false;
    if (s.find(':') != std::string::npos) {
        in6_addr a6;
        if (inet_pton(AF_INET6, s.c_str(), &a6) != 1) return false;
        lt::address_v6::bytes_type bytes;
        std::copy(std::begin(a6.s6_addr), std::end(a6.s6_addr), bytes.begin());
        out = lt::address_v6(bytes);
        return true;
    }
    unsigned octets[4];
    size_t pos = 0;
    for (int i = 0; i < 4; ++i) {
        size_t start = pos;
        unsigned v = 0;
        while (pos < s.size() && std::isdigit(static_cast<unsigned char>(s[pos]))) {
            v = v * 10 + static_cast<unsigned>(s[pos] - '0');
            if (v > 255) return false;
            ++pos;
        }
        if (pos == start) return false;
        octets[i] = v;
        if (i < 3) {
            if (pos >= s.size() || s[pos] != '.') return false;
            ++pos;
        }
    }
    if (pos != s.size()) return false;
    out = lt::address_v4({{static_cast<unsigned char>(octets[0]), static_cast<unsigned char>(octets[1]),
                           static_cast<unsigned char>(octets[2]), static_cast<unsigned char>(octets[3])}});
    return true;
}

bool parseRange(const std::string &text, lt::address &first, lt::address &last) {
    size_t dash = text.find('-');
    if (dash == std::string::npos) return false;
    return parseAddress(text.substr(0, dash), first) && parseAddress(text.substr(dash + 1), last);
}

bool parseCIDR(const std::string &text, lt::address &first, lt::address &last) {
    size_t slash = text.find('/');
    if (slash == std::string::npos) return false;
    lt::address base;
    if (!parseAddress(text.substr(0, slash), base)) return false;
    std::string bitsText = trimmed(text.substr(slash + 1));
    if (bitsText.empty() || bitsText.size() > 3) return false;
    for (char c : bitsText) if (!std::isdigit(static_cast<unsigned char>(c))) return false;
    int bits = std::stoi(bitsText);
    if (base.is_v4()) {
        if (bits > 32) return false;
        uint32_t ip = base.to_v4().to_uint();
        uint32_t mask = bits == 0 ? 0 : ~uint32_t(0) << (32 - bits);
        first = lt::address_v4(ip & mask);
        last = lt::address_v4(ip | ~mask);
    } else {
        if (bits > 128) return false;
        auto lo = base.to_v6().to_bytes();
        auto hi = lo;
        for (int i = 0; i < 16; ++i) {
            int keep = std::max(0, std::min(8, bits - i * 8));
            unsigned char mask = static_cast<unsigned char>(0xFF << (8 - keep));
            lo[i] &= mask;
            hi[i] |= static_cast<unsigned char>(~mask);
        }
        first = lt::address_v6(lo);
        last = lt::address_v6(hi);
    }
    return true;
}

/// Reads one blocklist line. Understands the PeerGuardian text format ("Name:1.2.3.4-1.2.3.9", what
/// Transmission lists use), eMule .dat ("1.2.3.4 - 1.2.3.9 , 000 , Name"), and bare ranges, CIDR
/// blocks and single addresses. Returns NO for comments, blank lines and anything unrecognised.
bool parseBlocklistLine(const std::string &raw, lt::address &first, lt::address &last) {
    std::string line = trimmed(raw);
    if (line.empty() || line[0] == '#' || line[0] == ';' || line.compare(0, 2, "//") == 0) return NO;

    // eMule .dat: the access level follows the range, and 128 or more means "allowed".
    size_t comma = line.find(',');
    if (comma != std::string::npos) {
        if (!parseRange(line.substr(0, comma), first, last)) return NO;
        size_t next = line.find(',', comma + 1);
        std::string level = trimmed(line.substr(comma + 1, next == std::string::npos ? std::string::npos : next - comma - 1));
        if (!level.empty() && std::all_of(level.begin(), level.end(), [](char c) { return std::isdigit(static_cast<unsigned char>(c)); })
            && level.size() <= 4 && std::stoi(level) >= 128) return NO;
        return YES;
    }
    if (parseRange(line, first, last) || parseCIDR(line, first, last)) return YES;
    if (parseAddress(line, first)) { last = first; return YES; }

    // PeerGuardian: the name can contain colons, so try each one as the start of the range.
    for (size_t colon = line.find(':'); colon != std::string::npos; colon = line.find(':', colon + 1)) {
        std::string rest = line.substr(colon + 1);
        if (parseRange(rest, first, last)) return YES;
    }
    return NO;
}

lt::settings_pack makePack(KTSessionSettings *s) {
    lt::settings_pack p;
    p.set_int(lt::settings_pack::alert_mask,
              lt::alert_category::status | lt::alert_category::error | lt::alert_category::storage |
              lt::alert_category::file_progress);
    p.set_str(lt::settings_pack::user_agent, "Piece/1.0 libtorrent/2.0");
    p.set_str(lt::settings_pack::peer_fingerprint, lt::generate_fingerprint("KT", 1, 0, 0, 0));
    std::string port = std::to_string(s.listenPort);
    p.set_str(lt::settings_pack::listen_interfaces, "0.0.0.0:" + port + ",[::]:" + port);
    p.set_str(lt::settings_pack::dht_bootstrap_nodes,
              "router.bittorrent.com:6881,dht.transmissionbt.com:6881,"
              "router.utorrent.com:6881,dht.libtorrent.org:25401");
    p.set_bool(lt::settings_pack::enable_dht, s.enableDHT);
    p.set_bool(lt::settings_pack::enable_lsd, s.enableLSD);
    p.set_bool(lt::settings_pack::enable_upnp, s.enablePortMapping);
    p.set_bool(lt::settings_pack::enable_natpmp, s.enablePortMapping);
    p.set_int(lt::settings_pack::download_rate_limit, s.downloadRateLimit);
    p.set_int(lt::settings_pack::upload_rate_limit, s.uploadRateLimit);
    p.set_int(lt::settings_pack::active_downloads, s.maxActiveDownloads);
    p.set_int(lt::settings_pack::active_seeds, s.maxActiveSeeds);
    p.set_int(lt::settings_pack::active_limit, s.maxActiveDownloads + s.maxActiveSeeds + 10);
    p.set_int(lt::settings_pack::connections_limit, s.maxConnections);
    // Merged trackers sit in tiers of their own; without this only the first working tier is used.
    p.set_bool(lt::settings_pack::announce_to_all_tiers, true);
    int enc = s.requireEncryption ? lt::settings_pack::pe_forced : lt::settings_pack::pe_enabled;
    p.set_int(lt::settings_pack::out_enc_policy, enc);
    p.set_int(lt::settings_pack::in_enc_policy, enc);
    return p;
}

} // namespace

@implementation KTSession {
    std::unique_ptr<lt::session> _session;
    std::map<std::string, lt::torrent_handle> _handles;
    std::mutex _mutex;
    std::string _stateDir;
    std::atomic<int> _pendingResume;
    std::vector<std::string> _mergeTrackers;
    std::set<std::string> _filterKeys;
    std::atomic<bool> _partSuffix;
    // Renames in flight, keyed by (torrent, file index), with the name each is headed for.
    std::mutex _renameMutex;
    std::map<std::pair<std::string, int>, std::string> _renaming;
    // "Finished" events held back until the torrent's files have their final names.
    NSMutableDictionary<NSString *, KTEvent *> *_deferredFinished;
    NSMutableDictionary<NSString *, NSDate *> *_deferredSince;
    // The transfer hold: whether it's on, the torrents it must leave alone, and the ones it paused
    // (mapped to whether each was auto-managed before).
    std::mutex _holdMutex;
    bool _holdActive;
    std::set<std::string> _holdExempt;
    std::map<std::string, bool> _held;
}

- (instancetype)initWithStateDirectory:(NSString *)stateDirectory settings:(KTSessionSettings *)settings {
    if ((self = [super init])) {
        _stateDir = stateDirectory.fileSystemRepresentation;
        _partSuffix = settings.partSuffix;
        _deferredFinished = [NSMutableDictionary dictionary];
        _deferredSince = [NSMutableDictionary dictionary];
        [[NSFileManager defaultManager] createDirectoryAtPath:[stateDirectory stringByAppendingPathComponent:@"resume"]
                                  withIntermediateDirectories:YES
                                                   attributes:nil
                                                        error:nil];
        lt::session_params params;
        std::vector<char> buf;
        if (readFile(_stateDir + "/session.state", buf)) {
            lt::error_code ec;
            lt::bdecode_node node = lt::bdecode(buf, ec);
            if (!ec) params = lt::read_session_params(node);
        }
        // Saved state only contributes DHT nodes; the app's own settings always win.
        params.settings = makePack(settings);
        _session = std::make_unique<lt::session>(std::move(params));
    }
    return self;
}

+ (nullable NSData *)createTorrentForPath:(NSString *)path {
    try {
        std::string full = path.fileSystemRepresentation;
        lt::file_storage fs;
        lt::add_files(fs, full);
        if (fs.num_files() == 0) return nil;
        lt::create_torrent ct(fs);
        lt::error_code ec;
        lt::set_piece_hashes(ct, path.stringByDeletingLastPathComponent.fileSystemRepresentation, ec);
        if (ec) return nil;
        std::vector<char> buf;
        lt::bencode(std::back_inserter(buf), ct.generate());
        return [NSData dataWithBytes:buf.data() length:buf.size()];
    } catch (const std::exception &) {
        return nil;
    }
}

- (void)applySettings:(KTSessionSettings *)settings {
    // libtorrent throws when a handle has gone away; never let that unwind into Swift.
    try {
        _session->apply_settings(makePack(settings));
        bool changed = _partSuffix.exchange(settings.partSuffix) != bool(settings.partSuffix);
        if (changed) [self reconcileAllPartNames];
    } catch (const std::exception &) {
    }
}

- (NSInteger)loadBlocklistAtPath:(NSString *)path {
    // libtorrent throws when a handle has gone away; never let that unwind into Swift.
    try {
        std::ifstream file(path.fileSystemRepresentation, std::ios::binary);
        if (!file) return -1;
        lt::ip_filter filter;
        NSInteger rules = 0;
        std::string line;
        while (std::getline(file, line)) {
            lt::address first, last;
            if (!parseBlocklistLine(line, first, last)) continue;
            if (first.is_v4() != last.is_v4()) continue;
            if (last < first) std::swap(first, last);
            filter.add_rule(first, last, lt::ip_filter::blocked);
            ++rules;
        }
        // An empty or unreadable list never replaces the one in force.
        if (rules == 0) return 0;
        _session->set_ip_filter(std::move(filter));
        return rules;
    } catch (const std::exception &) {
    }
    return -1;
}

- (void)clearBlocklist {
    try {
        _session->set_ip_filter(lt::ip_filter());
    } catch (const std::exception &) {
    }
}

- (std::string)resumePathFor:(const std::string &)hash {
    return _stateDir + "/resume/" + hash + ".fastresume";
}

- (BOOL)handle:(lt::torrent_handle &)out forHash:(NSString *)infoHash {
    // libtorrent throws when a handle has gone away; never let that unwind into Swift.
    try {
        std::lock_guard<std::mutex> lock(_mutex);
        auto it = _handles.find(infoHash.UTF8String);
        if (it == _handles.end() || !it->second.is_valid()) return NO;
        out = it->second;
        return YES;
    } catch (const std::exception &) {
    }
    return NO;
}

- (void)restoreTorrents {
    // libtorrent throws when a handle has gone away; never let that unwind into Swift.
    try {
        NSString *dir = [toNS(_stateDir) stringByAppendingPathComponent:@"resume"];
        NSArray<NSString *> *names = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:dir error:nil];
        for (NSString *name in names) {
            if (![name.pathExtension isEqualToString:@"fastresume"]) continue;
            std::vector<char> buf;
            if (!readFile([dir stringByAppendingPathComponent:name].fileSystemRepresentation, buf)) continue;
            lt::error_code ec;
            lt::add_torrent_params atp = lt::read_resume_data(buf, ec);
            if (ec) continue;
            [self holdIfNeeded:atp hash:hashString(atp.info_hashes)];
            lt::torrent_handle h = _session->add_torrent(std::move(atp), ec);
            if (ec || !h.is_valid()) continue;
            std::lock_guard<std::mutex> lock(_mutex);
            _handles[hashString(h)] = h;
        }
    } catch (const std::exception &) {
    }
}

/// Adds the trackers in `atp` (a .torrent's announce list or a magnet's `tr=`) that the transfer doesn't have yet.
- (void)mergeTrackersOf:(const lt::add_torrent_params &)atp intoTorrent:(NSString *)infoHash {
    // libtorrent throws when a handle has gone away; never let that unwind into Swift.
    try {
        lt::torrent_handle h;
        if (![self handle:h forHash:infoHash]) return;
        std::vector<lt::announce_entry> current = h.trackers();
        std::set<std::string> have;
        for (const lt::announce_entry &ae : current) have.insert(trackerKey(ae.url));
        std::vector<std::string> incoming = atp.trackers;
        if (atp.ti)
            for (const lt::announce_entry &ae : atp.ti->trackers()) incoming.push_back(ae.url);
        int maxTier = maxTierOf(current);
        bool changed = false;
        for (const std::string &url : incoming) {
            std::string key = trackerKey(url);
            if (key.empty() || !have.insert(key).second) continue;
            h.add_tracker(nextTierEntry(url, maxTier));
            changed = true;
        }
        // The filter list still wins over whatever the file brought along.
        if ([self applyTrackerRulesTo:h]) changed = true;
        if (changed) [self saveResumeDataFor:h];
    } catch (const std::exception &) {
    }
}

- (nullable NSString *)addParams:(lt::add_torrent_params)atp savePath:(NSString *)savePath error:(NSError **)error {
    // libtorrent throws when a handle has gone away; never let that unwind into Swift.
    try {
        atp.save_path = savePath.fileSystemRepresentation;
        std::string hash = hashString(atp.info_hashes.has_v1() || atp.info_hashes.has_v2()
                                          ? atp.info_hashes
                                          : (atp.ti ? atp.ti->info_hashes() : atp.info_hashes));
        bool exists;
        {
            std::lock_guard<std::mutex> lock(_mutex);
            exists = _handles.count(hash) > 0;
        }
        if (exists) {
            // Already added: keep the transfer, but pick up any trackers the new torrent file or link knows.
            [self mergeTrackersOf:atp intoTorrent:toNS(hash)];
            return toNS(hash);
        }
        lt::error_code ec;
        [self holdIfNeeded:atp hash:hash];
        std::string requested = hash;
        lt::torrent_handle h = _session->add_torrent(std::move(atp), ec);
        if (ec || !h.is_valid()) {
            std::lock_guard<std::mutex> lock(_holdMutex);
            _held.erase(requested);
            if (error) *error = makeError(ec ? ec.message() : "The torrent could not be added.");
            return nil;
        }
        hash = hashString(h);
        {
            std::lock_guard<std::mutex> lock(_mutex);
            _handles[hash] = h;
        }
        [self applyTrackerRulesTo:h];
        h.save_resume_data(lt::torrent_handle::save_info_dict);
        ++_pendingResume;
        return toNS(hash);
    } catch (const std::exception &) {
    }
    return nil;
}

- (nullable NSString *)addMagnet:(NSString *)magnet savePath:(NSString *)savePath error:(NSError **)error {
    // libtorrent throws when a handle has gone away; never let that unwind into Swift.
    try {
        lt::error_code ec;
        lt::add_torrent_params atp = lt::parse_magnet_uri(magnet.UTF8String, ec);
        if (ec) {
            if (error) *error = makeError("That magnet link isn't valid: " + ec.message());
            return nil;
        }
        return [self addParams:std::move(atp) savePath:savePath error:error];
    } catch (const std::exception &) {
    }
    return nil;
}

- (nullable NSString *)addTorrentData:(NSData *)data savePath:(NSString *)savePath error:(NSError **)error {
    // libtorrent throws when a handle has gone away; never let that unwind into Swift.
    try {
        lt::error_code ec;
        auto ti = std::make_shared<lt::torrent_info>(
            lt::span<char const>(static_cast<const char *>(data.bytes), static_cast<std::ptrdiff_t>(data.length)), ec,
            lt::from_span);
        if (ec) {
            if (error) *error = makeError("That torrent file isn't valid: " + ec.message());
            return nil;
        }
        lt::add_torrent_params atp;
        atp.ti = ti;
        return [self addParams:std::move(atp) savePath:savePath error:error];
    } catch (const std::exception &) {
    }
    return nil;
}

- (void)removeTorrent:(NSString *)infoHash deleteFiles:(BOOL)deleteFiles {
    // libtorrent throws when a handle has gone away; never let that unwind into Swift.
    try {
        lt::torrent_handle h;
        if (![self handle:h forHash:infoHash]) return;
        std::string hash = infoHash.UTF8String;
        {
            std::lock_guard<std::mutex> lock(_mutex);
            _handles.erase(hash);
        }
        [self endHoldFor:infoHash];
        {
            std::lock_guard<std::mutex> lock(_renameMutex);
            for (auto it = _renaming.begin(); it != _renaming.end();)
                it = it->first.first == hash ? _renaming.erase(it) : std::next(it);
        }
        _session->remove_torrent(h, deleteFiles ? lt::session::delete_files : lt::remove_flags_t{});
        std::remove([self resumePathFor:hash].c_str());
    } catch (const std::exception &) {
    }
}

- (void)pauseTorrent:(NSString *)infoHash {
    // libtorrent throws when a handle has gone away; never let that unwind into Swift.
    try {
        lt::torrent_handle h;
        if (![self handle:h forHash:infoHash]) return;
        [self endHoldFor:infoHash];
        h.unset_flags(lt::torrent_flags::auto_managed);
        h.pause(lt::torrent_handle::graceful_pause);
    } catch (const std::exception &) {
    }
}

- (void)resumeTorrent:(NSString *)infoHash {
    // libtorrent throws when a handle has gone away; never let that unwind into Swift.
    try {
        lt::torrent_handle h;
        if (![self handle:h forHash:infoHash]) return;
        [self endHoldFor:infoHash];
        h.clear_error();
        h.set_flags(lt::torrent_flags::auto_managed);
        h.resume();
    } catch (const std::exception &) {
    }
}

// MARK: - Hold

- (void)setHoldActive:(BOOL)active exempt:(NSArray<NSString *> *)exempt {
    // libtorrent throws when a handle has gone away; never let that unwind into Swift.
    try {
        std::set<std::string> keep;
        for (NSString *hash in exempt) keep.insert(hash.UTF8String);
        std::vector<std::pair<std::string, lt::torrent_handle>> handles;
        {
            std::lock_guard<std::mutex> lock(_mutex);
            handles.assign(_handles.begin(), _handles.end());
        }
        std::lock_guard<std::mutex> lock(_holdMutex);
        _holdActive = active;
        _holdExempt = std::move(keep);
        for (auto &entry : handles) {
            try {
                lt::torrent_handle &h = entry.second;
                if (!h.is_valid()) continue;
                const std::string &hash = entry.first;
                bool hold = _holdActive && !_holdExempt.count(hash);
                auto held = _held.find(hash);
                if (hold && held == _held.end()) {
                    lt::torrent_flags_t flags = h.flags();
                    bool userPaused = (flags & lt::torrent_flags::paused) && !(flags & lt::torrent_flags::auto_managed);
                    if (userPaused) continue;
                    _held[hash] = bool(flags & lt::torrent_flags::auto_managed);
                    h.unset_flags(lt::torrent_flags::auto_managed);
                    h.pause();
                } else if (!hold && held != _held.end()) {
                    bool wasAutoManaged = held->second;
                    _held.erase(held);
                    if (wasAutoManaged) h.set_flags(lt::torrent_flags::auto_managed);
                    h.resume();
                }
            } catch (const std::exception &) {
            }
        }
    } catch (const std::exception &) {
    }
}

/// Makes a torrent about to be added or restored start held, when the hold applies to it.
- (void)holdIfNeeded:(lt::add_torrent_params &)atp hash:(const std::string &)hash {
    std::lock_guard<std::mutex> lock(_holdMutex);
    if (!_holdActive || _holdExempt.count(hash)) return;
    bool userPaused = (atp.flags & lt::torrent_flags::paused) && !(atp.flags & lt::torrent_flags::auto_managed);
    if (userPaused) return;
    _held[hash] = bool(atp.flags & lt::torrent_flags::auto_managed);
    atp.flags &= ~lt::torrent_flags::auto_managed;
    atp.flags |= lt::torrent_flags::paused;
}

- (void)endHoldFor:(NSString *)infoHash {
    std::lock_guard<std::mutex> lock(_holdMutex);
    _held.erase(infoHash.UTF8String);
}

- (void)recheck:(NSString *)infoHash {
    // libtorrent throws when a handle has gone away; never let that unwind into Swift.
    try {
        lt::torrent_handle h;
        if ([self handle:h forHash:infoHash]) h.force_recheck();
    } catch (const std::exception &) {
    }
}

- (void)reannounceTorrent:(NSString *)infoHash {
    // libtorrent throws when a handle has gone away; never let that unwind into Swift.
    try {
        lt::torrent_handle h;
        if (![self handle:h forHash:infoHash]) return;
        h.force_reannounce();
        h.force_dht_announce();
    } catch (const std::exception &) {
    }
}

- (void)setSequential:(BOOL)sequential forTorrent:(NSString *)infoHash {
    // libtorrent throws when a handle has gone away; never let that unwind into Swift.
    try {
        lt::torrent_handle h;
        if (![self handle:h forHash:infoHash]) return;
        if (sequential) h.set_flags(lt::torrent_flags::sequential_download);
        else h.unset_flags(lt::torrent_flags::sequential_download);
    } catch (const std::exception &) {
    }
}

- (NSArray<KTTorrentStatus *> *)statuses {
    // libtorrent throws when a handle has gone away; never let that unwind into Swift.
    try {
        std::vector<std::pair<std::string, lt::torrent_handle>> handles;
        {
            std::lock_guard<std::mutex> lock(_mutex);
            handles.assign(_handles.begin(), _handles.end());
        }
        std::set<std::string> held;
        {
            std::lock_guard<std::mutex> lock(_holdMutex);
            for (auto &entry : _held) held.insert(entry.first);
        }
        NSMutableArray<KTTorrentStatus *> *out = [NSMutableArray arrayWithCapacity:handles.size()];
        for (auto &entry : handles) {
            if (!entry.second.is_valid()) continue;
            lt::torrent_status st;
            try {
                st = entry.second.status(lt::torrent_handle::query_name |
                                                        lt::torrent_handle::query_save_path |
                                                        lt::torrent_handle::query_torrent_file);
            } catch (const std::exception &) {
                continue;
            }
            KTTorrentStatus *s = [KTTorrentStatus new];
            s.infoHash = toNS(entry.first);
            s.name = st.name.empty() ? toNS(entry.first) : toNS(st.name);
            s.savePath = toNS(st.save_path);
            if (st.errc) s.errorMessage = toNS(st.errc.message());
            switch (st.state) {
            case lt::torrent_status::checking_files:
            case lt::torrent_status::checking_resume_data: s.state = KTTorrentStateChecking; break;
            case lt::torrent_status::downloading_metadata: s.state = KTTorrentStateFetchingMetadata; break;
            case lt::torrent_status::finished: s.state = KTTorrentStateFinished; break;
            case lt::torrent_status::seeding: s.state = KTTorrentStateSeeding; break;
            default: s.state = KTTorrentStateDownloading; break;
            }
            s.paused = bool(st.flags & lt::torrent_flags::paused);
            s.autoManaged = bool(st.flags & lt::torrent_flags::auto_managed);
            s.held = held.count(entry.first) > 0;
            s.sequential = bool(st.flags & lt::torrent_flags::sequential_download);
            s.hasMetadata = st.has_metadata;
            s.progress = st.progress;
            s.totalWanted = st.total_wanted;
            s.totalWantedDone = st.total_wanted_done;
            s.totalDownloaded = st.all_time_download;
            s.totalUploaded = st.all_time_upload;
            s.downloadRate = st.download_payload_rate;
            s.uploadRate = st.upload_payload_rate;
            s.numPeers = st.num_peers;
            s.numSeeds = st.num_seeds;
            s.addedTime = static_cast<NSTimeInterval>(st.added_time);
            s.completedTime = static_cast<NSTimeInterval>(st.completed_time);
            if (auto ti = st.torrent_file.lock()) {
                s.totalSize = ti->total_size();
                s.numPieces = ti->num_pieces();
                s.pieceLength = ti->piece_length();
            }
            [out addObject:s];
        }
        return out;
    } catch (const std::exception &) {
    }
    return @[];
}

- (NSArray<KTFileEntry *> *)filesForTorrent:(NSString *)infoHash {
    // libtorrent throws when a handle has gone away; never let that unwind into Swift.
    try {
        lt::torrent_handle h;
        if (![self handle:h forHash:infoHash]) return @[];
        auto ti = h.torrent_file();
        if (!ti) return @[];
        const lt::file_storage &fs = ti->files();
        std::vector<std::int64_t> progress;
        h.file_progress(progress, lt::torrent_handle::piece_granularity);
        std::vector<lt::download_priority_t> priorities = h.get_file_priorities();
        NSMutableArray<KTFileEntry *> *out = [NSMutableArray arrayWithCapacity:fs.num_files()];
        for (lt::file_index_t i : fs.file_range()) {
            if (fs.pad_file_at(i)) continue;
            int idx = static_cast<int>(i);
            KTFileEntry *f = [KTFileEntry new];
            f.index = idx;
            f.path = toNS(ti->orig_files().file_path(i));
            f.diskPath = toNS(fs.file_path(i));
            f.size = fs.file_size(i);
            f.downloaded = idx < static_cast<int>(progress.size()) ? progress[idx] : 0;
            f.priority = idx < static_cast<int>(priorities.size())
                             ? static_cast<int>(static_cast<std::uint8_t>(priorities[idx]))
                             : 4;
            [out addObject:f];
        }
        return out;
    } catch (const std::exception &) {
    }
    return @[];
}

- (NSArray<KTPeerInfo *> *)peersForTorrent:(NSString *)infoHash {
    // libtorrent throws when a handle has gone away; never let that unwind into Swift.
    try {
        lt::torrent_handle h;
        if (![self handle:h forHash:infoHash]) return @[];
        std::vector<lt::peer_info> peers;
        h.get_peer_info(peers);
        NSMutableArray<KTPeerInfo *> *out = [NSMutableArray arrayWithCapacity:peers.size()];
        for (const lt::peer_info &p : peers) {
            if (p.flags & (lt::peer_info::connecting | lt::peer_info::handshake)) continue;
            KTPeerInfo *info = [KTPeerInfo new];
            info.address = toNS(p.ip.address().to_string());
            info.client = toNS(p.client);
            info.progress = p.progress;
            info.downloadRate = p.payload_down_speed;
            info.uploadRate = p.payload_up_speed;
            info.isSeed = bool(p.flags & lt::peer_info::seed);
            [out addObject:info];
        }
        return out;
    } catch (const std::exception &) {
    }
    return @[];
}

- (NSArray<KTTrackerInfo *> *)trackersForTorrent:(NSString *)infoHash {
    // libtorrent throws when a handle has gone away; never let that unwind into Swift.
    try {
        lt::torrent_handle h;
        if (![self handle:h forHash:infoHash]) return @[];
        std::vector<lt::announce_entry> trackers = h.trackers();
        NSMutableArray<KTTrackerInfo *> *out = [NSMutableArray arrayWithCapacity:trackers.size()];
        for (const lt::announce_entry &ae : trackers) {
            KTTrackerInfo *t = [KTTrackerInfo new];
            t.url = toNS(ae.url);
            t.tier = ae.tier;
            t.seeds = -1;
            t.leechers = -1;
            std::string message;
            bool working = false, updating = false;
            for (const lt::announce_endpoint &ep : ae.endpoints) {
                for (const lt::announce_infohash &ih : ep.info_hashes) {
                    if (ih.fails == 0 && ih.start_sent) working = true;
                    if (ih.updating) updating = true;
                    if (ih.scrape_complete > t.seeds) t.seeds = ih.scrape_complete;
                    if (ih.scrape_incomplete > t.leechers) t.leechers = ih.scrape_incomplete;
                    if (!ih.message.empty()) message = ih.message;
                    else if (ih.last_error && message.empty()) message = ih.last_error.message();
                }
            }
            t.working = working;
            t.updating = updating;
            t.message = toNS(message);
            [out addObject:t];
        }
        return out;
    } catch (const std::exception &) {
    }
    return @[];
}

- (void)setPriority:(int)priority forFile:(int)fileIndex inTorrent:(NSString *)infoHash {
    // libtorrent throws when a handle has gone away; never let that unwind into Swift.
    try {
        lt::torrent_handle h;
        if (![self handle:h forHash:infoHash]) return;
        h.file_priority(lt::file_index_t(fileIndex), lt::download_priority_t(static_cast<std::uint8_t>(priority)));
    } catch (const std::exception &) {
    }
}

// MARK: - Trackers

- (void)saveResumeDataFor:(lt::torrent_handle &)h {
    h.save_resume_data(lt::torrent_handle::save_info_dict);
    ++_pendingResume;
}

- (BOOL)addTracker:(NSString *)url toTorrent:(NSString *)infoHash {
    // libtorrent throws when a handle has gone away; never let that unwind into Swift.
    try {
        lt::torrent_handle h;
        if (![self handle:h forHash:infoHash]) return NO;
        std::string address = url.UTF8String;
        std::string key = trackerKey(address);
        if (key.empty()) return NO;
        std::vector<lt::announce_entry> trackers = h.trackers();
        for (const lt::announce_entry &ae : trackers)
            if (trackerKey(ae.url) == key) return NO;
        int maxTier = maxTierOf(trackers);
        h.add_tracker(nextTierEntry(address, maxTier));
        [self saveResumeDataFor:h];
        return YES;
    } catch (const std::exception &) {
    }
    return NO;
}

- (void)removeTracker:(NSString *)url fromTorrent:(NSString *)infoHash {
    // libtorrent throws when a handle has gone away; never let that unwind into Swift.
    try {
        lt::torrent_handle h;
        if (![self handle:h forHash:infoHash]) return;
        std::string key = trackerKey(url.UTF8String);
        std::vector<lt::announce_entry> trackers = h.trackers();
        auto end = std::remove_if(trackers.begin(), trackers.end(),
                                  [&](const lt::announce_entry &ae) { return trackerKey(ae.url) == key; });
        if (end == trackers.end()) return;
        trackers.erase(end, trackers.end());
        h.replace_trackers(trackers);
        [self saveResumeDataFor:h];
    } catch (const std::exception &) {
    }
}

- (void)setMergeTrackers:(NSArray<NSString *> *)merge
          filterTrackers:(NSArray<NSString *> *)filter
         applyToExisting:(BOOL)applyToExisting {
    std::vector<lt::torrent_handle> handles;
    {
        std::lock_guard<std::mutex> lock(_mutex);
        _mergeTrackers.clear();
        _filterKeys.clear();
        for (NSString *url in merge) _mergeTrackers.push_back(url.UTF8String);
        for (NSString *url in filter) _filterKeys.insert(trackerKey(url.UTF8String));
        if (applyToExisting)
            for (auto &entry : _handles) handles.push_back(entry.second);
    }
    for (lt::torrent_handle &h : handles) {
        // libtorrent throws when a handle has gone away; never let that unwind into Swift.
        try {
            if (h.is_valid() && [self applyTrackerRulesTo:h]) [self saveResumeDataFor:h];
        } catch (const std::exception &) {
        }
    }
}

/// Strips filtered trackers and adds the missing merged ones. Returns YES when anything changed.
- (BOOL)applyTrackerRulesTo:(lt::torrent_handle &)h {
    std::vector<std::string> merge;
    std::set<std::string> filter;
    {
        std::lock_guard<std::mutex> lock(_mutex);
        merge = _mergeTrackers;
        filter = _filterKeys;
    }
    if (merge.empty() && filter.empty()) return NO;
    std::vector<lt::announce_entry> current = h.trackers();
    std::vector<lt::announce_entry> kept;
    std::set<std::string> have;
    for (const lt::announce_entry &ae : current) {
        std::string key = trackerKey(ae.url);
        if (filter.count(key)) continue;
        have.insert(key);
        kept.push_back(ae);
    }
    bool changed = kept.size() != current.size();
    if (changed) h.replace_trackers(kept);
    int maxTier = maxTierOf(kept);
    for (const std::string &url : merge) {
        std::string key = trackerKey(url);
        if (key.empty() || have.count(key) || filter.count(key)) continue;
        h.add_tracker(nextTierEntry(url, maxTier));
        have.insert(key);
        changed = true;
    }
    return changed;
}

- (NSData *)pieceMapForTorrent:(NSString *)infoHash {
    // libtorrent throws when a handle has gone away; never let that unwind into Swift.
    try {
        lt::torrent_handle h;
        if (![self handle:h forHash:infoHash]) return [NSData data];
        lt::torrent_status st = h.status(lt::torrent_handle::query_pieces | lt::torrent_handle::query_torrent_file);
        auto ti = st.torrent_file.lock();
        if (!ti) return [NSData data];
        int n = ti->num_pieces();
        NSMutableData *data = [NSMutableData dataWithLength:n];
        auto *bytes = static_cast<std::uint8_t *>(data.mutableBytes);
        bool all = st.pieces.empty() && st.is_seeding;
        for (int i = 0; i < n; ++i)
            bytes[i] = (all || (i < st.pieces.size() && st.pieces.get_bit(lt::piece_index_t(i)))) ? 1 : 0;
        return data;
    } catch (const std::exception &) {
    }
    return [NSData data];
}

- (int64_t)contiguousBytesInTorrent:(NSString *)infoHash file:(int)fileIndex offset:(int64_t)offset {
    // libtorrent throws when a handle has gone away; never let that unwind into Swift.
    try {
        lt::torrent_handle h;
        if (![self handle:h forHash:infoHash]) return 0;
        lt::torrent_status st = h.status(lt::torrent_handle::query_pieces | lt::torrent_handle::query_torrent_file);
        auto ti = st.torrent_file.lock();
        if (!ti) return 0;
        const lt::file_storage &fs = ti->files();
        if (fileIndex < 0 || fileIndex >= fs.num_files()) return 0;
        lt::file_index_t fi(fileIndex);
        std::int64_t remaining = fs.file_size(fi) - offset;
        if (remaining <= 0) return 0;
        if (st.is_seeding) return remaining;

        lt::peer_request req = ti->map_file(fi, offset, 1);
        int piece = static_cast<int>(req.piece);
        std::int64_t start = req.start;
        std::int64_t available = 0;
        int end = ti->num_pieces();
        while (piece < end && piece < st.pieces.size() && st.pieces.get_bit(lt::piece_index_t(piece))) {
            available += ti->piece_size(lt::piece_index_t(piece)) - start;
            start = 0;
            ++piece;
            if (available >= remaining) break;
        }
        return std::min(available, remaining);
    } catch (const std::exception &) {
    }
    return 0;
}

- (void)prioritizeTorrent:(NSString *)infoHash file:(int)fileIndex offset:(int64_t)offset window:(int64_t)window {
    // libtorrent throws when a handle has gone away; never let that unwind into Swift.
    try {
        lt::torrent_handle h;
        if (![self handle:h forHash:infoHash]) return;
        auto ti = h.torrent_file();
        if (!ti) return;
        const lt::file_storage &fs = ti->files();
        if (fileIndex < 0 || fileIndex >= fs.num_files()) return;
        lt::file_index_t fi(fileIndex);
        std::int64_t size = fs.file_size(fi);
        if (offset >= size) return;
        if (h.file_priority(fi) == lt::dont_download) h.file_priority(fi, lt::default_priority);

        std::int64_t last = std::min(offset + window, size) - 1;
        int first = static_cast<int>(ti->map_file(fi, offset, 1).piece);
        int lastPiece = static_cast<int>(ti->map_file(fi, last, 1).piece);
        int deadline = 300;
        for (int p = first; p <= lastPiece; ++p) {
            lt::piece_index_t idx(p);
            if (!h.have_piece(idx)) {
                h.set_piece_deadline(idx, deadline);
                deadline += 150;
            }
        }
    } catch (const std::exception &) {
    }
}

- (void)clearDeadlinesForTorrent:(NSString *)infoHash {
    // libtorrent throws when a handle has gone away; never let that unwind into Swift.
    try {
        lt::torrent_handle h;
        if ([self handle:h forHash:infoHash]) h.clear_piece_deadlines();
    } catch (const std::exception &) {
    }
}

- (nullable NSString *)magnetLinkForTorrent:(NSString *)infoHash {
    // libtorrent throws when a handle has gone away; never let that unwind into Swift.
    try {
        lt::torrent_handle h;
        if (![self handle:h forHash:infoHash]) return nil;
        return toNS(lt::make_magnet_uri(h));
    } catch (const std::exception &) {
    }
    return nil;
}

- (nullable NSData *)torrentDataForTorrent:(NSString *)infoHash {
    // libtorrent throws when a handle has gone away; never let that unwind into Swift.
    try {
        lt::torrent_handle h;
        if (![self handle:h forHash:infoHash]) return nil;
        auto ti = h.torrent_file();
        if (!ti) return nil;
        lt::create_torrent ct(*ti);
        std::vector<char> buf;
        lt::bencode(std::back_inserter(buf), ct.generate());
        return [NSData dataWithBytes:buf.data() length:buf.size()];
    } catch (const std::exception &) {
    }
    return nil;
}

// MARK: - Part files

/// Brings every file's name on disk in line with its state: `name.part` while incomplete (when the
/// option is on), the torrent's own name otherwise. Safe to call at any time; it only renames what differs.
- (void)reconcilePartNames:(lt::torrent_handle &)h {
    // libtorrent throws when a handle has gone away; never let that unwind into Swift.
    try {
        if (!h.is_valid()) return;
        lt::torrent_status st = h.status(lt::status_flags_t{});
        // Until the check is done nothing is known about which files are complete.
        if (!st.has_metadata || st.state == lt::torrent_status::checking_files ||
            st.state == lt::torrent_status::checking_resume_data ||
            st.state == lt::torrent_status::downloading_metadata) return;
        auto ti = h.torrent_file();
        if (!ti) return;
        const lt::file_storage &fs = ti->files();
        const lt::file_storage &orig = ti->orig_files();
        if (fs.num_files() != orig.num_files()) return;
        std::vector<std::int64_t> progress;
        h.file_progress(progress, lt::torrent_handle::piece_granularity);
        std::string hash = hashString(h);
        bool enabled = _partSuffix;
        for (lt::file_index_t i : fs.file_range()) {
            if (fs.pad_file_at(i)) continue;
            int idx = static_cast<int>(i);
            bool complete = fs.file_size(i) == 0 ||
                            (idx < static_cast<int>(progress.size()) && progress[idx] >= fs.file_size(i));
            std::string target = orig.file_path(i);
            if (enabled && !complete) target += ".part";
            if (fs.file_path(i) == target) continue;
            {
                std::lock_guard<std::mutex> lock(_renameMutex);
                auto &pending = _renaming[{hash, idx}];
                if (pending == target) continue;
                pending = target;
            }
            h.rename_file(i, target);
        }
    } catch (const std::exception &) {
    }
}

- (void)reconcileAllPartNames {
    // libtorrent throws when a handle has gone away; never let that unwind into Swift.
    try {
        std::vector<lt::torrent_handle> handles;
        {
            std::lock_guard<std::mutex> lock(_mutex);
            for (auto &entry : _handles) handles.push_back(entry.second);
        }
        for (lt::torrent_handle &h : handles) [self reconcilePartNames:h];
    } catch (const std::exception &) {
    }
}

- (void)renameFinished:(const lt::torrent_handle &)h file:(lt::file_index_t)index {
    std::lock_guard<std::mutex> lock(_renameMutex);
    _renaming.erase({hashString(h), static_cast<int>(index)});
}

- (BOOL)hasRenamesInFlightFor:(const std::string &)hash {
    std::lock_guard<std::mutex> lock(_renameMutex);
    auto it = _renaming.lower_bound({hash, std::numeric_limits<int>::min()});
    return it != _renaming.end() && it->first.first == hash;
}

/// Moves a held-back "finished" event into `out` once its torrent has no renames left (or has waited too long).
- (void)releaseDeferredFinished:(NSMutableArray<KTEvent *> *)out forHash:(NSString *)hash force:(BOOL)force {
    KTEvent *event = _deferredFinished[hash];
    if (!event) return;
    if (!force && [self hasRenamesInFlightFor:hash.UTF8String]) return;
    [out addObject:event];
    [_deferredFinished removeObjectForKey:hash];
    [_deferredSince removeObjectForKey:hash];
}

- (NSArray<KTEvent *> *)pollEvents {
    // libtorrent throws when a handle has gone away; never let that unwind into Swift.
    try {
        std::vector<lt::alert *> alerts;
        _session->pop_alerts(&alerts);
        NSMutableArray<KTEvent *> *out = [NSMutableArray array];
        // Torrents whose file names changed; their resume data is rewritten once, so a crash can't leave it pointing at old names.
        std::map<std::string, lt::torrent_handle> renamed;
        for (lt::alert *a : alerts) {
            try {
            if (auto *rd = lt::alert_cast<lt::save_resume_data_alert>(a)) {
                --_pendingResume;
                std::string hash = hashString(rd->params.info_hashes);
                bool known;
                {
                    std::lock_guard<std::mutex> lock(_mutex);
                    known = _handles.count(hash) > 0;
                }
                // A torrent removed while its save was in flight must not come back at next launch.
                if (known) {
                    // Save the transfer as the user left it, not as the hold has it.
                    std::optional<bool> heldAutoManaged;
                    {
                        std::lock_guard<std::mutex> lock(_holdMutex);
                        auto held = _held.find(hash);
                        if (held != _held.end()) heldAutoManaged = held->second;
                    }
                    if (heldAutoManaged) {
                        lt::add_torrent_params params = rd->params;
                        params.flags &= ~lt::torrent_flags::paused;
                        if (*heldAutoManaged) params.flags |= lt::torrent_flags::auto_managed;
                        writeFile([self resumePathFor:hash], lt::write_resume_data_buf(params));
                    } else {
                        writeFile([self resumePathFor:hash], lt::write_resume_data_buf(rd->params));
                    }
                }
            } else if (lt::alert_cast<lt::save_resume_data_failed_alert>(a)) {
                --_pendingResume;
            } else if (auto *fin = lt::alert_cast<lt::torrent_finished_alert>(a)) {
                KTEvent *e = [KTEvent new];
                e.type = KTEventTypeFinished;
                e.infoHash = toNS(hashString(fin->handle));
                e.message = toNS(fin->torrent_name());
                // The library reads the files as soon as it hears this, so wait until they have their final names.
                [self reconcilePartNames:fin->handle];
                if ([self hasRenamesInFlightFor:hashString(fin->handle)]) {
                    _deferredFinished[e.infoHash] = e;
                    _deferredSince[e.infoHash] = [NSDate date];
                } else {
                    [out addObject:e];
                }
                fin->handle.save_resume_data(lt::torrent_handle::save_info_dict);
                ++_pendingResume;
            } else if (auto *fc = lt::alert_cast<lt::file_completed_alert>(a)) {
                [self reconcilePartNames:fc->handle];
            } else if (auto *sc = lt::alert_cast<lt::state_changed_alert>(a)) {
                [self reconcilePartNames:sc->handle];
            } else if (auto *fr = lt::alert_cast<lt::file_renamed_alert>(a)) {
                [self renameFinished:fr->handle file:fr->index];
                renamed[hashString(fr->handle)] = fr->handle;
                [self releaseDeferredFinished:out forHash:toNS(hashString(fr->handle)) force:NO];
            } else if (auto *ff = lt::alert_cast<lt::file_rename_failed_alert>(a)) {
                [self renameFinished:ff->handle file:ff->index];
                [self releaseDeferredFinished:out forHash:toNS(hashString(ff->handle)) force:NO];
            } else if (auto *md = lt::alert_cast<lt::metadata_received_alert>(a)) {
                KTEvent *e = [KTEvent new];
                e.type = KTEventTypeMetadataReceived;
                e.infoHash = toNS(hashString(md->handle));
                e.message = toNS(md->torrent_name());
                [out addObject:e];
                md->handle.save_resume_data(lt::torrent_handle::save_info_dict);
                ++_pendingResume;
            } else if (auto *err = lt::alert_cast<lt::torrent_error_alert>(a)) {
                KTEvent *e = [KTEvent new];
                e.type = KTEventTypeError;
                e.infoHash = toNS(hashString(err->handle));
                e.message = toNS(err->error.message());
                [out addObject:e];
            } else if (auto *ferr = lt::alert_cast<lt::file_error_alert>(a)) {
                KTEvent *e = [KTEvent new];
                e.type = KTEventTypeError;
                e.infoHash = toNS(hashString(ferr->handle));
                e.message = toNS(ferr->error.message());
                [out addObject:e];
            }
            } catch (const std::exception &) {
                // The alert's torrent was removed before it was processed.
            }
        }
        for (auto &entry : renamed) {
            if (!entry.second.is_valid()) continue;
            entry.second.save_resume_data(lt::torrent_handle::save_info_dict);
            ++_pendingResume;
        }
        for (NSString *hash in [_deferredSince allKeys]) {
            if (-[_deferredSince[hash] timeIntervalSinceNow] > 10) [self releaseDeferredFinished:out forHash:hash force:YES];
        }
        return out;
    } catch (const std::exception &) {
    }
    return @[];
}

- (void)saveResumeData {
    // libtorrent throws when a handle has gone away; never let that unwind into Swift.
    try {
        // Picks up anything the alerts missed, such as a paused torrent that never changed state.
        if (!_session->is_paused()) [self reconcileAllPartNames];
        std::vector<lt::torrent_handle> handles;
        {
            std::lock_guard<std::mutex> lock(_mutex);
            for (auto &entry : _handles) handles.push_back(entry.second);
        }
        for (lt::torrent_handle &h : handles) {
            if (!h.is_valid()) continue;
            h.save_resume_data(lt::torrent_handle::save_info_dict | lt::torrent_handle::only_if_modified);
            ++_pendingResume;
        }
    } catch (const std::exception &) {
    }
}

- (void)shutdown {
    // libtorrent throws when a handle has gone away; never let that unwind into Swift.
    try {
        if (!_session) return;
        _session->pause();
        [self saveResumeData];
        auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(8);
        while (_pendingResume > 0 && std::chrono::steady_clock::now() < deadline) {
            _session->wait_for_alert(std::chrono::milliseconds(200));
            [self pollEvents];
        }
        writeFile(_stateDir + "/session.state", lt::write_session_params_buf(_session->session_state()));
        _session.reset();
    } catch (const std::exception &) {
    }
}

@end
