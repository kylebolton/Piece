#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, KTTorrentState) {
    KTTorrentStateChecking = 0,
    KTTorrentStateFetchingMetadata,
    KTTorrentStateDownloading,
    KTTorrentStateFinished,
    KTTorrentStateSeeding,
};

typedef NS_ENUM(NSInteger, KTEventType) {
    KTEventTypeFinished = 0,
    KTEventTypeMetadataReceived,
    KTEventTypeError,
};

NS_SWIFT_SENDABLE
@interface KTTorrentStatus : NSObject
@property (nonatomic, copy) NSString *infoHash;
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) NSString *savePath;
@property (nonatomic, copy, nullable) NSString *errorMessage;
@property (nonatomic) KTTorrentState state;
@property (nonatomic) BOOL paused;
@property (nonatomic) BOOL autoManaged;
@property (nonatomic) BOOL hasMetadata;
@property (nonatomic) BOOL sequential;
@property (nonatomic) float progress;
@property (nonatomic) int64_t totalSize;
@property (nonatomic) int64_t totalWanted;
@property (nonatomic) int64_t totalWantedDone;
@property (nonatomic) int64_t totalDownloaded;
@property (nonatomic) int64_t totalUploaded;
@property (nonatomic) int downloadRate;
@property (nonatomic) int uploadRate;
@property (nonatomic) int numPeers;
@property (nonatomic) int numSeeds;
@property (nonatomic) int numPieces;
@property (nonatomic) int pieceLength;
@property (nonatomic) NSTimeInterval addedTime;
@property (nonatomic) NSTimeInterval completedTime;
@end

NS_SWIFT_SENDABLE
@interface KTFileEntry : NSObject
@property (nonatomic) int index;
@property (nonatomic, copy) NSString *path;
@property (nonatomic) int64_t size;
@property (nonatomic) int64_t downloaded;
@property (nonatomic) int priority;
@end

NS_SWIFT_SENDABLE
@interface KTPeerInfo : NSObject
@property (nonatomic, copy) NSString *address;
@property (nonatomic, copy) NSString *client;
@property (nonatomic) float progress;
@property (nonatomic) int downloadRate;
@property (nonatomic) int uploadRate;
@property (nonatomic) BOOL isSeed;
@end

NS_SWIFT_SENDABLE
@interface KTTrackerInfo : NSObject
@property (nonatomic, copy) NSString *url;
@property (nonatomic, copy) NSString *message;
@property (nonatomic) int tier;
@property (nonatomic) int seeds;
@property (nonatomic) int leechers;
@property (nonatomic) BOOL working;
@property (nonatomic) BOOL updating;
@end

NS_SWIFT_SENDABLE
@interface KTEvent : NSObject
@property (nonatomic) KTEventType type;
@property (nonatomic, copy) NSString *infoHash;
@property (nonatomic, copy) NSString *message;
@end

NS_SWIFT_SENDABLE
@interface KTSessionSettings : NSObject
@property (nonatomic) int listenPort;
@property (nonatomic) int downloadRateLimit;   // bytes/s, 0 = unlimited
@property (nonatomic) int uploadRateLimit;     // bytes/s, 0 = unlimited
@property (nonatomic) int maxActiveDownloads;
@property (nonatomic) int maxActiveSeeds;
@property (nonatomic) int maxConnections;
@property (nonatomic) BOOL enableDHT;
@property (nonatomic) BOOL enableLSD;
@property (nonatomic) BOOL enablePortMapping;
@property (nonatomic) BOOL requireEncryption;
@end

/// Thin wrapper around a libtorrent session. All methods are thread-safe.
NS_SWIFT_SENDABLE
@interface KTSession : NSObject

- (instancetype)initWithStateDirectory:(NSString *)stateDirectory
                              settings:(KTSessionSettings *)settings NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

- (void)applySettings:(KTSessionSettings *)settings;

/// Builds a .torrent for a file or folder on disk. Returns nil if it can't be read.
+ (nullable NSData *)createTorrentForPath:(NSString *)path;

/// Restores every torrent saved in the state directory.
- (void)restoreTorrents;

- (nullable NSString *)addMagnet:(NSString *)magnet
                        savePath:(NSString *)savePath
                           error:(NSError **)error;
- (nullable NSString *)addTorrentData:(NSData *)data
                             savePath:(NSString *)savePath
                                error:(NSError **)error;

- (void)removeTorrent:(NSString *)infoHash deleteFiles:(BOOL)deleteFiles;
- (void)pauseTorrent:(NSString *)infoHash;
- (void)resumeTorrent:(NSString *)infoHash;
- (void)recheckTorrent:(NSString *)infoHash;
- (void)reannounceTorrent:(NSString *)infoHash;
- (void)setSequential:(BOOL)sequential forTorrent:(NSString *)infoHash;

- (NSArray<KTTorrentStatus *> *)statuses;
- (NSArray<KTFileEntry *> *)filesForTorrent:(NSString *)infoHash;
- (NSArray<KTPeerInfo *> *)peersForTorrent:(NSString *)infoHash;
- (NSArray<KTTrackerInfo *> *)trackersForTorrent:(NSString *)infoHash;
- (void)setPriority:(int)priority forFile:(int)fileIndex inTorrent:(NSString *)infoHash;

/// One byte per piece: 1 when the piece has been downloaded and verified.
- (NSData *)pieceMapForTorrent:(NSString *)infoHash;

/// Number of verified bytes available on disk starting at `offset` in the file.
- (int64_t)contiguousBytesInTorrent:(NSString *)infoHash file:(int)fileIndex offset:(int64_t)offset;
/// Asks for the pieces covering `window` bytes from `offset` to be downloaded first.
- (void)prioritizeTorrent:(NSString *)infoHash file:(int)fileIndex offset:(int64_t)offset window:(int64_t)window;
- (void)clearDeadlinesForTorrent:(NSString *)infoHash;

- (nullable NSString *)magnetLinkForTorrent:(NSString *)infoHash;
- (nullable NSData *)torrentDataForTorrent:(NSString *)infoHash;

/// Drains pending libtorrent alerts and returns the ones the app cares about.
- (NSArray<KTEvent *> *)pollEvents;

/// Requests resume data for torrents that changed since the last save.
- (void)saveResumeData;
/// Blocks until all resume data and session state are written. Call on quit.
- (void)shutdown;

@end

NS_ASSUME_NONNULL_END
