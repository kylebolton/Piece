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

#include <atomic>
#include <chrono>
#include <fstream>
#include <map>
#include <memory>
#include <mutex>
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

NSString *const KTErrorDomain = @"Swarmly.TorrentBridge";

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

lt::settings_pack makePack(KTSessionSettings *s) {
    lt::settings_pack p;
    p.set_int(lt::settings_pack::alert_mask,
              lt::alert_category::status | lt::alert_category::error | lt::alert_category::storage);
    p.set_str(lt::settings_pack::user_agent, "Swarmly/1.0 libtorrent/2.0");
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
}

- (instancetype)initWithStateDirectory:(NSString *)stateDirectory settings:(KTSessionSettings *)settings {
    if ((self = [super init])) {
        _stateDir = stateDirectory.fileSystemRepresentation;
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
            lt::torrent_handle h = _session->add_torrent(std::move(atp), ec);
            if (ec || !h.is_valid()) continue;
            std::lock_guard<std::mutex> lock(_mutex);
            _handles[hashString(h)] = h;
        }
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
        {
            std::lock_guard<std::mutex> lock(_mutex);
            if (_handles.count(hash)) return toNS(hash);
        }
        lt::error_code ec;
        lt::torrent_handle h = _session->add_torrent(std::move(atp), ec);
        if (ec || !h.is_valid()) {
            if (error) *error = makeError(ec ? ec.message() : "The torrent could not be added.");
            return nil;
        }
        hash = hashString(h);
        {
            std::lock_guard<std::mutex> lock(_mutex);
            _handles[hash] = h;
        }
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
        h.clear_error();
        h.set_flags(lt::torrent_flags::auto_managed);
        h.resume();
    } catch (const std::exception &) {
    }
}

- (void)rechecSwarmly:(NSString *)infoHash {
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
            f.path = toNS(fs.file_path(i));
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

- (NSArray<KTEvent *> *)pollEvents {
    // libtorrent throws when a handle has gone away; never let that unwind into Swift.
    try {
        std::vector<lt::alert *> alerts;
        _session->pop_alerts(&alerts);
        NSMutableArray<KTEvent *> *out = [NSMutableArray array];
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
                if (known) writeFile([self resumePathFor:hash], lt::write_resume_data_buf(rd->params));
            } else if (lt::alert_cast<lt::save_resume_data_failed_alert>(a)) {
                --_pendingResume;
            } else if (auto *fin = lt::alert_cast<lt::torrent_finished_alert>(a)) {
                KTEvent *e = [KTEvent new];
                e.type = KTEventTypeFinished;
                e.infoHash = toNS(hashString(fin->handle));
                e.message = toNS(fin->torrent_name());
                [out addObject:e];
                fin->handle.save_resume_data(lt::torrent_handle::save_info_dict);
                ++_pendingResume;
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
        return out;
    } catch (const std::exception &) {
    }
    return @[];
}

- (void)saveResumeData {
    // libtorrent throws when a handle has gone away; never let that unwind into Swift.
    try {
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
