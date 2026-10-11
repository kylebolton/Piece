import XCTest
@testable import Piece

final class SearchTests: XCTestCase {
    func testMagnetHelpers() {
        let hex = "08ada5a7a6183aae1e09d831df6748d566095a10"
        XCTAssertEqual(Magnet.infoHash(from: "magnet:?xt=urn:btih:\(hex.uppercased())&dn=Sintel"), hex)
        XCTAssertEqual(Magnet.infoHash(from: "magnet:?xt=urn:btih:BCW2LJ5GDA5K4HQJ3AY56Z2I2VTASWQQ"), hex)
        XCTAssertNil(Magnet.infoHash(from: "magnet:?dn=nothing"))
        XCTAssertEqual(Magnet.displayName(from: "magnet:?xt=urn:btih:\(hex)&dn=Big+Buck%20Bunny"), "Big Buck Bunny")
    }

    func testSizes() {
        XCTAssertEqual(SizeParser.bytes(in: "Size 1.5 GB, uploaded"), Int64(1.5 * 1_073_741_824))
        XCTAssertEqual(SizeParser.bytes(in: "700 MiB"), 700 * 1_048_576)
        XCTAssertEqual(SizeParser.bytes(in: "350,5 MB"), Int64(350.5 * 1_048_576))
        XCTAssertNil(SizeParser.bytes(in: "no size here 2024"))
    }

    func testTorznabFeed() {
        let xml = """
        <?xml version="1.0"?>
        <rss xmlns:torznab="http://torznab.com/schemas/2015/feed"><channel>
          <item>
            <title>Ubuntu 24.04 Desktop</title>
            <guid>https://example.org/details/1</guid>
            <link>https://example.org/dl/1.torrent</link>
            <pubDate>Thu, 25 Apr 2024 10:00:00 +0000</pubDate>
            <size>6114656256</size>
            <enclosure url="https://example.org/dl/1.torrent" length="6114656256" type="application/x-bittorrent"/>
            <torznab:attr name="seeders" value="120"/>
            <torznab:attr name="peers" value="150"/>
            <torznab:attr name="infohash" value="ABCDEFABCDEFABCDEFABCDEFABCDEFABCDEFABCD"/>
          </item>
          <item>
            <title>Magnet only</title>
            <link>magnet:?xt=urn:btih:08ada5a7a6183aae1e09d831df6748d566095a10&amp;dn=x</link>
            <torznab:attr name="seeders" value="3"/>
          </item>
        </channel></rss>
        """
        let results = FeedParser.parse(Data(xml.utf8), provider: "Test")
        XCTAssertEqual(results.count, 2)
        XCTAssertEqual(results[0].title, "Ubuntu 24.04 Desktop")
        XCTAssertEqual(results[0].size, 6_114_656_256)
        XCTAssertEqual(results[0].seeders, 120)
        XCTAssertEqual(results[0].leechers, 30)
        XCTAssertEqual(results[0].torrentURL?.absoluteString, "https://example.org/dl/1.torrent")
        XCTAssertEqual(results[0].infoHash, "abcdefabcdefabcdefabcdefabcdefabcdefabcd")
        XCTAssertEqual(results[0].detailsURL?.absoluteString, "https://example.org/details/1")
        XCTAssertNotNil(results[0].date)
        XCTAssertEqual(results[1].infoHash, "08ada5a7a6183aae1e09d831df6748d566095a10")
        XCTAssertTrue(results[1].magnet?.hasPrefix("magnet:?xt=") == true)
    }

    func testNyaaStyleFeed() {
        let xml = """
        <rss xmlns:nyaa="https://example.org/xmlns/nyaa"><channel><item>
          <title>Some Release</title><link>https://example.org/download/5.torrent</link>
          <nyaa:seeders>42</nyaa:seeders><nyaa:leechers>7</nyaa:leechers>
          <nyaa:infoHash>08ada5a7a6183aae1e09d831df6748d566095a10</nyaa:infoHash><nyaa:size>1.4 GiB</nyaa:size>
        </item></channel></rss>
        """
        let result = FeedParser.parse(Data(xml.utf8), provider: "N").first
        XCTAssertEqual(result?.seeders, 42)
        XCTAssertEqual(result?.leechers, 7)
        XCTAssertEqual(result?.size, Int64(1.4 * 1_073_741_824))
    }

    func testScrapeTableWithMagnets() {
        let html = """
        <html><body><table>
          <tr><th>Category</th><th>Name</th><th>Size</th><th>Seeders</th><th>Leechers</th></tr>
          <tr><td><a href="/cat/1">Linux</a></td>
              <td><a href="/torrent/11/ubuntu-24-04-desktop">Ubuntu 24.04 Desktop amd64</a>
                  <a href="magnet:?xt=urn:btih:08ada5a7a6183aae1e09d831df6748d566095a10&dn=ubuntu">M</a></td>
              <td>5.7 GB</td><td>1,204</td><td>33</td></tr>
          <tr><td><a href="/cat/1">Linux</a></td>
              <td><a href="/torrent/12/ubuntu-server">Ubuntu 24.04 Server</a>
                  <a href="magnet:?xt=urn:btih:1111111111111111111111111111111111111111&dn=server">M</a></td>
              <td>2.1 GB</td><td>88</td><td>4</td></tr>
        </table></body></html>
        """
        let results = HTMLScraper.scrape(html: html, baseURL: URL(string: "https://example.org/search?q=ubuntu")!, provider: "T", query: "ubuntu")
        XCTAssertEqual(results.count, 2)
        XCTAssertEqual(results[0].title, "Ubuntu 24.04 Desktop amd64")
        XCTAssertEqual(results[0].infoHash, "08ada5a7a6183aae1e09d831df6748d566095a10")
        XCTAssertEqual(results[0].size, Int64(5.7 * 1_073_741_824))
        XCTAssertEqual(results[0].seeders, 1204)
        XCTAssertEqual(results[0].leechers, 33)
        XCTAssertEqual(results[0].detailsURL?.absoluteString, "https://example.org/torrent/11/ubuntu-24-04-desktop")
        XCTAssertEqual(results[1].seeders, 88)
    }

