import XCTest
@testable import Piece

final class ReleaseNameParserTests: XCTestCase {
    func testFilm() {
        let r = ReleaseNameParser.parse("The.Matrix.1999.1080p.BluRay.x264-GROUP.mkv")
        XCTAssertEqual(r.title, "The Matrix")
        XCTAssertEqual(r.year, 1999)
        XCTAssertEqual(r.resolution, "1080p")
        XCTAssertEqual(r.source, "Blu-ray")
        XCTAssertEqual(r.group, "GROUP")
        XCTAssertFalse(r.isEpisode)
    }

    func testYearInTitle() {
        let r = ReleaseNameParser.parse("Blade Runner 2049 (2017) [2160p] [4K] [WEB]")
        XCTAssertEqual(r.title, "Blade Runner 2049")
        XCTAssertEqual(r.year, 2017)
        XCTAssertEqual(r.resolution, "2160p")

        let leading = ReleaseNameParser.parse("2001.A.Space.Odyssey.1968.720p.mkv")
        XCTAssertEqual(leading.title, "2001 A Space Odyssey")
        XCTAssertEqual(leading.year, 1968)
    }

    func testEpisodes() {
        let a = ReleaseNameParser.parse("Show.Name.S02E05.720p.WEB-DL.x265.mkv")
        XCTAssertEqual(a.title, "Show Name")
        XCTAssertEqual(a.season, 2)
        XCTAssertEqual(a.episode, 5)
        XCTAssertEqual(a.source, "WEB")

        let b = ReleaseNameParser.parse("Some Show - 3x07 - The One.avi")
        XCTAssertEqual(b.title, "Some Show")
        XCTAssertEqual(b.season, 3)
        XCTAssertEqual(b.episode, 7)

        let c = ReleaseNameParser.parse("[Group] Another Show 2019 S01E10 1080p")
        XCTAssertEqual(c.title, "Another Show")
        XCTAssertEqual(c.year, 2019)
        XCTAssertEqual(c.episode, 10)
    }

    func testPlainName() {
        XCTAssertEqual(ReleaseNameParser.parse("Sintel.mp4").title, "Sintel")
        XCTAssertEqual(ReleaseNameParser.parse("big_buck_bunny.mp4").title, "big buck bunny")
    }

    func testClassify() {
        let film = LibraryStore.classify(path: "/d/The.Matrix.1999.1080p/The.Matrix.1999.1080p.mkv", size: 4_000_000_000)
        XCTAssertEqual(film?.kind, .film)
        XCTAssertEqual(film?.title, "The Matrix")

        let episode = LibraryStore.classify(path: "/d/Show.Name.S01.720p/Show.Name.S01E03.720p.mkv", size: 900_000_000)
        XCTAssertEqual(episode?.kind, .episode)
        XCTAssertEqual(episode?.showTitle, "Show Name")
        XCTAssertEqual(episode?.season, 1)
        XCTAssertEqual(episode?.episode, 3)

        let track = LibraryStore.classify(path: "/d/Album Name/03 - Song Title.flac", size: 30_000_000)
        XCTAssertEqual(track?.kind, .track)
        XCTAssertEqual(track?.title, "Song Title")
        XCTAssertEqual(track?.trackNumber, 3)
        XCTAssertEqual(track?.album, "Album Name")

        XCTAssertNil(LibraryStore.classify(path: "/d/Movie/sample.mkv", size: 20_000_000))
        XCTAssertNil(LibraryStore.classify(path: "/d/Movie/readme.txt", size: 100))
    }

    func testBestMatchPrefersTitleAndYear() {
        let candidates = [
            MetadataMatch(title: "Solaris", year: 2002, source: "t"),
            MetadataMatch(title: "Solaris", year: 1972, source: "t"),
            MetadataMatch(title: "Solaris Rising", year: 1972, source: "t"),
        ]
        XCTAssertEqual(MetadataService.best(in: candidates, title: "Solaris", year: 1972)?.year, 1972)
        XCTAssertEqual(MetadataService.best(in: candidates, title: "solaris", year: nil)?.year, 2002)
    }
}

