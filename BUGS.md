# Bugs

Found by reading the source, on `main` at `ed3377f`. Most severe first. Each entry says where the bug is, what goes wrong, and how sure the finding is:

- **Confirmed**: the code path is unambiguous, or I reproduced it with a standalone run.
- **Likely**: depends on libtorrent or AppKit behaviour that should be checked in the running app.

---

## High

### 1. A large number in the port field crashes the app, and it keeps crashing at every launch
`Support/AppSettings.swift:201`, `UI/Settings/NetworkSettings.swift:55`. **Confirmed**

The "Incoming port" field is an unvalidated `Int` text field. `sessionSettings` converts the value with `Int32(listenPort)`, which traps when the value doesn't fit in an `Int32`. Typing `9999999999` crashes the app as soon as the change is applied. The value is already saved in UserDefaults by then, and `TorrentStore.init` builds `sessionSettings` at startup, so every later launch crashes too. Values that do fit but are out of range (`70000`, `-1`) don't crash, but libtorrent can't listen on them and incoming connections stop without any message.

**Fix:** clamp the port to `1...65535` (or `0` for "random") in the setter, and build the setting with `Int32(clamping:)`.

### 2. Every completed transfer fires "Download complete" again at each launch
`Engine/TorrentStore.swift:134`, which calls `AppModel.torrentFinished` (`App/AppModel.swift:282`). **Likely**

The code comment notes that libtorrent posts `torrent_finished_alert` again when a completed torrent is restored. The guard meant to filter those out is `torrent.totalDownloaded > 0 || added < 60 s ago`. But `totalDownloaded` is `all_time_download`, which is stored in the resume data, so it is above 0 for every torrent Piece itself downloaded. The guard only filters out torrents seeded from data that was already on disk.

Effect at each launch, for every finished torrent still in the list:
- a "Download complete" notification and a Dock bounce
- a library import pass (duplicates are skipped)
- when "compress on complete" is on, another `ditto` rewrite attempt on each file

**Fix:** track which torrents were seen incomplete during this session, and only treat a finished event as new for those.

### 3. "Remove Missing Files" deletes packed items, and the archives stay on disk with nothing pointing to them
`Library/LibraryStore.swift:68`, `Library/MediaItem.swift:52`, `Storage/CompressionService.swift:113`. **Confirmed**

Packing deletes the original file but leaves `item.path` unchanged, so `fileExists` is false for every packed item. As a result:
- **Library → Remove Missing Files** removes all packed items. Their `.piecepack` archives stay in `Application Support/Piece/Packs`, and nothing in the app references them any more: the data can't be reached and the disk space is never freed.
- **Remove from Library** and **Move to Trash** on a packed item (`LibraryStore.remove`, line 58) also leave its archive behind. Move to Trash tries to trash the original path, which no longer exists.

**Fix:** count a packed item as present when its pack file exists. When a packed item is removed, delete its archive (or move it to the Trash).

### 4. Hybrid (v1+v2) torrents are tracked under an info-hash that can change
`TorrentBridge/TorrentBridge.mm:78-88`, `:478`, `:1134`. **Likely**

Torrents are keyed by `info_hashes().get_best()`, which is the v2 hash whenever one is known. When a hybrid torrent is added from a v1-only magnet, `_handles` stores it under the v1 hash. Once the metadata arrives, the handle also knows its v2 hash. After that, these all compute the v2 hash and no longer match the stored key:
- `save_resume_data_alert` (`known` is false)
- finished, error and rename events
- `hashString(h)` in `reconcilePartNames`

The likely results:
- the resume file is never written, so the transfer is gone after a relaunch
- finished and error events never reach the Swift side
- `.part` renames are attributed to the wrong key

**Fix:** use a stable ID: the v1 hash when there is one, which is what qBittorrent does. Use the same ID for the map key and in every alert handler.

---

## Medium

### 5. In the Add Torrent sheet, the chosen "Save to" folder only applies to magnet links
`UI/TransfersView.swift:264-268`, `Engine/TorrentStore.swift:183`. **Confirmed**

`add()` passes `folder` only on the `magnet:` branch. Torrent URLs and bare info-hashes go through `add(link:)`, which has no `savePath` parameter and always uses the default download folder.