    func testScrapeHeaderlessRowsAndTorrentFiles() {
        let html = """
        <ul>
          <li><a href="/t/a">Debian 12 netinst</a> <span>650 MB</span> <span class="seeds">17</span> <span class="leeches">2</span>
              <a href="/files/debian-12.torrent">Download</a></li>
          <li><a href="/t/b">Debian 12 DVD</a> <span>3.7 GB</span> <span class="seeds">9</span> <span class="leeches">1</span>
              <a href="/files/debian-12-dvd.torrent">Download</a></li>
        </ul>
        """
        let results = HTMLScraper.scrape(html: html, baseURL: URL(string: "https://example.org/")!, provider: "T", query: "debian")
        XCTAssertEqual(results.count, 2)
        XCTAssertEqual(results[0].title, "Debian 12 netinst")
        XCTAssertEqual(results[0].torrentURL?.absoluteString, "https://example.org/files/debian-12.torrent")
        XCTAssertEqual(results[0].seeders, 17)
        XCTAssertEqual(results[0].leechers, 2)
        XCTAssertNil(results[0].magnet)
    }

    func testScrapeDetailLinksAndResolve() {
        let html = """
        <div><a href="/">Home</a><a href="/about">About this site</a>
        <table>
          <tr><td><a href="/torrent/101/fedora-workstation-40">Fedora Workstation 40 Live</a></td><td>2.2 GB</td><td>40</td><td>3</td></tr>
          <tr><td><a href="/torrent/102/fedora-server-40">Fedora Server 40 DVD</a></td><td>2.6 GB</td><td>12</td><td>1</td></tr>
          <tr><td><a href="/torrent/103/fedora-kde-40">Fedora KDE 40 Live</a></td><td>2.4 GB</td><td>8</td><td>0</td></tr>
        </table></div>
        """
        let base = URL(string: "https://example.org/search/fedora")!
        let results = HTMLScraper.scrape(html: html, baseURL: base, provider: "T", query: "fedora")
        XCTAssertEqual(results.count, 3)
        XCTAssertTrue(results.allSatisfy(\.needsResolving))
        XCTAssertEqual(results[0].detailsURL?.path, "/torrent/101/fedora-workstation-40")
        XCTAssertEqual(results[0].size, Int64(2.2 * 1_073_741_824))
        XCTAssertEqual(results[0].seeders, 40)
        XCTAssertEqual(results[0].leechers, 3)

        let details = "<p>Get it: <a href=\"magnet:?xt=urn:btih:08ada5a7a6183aae1e09d831df6748d566095a10\">magnet</a> <a href=\"/x.torrent\">file</a></p>"
        XCTAssertEqual(HTMLScraper.downloadLink(html: details, baseURL: base).magnet, "magnet:?xt=urn:btih:08ada5a7a6183aae1e09d831df6748d566095a10")
        let fileOnly = "<a href=\"/dl/x.torrent\">file</a>"
        XCTAssertEqual(HTMLScraper.downloadLink(html: fileOnly, baseURL: base).torrent?.absoluteString, "https://example.org/dl/x.torrent")
    }

    func testInternetArchive() {
        XCTAssertEqual(SearchEngine.internetArchiveQuery("night of the (living) dead"),
                       "title:(night AND of AND the AND living AND dead) AND format:(\"Archive BitTorrent\")")
        let json = """
        {"response":{"docs":[{"identifier":"Sintel","title":"Sintel","item_size":1808653912,"publicdate":"2010-10-01T00:00:00Z"}]}}
        """
        let results = SearchEngine.parseInternetArchive(Data(json.utf8), name: "Internet Archive")
        XCTAssertEqual(results.first?.torrentURL?.absoluteString, "https://archive.org/download/Sintel/Sintel_archive.torrent")
        XCTAssertEqual(results.first?.size, 1_808_653_912)
        XCTAssertNotNil(results.first?.date)
    }

    func testTemplateEncoding() throws {
        XCTAssertEqual(try SearchEngine.url(from: "https://x.org/search?q={query}&c=1", query: "a b&c").absoluteString,
                       "https://x.org/search?q=a%20b%26c&c=1")
        XCTAssertEqual(try SearchEngine.url(from: "https://x.org/search/{query}/1/", query: "a/b").absoluteString,
                       "https://x.org/search/a%2Fb/1/")
    }
}