final class SubtitleTests: XCTestCase {
    func testSRT() {
        let srt = "1\r\n00:00:01,000 --> 00:00:03,500\r\n<i>Hello</i> there\r\nSecond line\r\n\r\n2\r\n00:01:02,250 --> 00:01:04,000\r\nBye\r\n"
        let cues = SubtitleParser.parse(srt, fileExtension: "srt")
        XCTAssertEqual(cues.count, 2)
        XCTAssertEqual(cues[0].text, "Hello there\nSecond line")
        XCTAssertEqual(cues[0].start, 1.0, accuracy: 0.001)
        XCTAssertEqual(cues[0].end, 3.5, accuracy: 0.001)
        XCTAssertEqual(cues[1].start, 62.25, accuracy: 0.001)
    }

    func testVTTAndASS() {
        let vtt = "WEBVTT\n\n00:01.000 --> 00:02.000 align:center\nHi\n\n00:03.000 --> 00:04.000\nAgain\n"
        let cues = SubtitleParser.parse(vtt, fileExtension: "vtt")
        XCTAssertEqual(cues.map(\.text), ["Hi", "Again"])
        XCTAssertEqual(cues[0].end, 2.0, accuracy: 0.001)

        let ass = """
        [Script Info]
        Title: x
        [Events]
        Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
        Dialogue: 0,0:00:05.00,0:00:07.50,Default,,0,0,0,,{\\an8}Hello, world\\NNext
        """
        let assCues = SubtitleParser.parse(ass, fileExtension: "ass")
        XCTAssertEqual(assCues.count, 1)
        XCTAssertEqual(assCues[0].text, "Hello, world\nNext")
        XCTAssertEqual(assCues[0].start, 5.0, accuracy: 0.001)
    }

    func testCueLookupAndWebVTT() {
        let cues = [SubtitleCue(start: 1, end: 2, text: "a"), SubtitleCue(start: 3, end: 5, text: "b"), SubtitleCue(start: 10, end: 11, text: "c")]
        XCTAssertNil(SubtitleParser.cue(at: 0.5, in: cues))
        XCTAssertEqual(SubtitleParser.cue(at: 1.5, in: cues)?.text, "a")
        XCTAssertNil(SubtitleParser.cue(at: 2.5, in: cues))
        XCTAssertEqual(SubtitleParser.cue(at: 4.9, in: cues)?.text, "b")
        XCTAssertEqual(SubtitleParser.cue(at: 10, in: cues)?.text, "c")
        XCTAssertNil(SubtitleParser.cue(at: 12, in: cues))

        let vtt = SubtitleParser.webVTT(from: cues, hlsTimestampMap: true)
        XCTAssertTrue(vtt.hasPrefix("WEBVTT\nX-TIMESTAMP-MAP=MPEGTS:0,LOCAL:00:00:00.000\n\n00:00:01.000 --> 00:00:02.000\na\n"))
        XCTAssertEqual(SubtitleParser.parse(vtt, fileExtension: "vtt"), cues)
    }

    func testLanguageGuess() {
        XCTAssertEqual(SubtitleLanguage.guess(fromFilename: "Sintel.en.srt"), "en")
        XCTAssertEqual(SubtitleLanguage.guess(fromFilename: "Movie.2019.1080p.spa.srt"), "es")
        XCTAssertEqual(SubtitleLanguage.guess(fromFilename: "Subs/English.srt"), "en")
        XCTAssertEqual(SubtitleLanguage.guess(fromFilename: "2_French.srt"), "fr")
        XCTAssertNil(SubtitleLanguage.guess(fromFilename: "Movie.2019.srt"))
        XCTAssertNil(SubtitleLanguage.guess(fromFilename: "Ice.Age.2002.srt"))
        XCTAssertEqual(SubtitleLanguage.guess(fromFilename: "Movie.en.forced.srt"), "en")
        XCTAssertEqual(SubtitleLanguage.guess(fromFilename: "Movie.eng.SDH.srt"), "en")
        XCTAssertEqual(SubtitleLanguage.guess(fromFilename: "Movie.en.hi.srt"), "en")
        XCTAssertEqual(SubtitleLanguage.guess(fromFilename: "Movie.hi.srt"), "hi")
        XCTAssertEqual(SubtitleLanguage.guess(fromFilename: "Movie.en.2.srt"), "en")
        XCTAssertEqual(SubtitleLanguage.guess(fromFilename: "Movie.en-US.srt"), "en")
        XCTAssertEqual(SubtitleLanguage.guess(fromFilename: "Movie.English.YIFY.srt"), "en")
    }