### 6. Resuming a converted (MKV/AVI/…) video, or switching its audio track, restarts conversion from 0:00
`Player/PlayerModel.swift:338`, `:391-404`, `Streaming/MediaTools.swift:214`. **Confirmed**

`HLSSession.start` supports `startTime` (it passes `-ss` to ffmpeg and shifts the subtitles), but no caller passes it. To resume at 45:00, ffmpeg starts at 0, and `seek(to:)` polls for at most 60 s for the playlist to reach the position. If ffmpeg hasn't got there by then (likely when re-encoding, or when the torrent is still downloading), the player seeks past the end of what exists. The same restart happens on every `reopen`: when AirPlay connects with subtitles on, when the audio track changes, and when subtitles are turned off.

### 7. Playing a queued transfer waits forever
`Player/PlayerModel.swift:159`. **Likely**

`play()` resumes the torrent only when `phase == .paused`. A torrent in the `.queued` phase (auto-managed, beyond the active-download limit) stays paused by libtorrent's queue. Setting piece deadlines doesn't start it, so the player shows "Waiting for the first pieces…" with no end.

### 8. Resume files are overwritten even when the write fails
`TorrentBridge/TorrentBridge.mm:127-134`. **Confirmed**

`writeFile` writes to a `.tmp` file without checking that the write succeeded, then renames it over the real file. On a full disk this replaces a good `.fastresume` with a truncated one. At the next launch `restoreTorrents` can't parse it and skips it, and the transfer is gone. `session.state` is written the same way.

**Fix:** check `f.good()` after the write and close (and ideally `fsync`) before the rename.

### 9. Blocklist lines whose name contains a comma are dropped
`TorrentBridge/TorrentBridge.mm:226-234`. **Confirmed**

Any line containing a comma is treated as eMule `.dat` format. A PeerGuardian line such as `China Internet Network Information Center, CNNIC:1.2.0.0-1.2.255.255` therefore fails `parseRange("China Internet…")` and is skipped. Common lists (level1 and similar) contain many organisation names with commas, so large parts of those lists are never blocked. The rule count shown in Settings is lower than it should be, but nothing says why.

**Fix:** try the PeerGuardian `name:range` form first when the part before the first comma doesn't parse as a range.

### 10. Sizes with thousands separators or 5+ digits are misread
`Search/SearchModels.swift:115-116`. **Confirmed** (standalone run)

The pattern `\d{1,4}(?:[.,]\d{1,3})?` has no leading boundary and treats a comma as the decimal separator:

| Input | Parsed as |
|---|---|
| `1,234.5 MB` | 234.5 MiB |
| `12345 MB` | 2345 MiB |

Every scraped HTML or feed result that writes sizes this way shows a wrong size, sorts wrongly, and lands in the wrong size-band filter.

### 11. "Show/Season 1/01 - Pilot.mkv" is imported as a film
`Library/ReleaseNameParser.swift:78`, `Library/LibraryStore.swift:162`. **Confirmed** (standalone run)

`seasonOnly` requires `m.range.location > 0`, so a folder named just `Season 1` yields `season == nil`. Files named `01 - Pilot.mkv` inside it then fall through to the film branch and are titled "01 - Pilot". This is one of the most common folder layouts. Even when a season is found, the show title is taken from the immediate folder ("Season 1"), not from the folder above it.

### 12. Packing an "Other" item that is a folder always fails
`Storage/CompressionService.swift:94`, `App/AppModel.swift:318`, `UI/StorageViews.swift:13`. **Confirmed**

Multi-file "Other" downloads are stored as their root folder. `fileExists` is true for a directory, so **Pack to Save Space…** is offered, and `packStaleItems` picks these folders when they're over 50 MB. `PackFormat.pack` then opens the folder with `FileHandle` and the first read fails, giving "Couldn't pack …". With auto-pack on, this error comes back every launch for each stale folder item.

### 13. A corrupt `.piecepack` can crash the app
`Storage/PackFormat.swift:111-112`. **Confirmed**