    func testLanguageVariants() {
        // Portuguese
        XCTAssertEqual(SubtitleLanguage.identify("pt-BR"), "pt-br")
        XCTAssertEqual(SubtitleLanguage.identify("pt_PT"), "pt-pt")
        XCTAssertEqual(SubtitleLanguage.identify("pob"), "pt-br")
        XCTAssertEqual(SubtitleLanguage.identify("por"), "pt")
        XCTAssertEqual(SubtitleLanguage.identify("Português"), "pt")
        XCTAssertEqual(SubtitleLanguage.identify("pt-AO"), "pt-pt")
        XCTAssertEqual(SubtitleLanguage.guess(fromFilename: "Movie.pt-BR.srt"), "pt-br")
        XCTAssertEqual(SubtitleLanguage.guess(fromFilename: "Movie.pt-PT.forced.srt"), "pt-pt")
        XCTAssertEqual(SubtitleLanguage.guess(fromFilename: "Movie.por.srt"), "pt")
        XCTAssertEqual(SubtitleLanguage.guess(fromFilename: "Subs/3_Brazilian.Portuguese.srt"), "pt-br")
        XCTAssertEqual(SubtitleLanguage.guess(fromFilename: "Movie.Portuguese (Brazil).srt"), "pt-br")
        XCTAssertEqual(SubtitleLanguage.guess(fromFilename: "Movie.ptbr.srt"), "pt-br")
        XCTAssertEqual(SubtitleLanguage.identify(tag: "por", title: "Brazilian"), "pt-br")
        XCTAssertEqual(SubtitleLanguage.identify(tag: "por", title: "Português (Portugal)"), "pt-pt")
        XCTAssertEqual(SubtitleLanguage.identify(tag: "por", title: "European Portuguese [Forced]"), "pt-pt")
        XCTAssertEqual(SubtitleLanguage.identify(tag: "por", title: "SDH"), "pt")
        XCTAssertEqual(SubtitleLanguage.identify(tag: nil, title: "Português do Brasil"), "pt-br")

        // Spanish
        XCTAssertEqual(SubtitleLanguage.identify("es-419"), "ea")
        XCTAssertEqual(SubtitleLanguage.identify("es-MX"), "ea")
        XCTAssertEqual(SubtitleLanguage.identify("es-ES"), "sp")
        XCTAssertEqual(SubtitleLanguage.identify("spa"), "es")
        XCTAssertEqual(SubtitleLanguage.guess(fromFilename: "Movie.Spanish.Latin.srt"), "ea")
        XCTAssertEqual(SubtitleLanguage.guess(fromFilename: "Movie.Latino.srt"), "ea")
        XCTAssertEqual(SubtitleLanguage.identify(tag: "spa", title: "Español (Latinoamérica)"), "ea")
        XCTAssertEqual(SubtitleLanguage.identify(tag: "spa", title: "Castellano"), "sp")

        // Chinese
        XCTAssertEqual(SubtitleLanguage.identify("zh-Hant-TW"), "zh-tw")
        XCTAssertEqual(SubtitleLanguage.identify("zh-HK"), "zh-tw")
        XCTAssertEqual(SubtitleLanguage.identify("chi"), "zh")
        XCTAssertEqual(SubtitleLanguage.guess(fromFilename: "Movie.chs.srt"), "zh-cn")
        XCTAssertEqual(SubtitleLanguage.guess(fromFilename: "Movie.chs&eng.srt"), "ze")
        XCTAssertEqual(SubtitleLanguage.guess(fromFilename: "Movie.zh-Hans.srt"), "zh-cn")
        XCTAssertEqual(SubtitleLanguage.identify(tag: "chi", title: "简体中文字幕"), "zh-cn")
        XCTAssertEqual(SubtitleLanguage.identify(tag: "chi", title: "Traditional"), "zh-tw")
        XCTAssertEqual(SubtitleLanguage.identify(tag: "chi", title: "中英双语"), "ze")

        // Others keep their region-free code.
        XCTAssertEqual(SubtitleLanguage.identify("en-GB"), "en")
        XCTAssertEqual(SubtitleLanguage.identify("nob"), "no")
        XCTAssertEqual(SubtitleLanguage.identify("fa-AF"), "pr")
        XCTAssertEqual(SubtitleLanguage.name(for: "por"), "Portuguese")
        XCTAssertEqual(SubtitleLanguage.badge(for: "ea"), "ES-419")
    }

    func testLanguageMatching() {
        typealias L = SubtitleLanguage
        XCTAssertEqual(L.match("pt-pt", preference: "pt-pt"), .exact)
        XCTAssertNil(L.match("pt-br", preference: "pt-pt"))
        XCTAssertEqual(L.match("pt", preference: "pt-pt"), .unlabeledVariant)
        XCTAssertEqual(L.match("pt-br", preference: "pt"), .exact)
        XCTAssertEqual(L.match("pt", preference: "pt"), .exact)
        XCTAssertEqual(L.match("es", preference: "sp"), .unlabeledVariant)
        XCTAssertEqual(L.match("ea", preference: "es"), .exact)
        XCTAssertNil(L.match("ea", preference: "sp"))
        XCTAssertNil(L.match(nil, preference: "en"))

        // Exact matches for any preference beat an unlabeled variant of the first.
        let tracks = ["pt", "en", "pt-br"]
        XCTAssertEqual(L.best(tracks, for: ["pt-pt", "en"], language: { $0 }), "en")
        XCTAssertEqual(L.best(["pt", "fr"], for: ["pt-pt", "en"], language: { $0 }), "pt")
        XCTAssertNil(L.best(["pt-br", "fr"], for: ["pt-pt", "en"], language: { $0 }))
        XCTAssertEqual(L.best(tracks, for: ["pt", "en"], language: { $0 }), "pt")
        XCTAssertEqual(L.best(["en", "pt-br"], for: ["pt-pt", "pt", "en"], language: { $0 }), "pt-br")

        XCTAssertEqual(L.searchCodes(for: ["pt-pt", "en"]), ["en", "pt-pt"])
        XCTAssertEqual(L.searchCodes(for: ["pt"]), ["pm", "pt-br", "pt-pt"])
        XCTAssertEqual(L.searchCodes(for: ["sp"]), ["es", "sp"])
        XCTAssertEqual(L.searchCodes(for: ["es"]), ["ea", "es", "sp"])
        XCTAssertEqual(L.searchCodes(for: ["zh-tw"]), ["zh-tw"])

        func result(_ id: Int, _ language: String, hash: Bool = false, downloads: Int = 0) -> OnlineSubtitle {
            OnlineSubtitle(fileID: id, language: language, release: "", downloads: downloads, hashMatch: hash, hearingImpaired: false)
        }
        let sorted = OpenSubtitles.sorted([result(1, "es", hash: true), result(2, "en"), result(3, "sp", downloads: 5),
                                           result(4, "sp", hash: true)], for: ["sp", "en"])
        XCTAssertEqual(sorted.map(\.fileID), [4, 3, 2, 1])
    }

    func testLanguagePreferences() {
        typealias L = SubtitleLanguage
        XCTAssertEqual(L.defaultPreferences(systemLanguages: ["pt-PT", "en-PT"]), ["pt-pt", "en"])
        XCTAssertEqual(L.defaultPreferences(systemLanguages: ["zh-Hant-TW"]), ["zh-tw"])
        XCTAssertEqual(L.defaultPreferences(systemLanguages: ["tlh"]), ["en"])
        XCTAssertEqual(L.migrate(["pt", "en"], systemLanguages: ["pt-PT", "en"]), ["pt-pt", "en"])
        XCTAssertEqual(L.migrate(["pt", "en"], systemLanguages: ["en-US"]), ["pt", "en"])
        XCTAssertEqual(L.migrate(["zh", "es"], systemLanguages: ["zh-Hans-CN"]), ["zh-cn", "es"])
        XCTAssertEqual(L.migrate(["xx"], systemLanguages: ["fr-FR"]), ["fr"])
        XCTAssertEqual(L.validated(["pt-pt", "xx", "pt-pt", "en"]), ["pt-pt", "en"])
    }