`guard length < end` doesn't account for the 16-byte footer. Any `length` greater than `end - 16` makes `end - magic.count - 8 - length` underflow `UInt64`, which traps. Unpacking or verifying a damaged pack should throw `.corrupt`, not crash.

**Fix:** `guard length <= end - UInt64(magic.count * 2 + 8)`.

### 14. Selecting two quality filters returns no results
`Search/SearchRefine.swift:82`. **Confirmed**

`filter.qualities.isSubset(of: result.qualities)` requires a result to have every selected quality, so choosing both 1080p and 720p matches nothing. Resolutions are mutually exclusive and should be OR'ed. HDR and x265 can stay AND'ed.

### 15. ⌘← / ⌘→ (and ⌥⌘← / ⌥⌘→) no longer move the cursor in text fields
`App/PieceApp.swift:110-113`. **Likely**

The Playback menu's skip items use these key equivalents and stay enabled while nothing is playing. Menu key equivalents are matched before the text field handles the key, so in the search box, the Add Torrent sheet and the settings fields, ⌘← calls `skip(by:)` (which does nothing) instead of moving to the start of the line.

**Fix:** disable these items when `player.item == nil`, or use different shortcuts.

---

## Low

### 16. Quickly clicking Resume and then Pause can leave the transfer running
`Engine/TorrentStore.swift:212-225`. **Confirmed**

`resume` runs `resumeTorrent` asynchronously on the engine queue, but `pause` calls `pauseTorrent` synchronously on the main thread. If the queued resume hasn't run yet, it runs after the pause and the user's last action is undone. Both should go through `queue`.

### 17. The toolbar Pause/Resume button inverts each transfer on mixed selections
`UI/RootView.swift:88-92`. **Confirmed**

The label says "Pause" unless every selected transfer is paused, held or completed, but the action calls `toggle` on each transfer. With a mix selected, it pauses the active ones and resumes the paused ones. The label also ignores `.error`, which `toggle` treats as resumable.

### 18. The OpenSubtitles login token is never refreshed
`Subtitles/OpenSubtitles.swift:103-108`. **Likely**

The token is fetched once and kept for the life of the process. OpenSubtitles tokens expire (after about 24 h). After that, every download sends a stale `Bearer` token and fails until the app is relaunched. On a 401 the client should clear `token` and retry once.

### 19. Episodes whose names contain "trailer" or "sample" are left out of the library
`Library/LibraryStore.swift:155`. **Confirmed**

Any video under 200 MB whose file name contains "trailer" or "sample" is treated as an extra, so for example SD episodes of *Trailer Park Boys* are never imported. Matching these as separate words, or only when the parser finds no episode number, would avoid this.

### 20. Ogg/Opus/WMA tracks with embedded cover art may not play, and a failed track stops the queue
`Player/AudioPlayer.swift:70`, `Streaming/MediaTools.swift:156-157`. **Likely**

`AudioPlayer` starts HLS with `probe: nil`, which maps `0:v:0?` with `-c:v copy`. A cover-art stream (MJPEG/PNG) is then copied into fMP4, which ffmpeg or AVPlayer rejects. `AudioPlayer` doesn't watch the item's status, so a failed track never moves on to `next()`.

**Fix:** use `-vn` for audio-only playback, and skip to the next track when an item fails.

### 21. A removed transfer can briefly reappear
`Engine/TorrentStore.swift:235-239`. **Confirmed**

`remove` updates `torrents` at once. A `refresh` whose `statuses()` call ran on the engine queue just before the removal then re-creates the `Torrent` in `apply`, and it disappears again on the next tick. If an inspector or selection was showing the row, it now refers to a different object.

### 22. Automatic online subtitle search only runs with your own API key
`Player/PlayerModel.swift:572`. **Confirmed**

Auto-search is skipped when `settings.openSubtitlesKey` is empty, but `OpenSubtitles.request` falls back to `BuiltInKeys.openSubtitles`. Builds with a built-in key never auto-search. This might be deliberate, to save the shared quota; if so, a comment would make that clear.

### 23. The row button's tooltip says "Pause" for transfers in error
`UI/TransfersView.swift:136`. **Confirmed**

For `.error`, `canResume` is true, so the button resumes and shows the resume icon, but its help text says "Pause".