    func testLanguageCatalog() {
        let ids = SubtitleLanguage.all.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count, "Duplicate language ids")
        // Everything OpenSubtitles lists, plus the Portuguese and Chinese families.
        XCTAssertEqual(SubtitleLanguage.all.filter(\.isOnline).count, 105)
        XCTAssertEqual(Set(SubtitleLanguage.all.filter { !$0.isOnline }.map(\.id)), ["pt", "zh"])
        for language in SubtitleLanguage.all {
            for variant in language.variants { XCTAssertEqual(SubtitleLanguage[variant]?.family, language.id) }
            XCTAssertEqual(SubtitleLanguage.identify(language.id), language.id)
        }
        XCTAssertEqual(SubtitleLanguage["pt"]?.preferenceName, "Portuguese (any variant)")
        XCTAssertEqual(SubtitleLanguage["pt"]?.note, "Portugal, Brazil or Mozambique")
        XCTAssertEqual(SubtitleLanguage["pt-br"]?.nativeName, "Português (Brasil)")
    }

    func testSubtitleStyle() {
        XCTAssertEqual(SubtitleStyle.hex(of: SubtitleStyle.color(hex: "#7FD4FF")!), "#7FD4FF")
        XCTAssertEqual(SubtitleStyle.hex(of: SubtitleStyle.color(hex: "ff0000")!), "#FF0000")
        XCTAssertNil(SubtitleStyle.color(hex: "#12345"))

        // The system font at each weight, upright and italic.
        let bold = SubtitleStyle(fontFace: "bold-italic").nsFont(size: 20)
        XCTAssertTrue(bold.fontDescriptor.symbolicTraits.contains(.italic))
        XCTAssertTrue(bold.fontDescriptor.symbolicTraits.contains(.bold))
        XCTAssertEqual(SubtitleStyle().fontDescription, "System Semibold")

        // Switching family keeps the nearest face.
        let boldItalic = SubtitleTypeface.Face(id: "bold-italic", name: "Bold Italic", weight: 9, isItalic: true)
        let georgia = SubtitleTypeface.closest(to: boldItalic, in: "Georgia")
        XCTAssertEqual(georgia?.id, "Georgia-BoldItalic")
        XCTAssertEqual(SubtitleStyle(fontFamily: "Georgia", fontFace: "Georgia-BoldItalic").fontDescription, "Georgia Bold Italic")
        XCTAssertTrue(SubtitleTypeface.families.contains("Georgia"))
        XCTAssertFalse(SubtitleTypeface.families.contains("Webdings"))

        // A removed font falls back to the system font.
        let missing = SubtitleStyle(fontFamily: "No Such Font", fontFace: "NoSuchFont-Bold").nsFont(size: 20)
        XCTAssertEqual(missing.familyName, NSFont.systemFont(ofSize: 20).familyName)
    }

    func testFinder() {
        let paths = ["Sintel/Sintel.mp4", "Sintel/Sintel.en.srt", "Sintel/Sintel.de.srt", "Sintel/poster.jpg"]
        XCTAssertEqual(SubtitleFinder.matches(forVideo: "Sintel/Sintel.mp4", among: paths), ["Sintel/Sintel.en.srt", "Sintel/Sintel.de.srt"])

        let season = ["S/Ep.S01E01.mkv", "S/Ep.S01E02.mkv", "S/Ep.S01E01.srt", "S/Ep.S01E02.srt",
                      "S/Subs/Ep.S01E02/2_English.srt", "S/Subs/Ep.S01E01/2_English.srt"]
        XCTAssertEqual(SubtitleFinder.matches(forVideo: "S/Ep.S01E02.mkv", among: season),
                       ["S/Ep.S01E02.srt", "S/Subs/Ep.S01E02/2_English.srt"])

        let film = ["Movie/Movie.mkv", "Movie/Subs/English.srt", "Movie/Subs/Spanish.srt"]
        XCTAssertEqual(SubtitleFinder.matches(forVideo: "Movie/Movie.mkv", among: film).count, 2)
    }

    func testMovieHash() {
        let zeros = Data(count: OpenSubtitles.chunkSize)
        XCTAssertEqual(OpenSubtitles.hash(size: 131_072, head: zeros, tail: zeros), "0000000000020000")
        var head = zeros
        head[0] = 1          // adds 1
        head[15] = 0x80      // adds 0x80 << 56 in the second word
        XCTAssertEqual(OpenSubtitles.hash(size: 131_072, head: head, tail: zeros), "8000000000020001")
    }
}

final class StreamingUnitTests: XCTestCase {
    func testByteRanges() {
        XCTAssertEqual(HTTPRequest.byteRange(header: nil, size: 100), 0...99)
        XCTAssertEqual(HTTPRequest.byteRange(header: "bytes=0-", size: 100), 0...99)
        XCTAssertEqual(HTTPRequest.byteRange(header: "bytes=10-19", size: 100), 10...19)
        XCTAssertEqual(HTTPRequest.byteRange(header: "bytes=90-500", size: 100), 90...99)
        XCTAssertEqual(HTTPRequest.byteRange(header: "bytes=-10", size: 100), 90...99)
        XCTAssertNil(HTTPRequest.byteRange(header: "bytes=100-", size: 100))
        XCTAssertNil(HTTPRequest.byteRange(header: "bytes=20-10", size: 100))
    }

    func testRequestParsing() {
        let request = HTTPRequest(head: "GET /abc/t/hash/0/file.mp4 HTTP/1.1\r\nHost: x\r\nRange: bytes=5-\r\n")
        XCTAssertEqual(request?.method, "GET")
        XCTAssertEqual(request?.path, "/abc/t/hash/0/file.mp4")
        XCTAssertEqual(request?.headers["range"], "bytes=5-")
        XCTAssertNil(HTTPRequest(head: "garbage"))
    }

    func testHLSArguments() {
        let json = """
        {"format":{"duration":"120.5","tags":{"TITLE":"x"}},"streams":[
          {"index":0,"codec_type":"video","codec_name":"hevc","width":3840,"height":2160,"disposition":{"default":1}},
          {"index":1,"codec_type":"audio","codec_name":"dts","channels":6,"tags":{"language":"eng"},"disposition":{"default":1}},
          {"index":2,"codec_type":"audio","codec_name":"aac","channels":2,"tags":{"language":"spa"}},
          {"index":3,"codec_type":"subtitle","codec_name":"subrip","tags":{"language":"eng","title":"SDH"}}]}
        """
        let probe = MediaProbe.parse(Data(json.utf8))
        XCTAssertEqual(probe?.duration, 120.5)
        XCTAssertEqual(probe?.audio.count, 2)
        XCTAssertEqual(probe?.subtitles.first?.title, "SDH")
        XCTAssertEqual(probe?.tags["title"], "x")

        let copyVideo = HLSSession.arguments(input: "in.mkv", probe: probe, audioStream: nil, startTime: 0, outputDirectory: "/tmp/o")
        XCTAssertTrue(copyVideo.joined(separator: " ").contains("-map 0:0 -c:v copy -tag:v hvc1"))
        XCTAssertTrue(copyVideo.joined(separator: " ").contains("-map 0:1 -c:a aac -b:a 384k"), "DTS must be re-encoded")

        let copyAudio = HLSSession.arguments(input: "in.mkv", probe: probe, audioStream: 2, startTime: 30, outputDirectory: "/tmp/o")
        XCTAssertTrue(copyAudio.joined(separator: " ").contains("-map 0:2 -c:a copy"))
        XCTAssertTrue(copyAudio.joined(separator: " ").hasPrefix("-hide_banner -loglevel warning -nostdin -ss 30.000"))

        let master = HLSSession.masterPlaylist(subtitleName: "English", language: "en")
        XCTAssertTrue(master.contains("TYPE=SUBTITLES"))
        XCTAssertTrue(master.contains("SUBTITLES=\"subs\"\nmedia.m3u8"))
        XCTAssertFalse(HLSSession.masterPlaylist(subtitleName: nil, language: nil).contains("SUBTITLES"))
    }
}

final class TrackerListTests: XCTestCase {
    func testParseSkipsCommentsAndBlankLines() {
        let text = """
        # Best trackers
        udp://tracker.opentrackr.org:1337/announce

          https://tracker.example.org/announce   # trailing comment
        #udp://disabled.example.org:80
        \r
        udp://open.stealth.si:80/announce\r
        """
        XCTAssertEqual(TrackerList.parse(text), [
            "udp://tracker.opentrackr.org:1337/announce",
            "https://tracker.example.org/announce",
            "udp://open.stealth.si:80/announce",
        ])
    }

    func testKeyIgnoresCaseAndTrailingSlash() {
        XCTAssertEqual(TrackerList.key(" UDP://Tracker.Example.org:80/announce/ "),
                       TrackerList.key("udp://tracker.example.org:80/announce"))
    }

    func testValidity() {
        XCTAssertTrue(TrackerList.isValid("udp://tracker.example.org:1337/announce"))
        XCTAssertTrue(TrackerList.isValid("wss://tracker.example.org"))
        XCTAssertFalse(TrackerList.isValid("tracker.example.org:1337"))
        XCTAssertFalse(TrackerList.isValid("ftp://tracker.example.org"))
        XCTAssertFalse(TrackerList.isValid("udp://"))
    }
}
