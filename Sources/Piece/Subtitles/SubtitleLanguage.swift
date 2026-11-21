import Foundation

/// A subtitle language as OpenSubtitles files it, with regional variants kept apart.
///
/// `id` is what settings and tracks store. For every language OpenSubtitles lists it's that
/// service's own code, lowercased ("en", "pt-br", "ea"). Portuguese, Spanish and Chinese come in
/// variants that OpenSubtitles files separately, and each also has a family entry ("pt", "es",
/// "zh"). On a track the family means the variant isn't labeled; in the preference list it means
/// any variant will do.
struct SubtitleLanguage: Identifiable, Hashable {
    let id: String
    /// English name, e.g. "Portuguese (Brazil)".
    let name: String
    /// BCP 47 tag, used for HLS playlists and the language's own name for itself.
    let tag: String
    /// The family this is a regional variant of, e.g. "pt" for "pt-br".
    let family: String?
    /// The regional variants of a family entry, most widely used region first.
    let variants: [String]
    /// Whether OpenSubtitles accepts `id` as a language code.
    let isOnline: Bool
    let badge: String
    let aliases: [String]
    private let nativeOverride: String?

    private init(_ id: String, _ name: String, tag: String? = nil, family: String? = nil, variants: [String] = [],
                 online: Bool = true, badge: String? = nil, native: String? = nil, aliases: [String] = []) {
        self.id = id
        self.name = name
        self.tag = tag ?? id
        self.family = family
        self.variants = variants
        self.isOnline = online
        self.badge = badge ?? (tag ?? id).uppercased()
        self.nativeOverride = native
        self.aliases = aliases
    }

    var isFamily: Bool { !variants.isEmpty }

    /// How the language reads in the preference list, where a family accepts every variant.
    var preferenceName: String { isFamily ? "\(name) (any variant)" : name }

    /// A short explanation for entries whose name alone doesn't say enough.
    var note: String? {
        if isFamily {
            let regions = variants.compactMap { Self[$0]?.qualifier }
            guard let last = regions.last else { return nil }
            return regions.count == 1 ? last : regions.dropLast().joined(separator: ", ") + " or " + last
        }
        return id == "ze" ? "Chinese and English together" : nil
    }

    /// The part of the name in parentheses: "Brazil" for "Portuguese (Brazil)".
    var qualifier: String? {
        guard let open = name.firstIndex(of: "("), let close = name.lastIndex(of: ")"), open < close else { return nil }
        return String(name[name.index(after: open)..<close])
    }

    /// The language's name for itself, e.g. "Português (Brasil)", when the system knows it.
    var nativeName: String? {
        if let nativeOverride { return nativeOverride }
        let locale = Locale(identifier: tag)
        guard let code = locale.language.languageCode?.identifier, Self.localizedLanguages.contains(code),
              let native = locale.localizedString(forIdentifier: tag), !native.isEmpty else { return nil }
        return native.prefix(1).uppercased(with: locale) + native.dropFirst()
    }

    // MARK: - Catalog

    /// Every language OpenSubtitles lists (GET /infos/languages), plus the Portuguese and Chinese families.
    static let all: [SubtitleLanguage] = [
        .init("ab", "Abkhazian", aliases: ["abk"]),
        .init("af", "Afrikaans", aliases: ["afr"]),
        .init("sq", "Albanian", aliases: ["alb", "sqi"]),
        .init("am", "Amharic", aliases: ["amh"]),
        .init("ar", "Arabic", aliases: ["ara"]),
        .init("an", "Aragonese", aliases: ["arg"]),
        .init("hy", "Armenian", aliases: ["arm", "hye"]),
        .init("as", "Assamese", aliases: ["asm"]),
        .init("at", "Asturian", tag: "ast", aliases: ["ast"]),
        .init("az-az", "Azerbaijani", tag: "az", aliases: ["az", "aze", "azj", "az-latn"]),
        .init("az-zb", "South Azerbaijani", tag: "azb", aliases: ["azb", "az-arab", "az-ir"]),
        .init("eu", "Basque", aliases: ["baq", "eus"]),
        .init("be", "Belarusian", aliases: ["bel"]),
        .init("bn", "Bengali", aliases: ["ben", "bangla"]),
        .init("bs", "Bosnian", aliases: ["bos"]),
        .init("br", "Breton", aliases: ["bre"]),
        .init("bg", "Bulgarian", aliases: ["bul"]),
        .init("my", "Burmese", aliases: ["bur", "mya"]),
        .init("ca", "Catalan", aliases: ["cat", "valencian"]),
        .init("zh", "Chinese", variants: ["zh-cn", "zh-tw", "zh-ca", "ze"], online: false,
              aliases: ["chi", "zho", "mandarin", "中文"]),
        .init("zh-cn", "Chinese (Simplified)", tag: "zh-Hans", family: "zh", badge: "ZH-CN",
              aliases: ["chs", "zhs", "zh-hans", "zh-sg", "simplified chinese", "简体", "简中", "简体中文"]),
        .init("zh-tw", "Chinese (Traditional)", tag: "zh-Hant", family: "zh", badge: "ZH-TW",
              aliases: ["cht", "zht", "zh-hant", "zh-hk", "zh-mo", "traditional chinese", "繁體", "繁体", "繁中", "繁體中文", "繁体中文"]),
        .init("zh-ca", "Chinese (Cantonese)", tag: "yue", family: "zh",
              aliases: ["yue", "zh-yue", "cantonese", "粵語", "粤语", "廣東話", "广东话"]),
        .init("ze", "Chinese (Bilingual)", tag: "zh", family: "zh", badge: "ZH+EN", native: "中英双语",
              aliases: ["zhe", "chs&eng", "cht&eng", "chseng", "chteng", "zh-en", "中英", "双语", "雙語", "简英", "繁英", "中英双语", "中英雙語"]),
        .init("hr", "Croatian", aliases: ["hrv", "scr"]),
        .init("cs", "Czech", aliases: ["cze", "ces"]),
        .init("da", "Danish", aliases: ["dan"]),
        .init("pr", "Dari", tag: "prs", aliases: ["prs", "fa-af"]),
        .init("nl", "Dutch", aliases: ["dut", "nld", "flemish", "nl-be"]),
        .init("en", "English", aliases: ["eng"]),
        .init("eo", "Esperanto", aliases: ["epo"]),
        .init("et", "Estonian", aliases: ["est"]),
        .init("ex", "Extremaduran", tag: "ext", aliases: ["ext"]),
        .init("fi", "Finnish", aliases: ["fin"]),
        .init("fr", "French", aliases: ["fre", "fra"]),
        .init("gd", "Scottish Gaelic", aliases: ["gla", "gaelic"]),
        .init("gl", "Galician", aliases: ["glg"]),
        .init("ka", "Georgian", aliases: ["geo", "kat"]),
        .init("de", "German", aliases: ["ger", "deu"]),
        .init("el", "Greek", aliases: ["gre", "ell"]),
        .init("he", "Hebrew", aliases: ["heb", "iw"]),
        .init("hi", "Hindi", aliases: ["hin"]),
        .init("hu", "Hungarian", aliases: ["hun"]),
        .init("is", "Icelandic", aliases: ["ice", "isl"]),
        .init("ig", "Igbo", aliases: ["ibo"]),
        .init("id", "Indonesian", aliases: ["ind", "in"]),
        .init("ia", "Interlingua", aliases: ["ina"]),
        .init("ga", "Irish", aliases: ["gle"]),
        .init("it", "Italian", aliases: ["ita"]),
        .init("ja", "Japanese", aliases: ["jpn", "jp"]),
        .init("kn", "Kannada", aliases: ["kan"]),
        .init("kk", "Kazakh", aliases: ["kaz"]),
        .init("km", "Khmer", aliases: ["khm"]),
        .init("ko", "Korean", aliases: ["kor"]),
        .init("ku", "Kurdish", aliases: ["kur", "ckb", "kmr"]),
        .init("lv", "Latvian", aliases: ["lav"]),
        .init("lt", "Lithuanian", aliases: ["lit"]),
        .init("lb", "Luxembourgish", aliases: ["ltz"]),
        .init("mk", "Macedonian", aliases: ["mac", "mkd"]),
        .init("ms", "Malay", aliases: ["may", "msa"]),
        .init("ml", "Malayalam", aliases: ["mal"]),
        .init("ma", "Manipuri", tag: "mni", aliases: ["mni"]),
        .init("mr", "Marathi", aliases: ["mar"]),
        .init("mn", "Mongolian", aliases: ["mon"]),
        .init("me", "Montenegrin", tag: "cnr", aliases: ["cnr", "mne"]),
        .init("nv", "Navajo", aliases: ["nav"]),
        .init("ne", "Nepali", aliases: ["nep"]),
        .init("se", "Northern Sami", aliases: ["sme"]),
        .init("no", "Norwegian", aliases: ["nor", "nob", "nno", "nb", "nn"]),
        .init("oc", "Occitan", aliases: ["oci"]),
        .init("or", "Odia", aliases: ["ori", "oriya"]),
        .init("ps", "Pashto", aliases: ["pus", "pushto"]),
        .init("fa", "Persian", aliases: ["per", "fas", "pes", "farsi"]),
        .init("pl", "Polish", aliases: ["pol"]),
        .init("pt", "Portuguese", variants: ["pt-pt", "pt-br", "pm"], online: false, aliases: ["por"]),
        .init("pt-pt", "Portuguese (Portugal)", tag: "pt-PT", family: "pt",
              aliases: ["ptpt", "european portuguese"]),
        .init("pt-br", "Portuguese (Brazil)", tag: "pt-BR", family: "pt",
              aliases: ["pob", "pb", "ptbr", "brazilian", "brasileiro", "brazilian portuguese"]),
        .init("pm", "Portuguese (Mozambique)", tag: "pt-MZ", family: "pt", aliases: ["pom", "pt-mz"]),
        .init("ro", "Romanian", aliases: ["rum", "ron", "mol", "moldavian"]),
        .init("ru", "Russian", aliases: ["rus"]),
        .init("sx", "Santali", tag: "sat", aliases: ["sat"]),
        .init("sr", "Serbian", aliases: ["srp", "scc"]),
        .init("sd", "Sindhi", aliases: ["snd"]),
        .init("si", "Sinhala", aliases: ["sin", "sinhalese"]),
        .init("sk", "Slovak", aliases: ["slo", "slk"]),
        .init("sl", "Slovenian", aliases: ["slv"]),
        .init("so", "Somali", aliases: ["som"]),
        // OpenSubtitles' own "es" is Spanish with no region given, so it doubles as the family.
        .init("es", "Spanish", variants: ["sp", "ea"], aliases: ["spa"]),
        .init("sp", "Spanish (Spain)", tag: "es-ES", family: "es",
              aliases: ["spn", "castilian", "castellano", "european spanish"]),
        .init("ea", "Spanish (Latin America)", tag: "es-419", family: "es",
              aliases: ["spl", "es-la", "latino", "latam", "latin american spanish"]),
        .init("sw", "Swahili", aliases: ["swa"]),
        .init("sv", "Swedish", aliases: ["swe"]),
        .init("sy", "Syriac", tag: "syr", aliases: ["syr"]),
        .init("tl", "Tagalog", aliases: ["tgl", "fil", "filipino"]),
        .init("ta", "Tamil", aliases: ["tam"]),
        .init("tt", "Tatar", aliases: ["tat"]),
        .init("te", "Telugu", aliases: ["tel"]),
        .init("tm-td", "Tetum", tag: "tet", aliases: ["tet"]),
        .init("th", "Thai", aliases: ["tha"]),
        .init("tp", "Toki Pona", tag: "tok", aliases: ["tok"]),
        .init("tr", "Turkish", aliases: ["tur"]),
        .init("tk", "Turkmen", aliases: ["tuk"]),
        .init("uk", "Ukrainian", aliases: ["ukr"]),
        .init("ur", "Urdu", aliases: ["urd"]),
        .init("uz", "Uzbek", aliases: ["uzb"]),
        .init("vi", "Vietnamese", aliases: ["vie"]),
        .init("cy", "Welsh", aliases: ["wel", "cym"]),
    ]

    /// Words that pick a variant once the language is known: "Brazil" after "Portuguese", "419" in "es-419".
    /// Listed in priority order, which matters for Chinese text that can contain several.
    private static let qualifiers: [String: [(String, String)]] = [
        "pt": [("br", "pt-br"), ("bra", "pt-br"), ("brazil", "pt-br"), ("brasil", "pt-br"), ("brazilian", "pt-br"),
               ("brasileiro", "pt-br"), ("brasileira", "pt-br"),
               ("mz", "pm"), ("moz", "pm"), ("mozambique", "pm"), ("mocambique", "pm"),
               ("pt", "pt-pt"), ("prt", "pt-pt"), ("portugal", "pt-pt"), ("european", "pt-pt"), ("europeu", "pt-pt"),
               ("europeia", "pt-pt"), ("eu", "pt-pt"), ("europe", "pt-pt"),
               // Portuguese elsewhere in Africa and Asia follows the European norm.
               ("ao", "pt-pt"), ("cv", "pt-pt"), ("gw", "pt-pt"), ("st", "pt-pt"), ("tl", "pt-pt"), ("mo", "pt-pt")],
        "es": [("es", "sp"), ("esp", "sp"), ("spain", "sp"), ("espana", "sp"), ("castilian", "sp"), ("castellano", "sp"),
               ("european", "sp"), ("europe", "sp"), ("eu", "sp"), ("iberian", "sp"),
               ("419", "ea"), ("la", "ea"), ("lat", "ea"), ("latam", "ea"), ("latin", "ea"), ("latino", "ea"), ("latina", "ea"),
               ("latinoamerica", "ea"), ("latinoamericano", "ea"), ("hispanoamerica", "ea"), ("america", "ea"),
               ("american", "ea"), ("americas", "ea"), ("mexico", "ea"), ("mexican", "ea")] + latinAmericanRegions,
        "zh": [("bilingual", "ze"), ("中英", "ze"), ("双语", "ze"), ("雙語", "ze"),
               ("yue", "zh-ca"), ("cantonese", "zh-ca"), ("粵語", "zh-ca"), ("粤语", "zh-ca"), ("廣東話", "zh-ca"),
               ("hans", "zh-cn"), ("cn", "zh-cn"), ("sg", "zh-cn"), ("chs", "zh-cn"), ("simplified", "zh-cn"),
               ("mainland", "zh-cn"), ("简体", "zh-cn"),
               ("hant", "zh-tw"), ("tw", "zh-tw"), ("hk", "zh-tw"), ("mo", "zh-tw"), ("cht", "zh-tw"),
               ("traditional", "zh-tw"), ("taiwan", "zh-tw"), ("繁體", "zh-tw"), ("繁体", "zh-tw"),
               ("简", "zh-cn"), ("繁", "zh-tw")],
        "az-az": [("arab", "az-zb"), ("ir", "az-zb"), ("south", "az-zb"), ("southern", "az-zb")],
        "fa": [("af", "pr"), ("afghanistan", "pr"), ("dari", "pr")],
    ]

    private static let latinAmericanRegions: [(String, String)] = [
        "mx", "ar", "co", "cl", "pe", "ve", "ec", "gt", "cu", "bo", "do", "hn", "py", "sv", "ni", "cr", "pa", "uy", "pr", "us",
    ].map { ($0, "ea") }

    private static let byID: [String: SubtitleLanguage] = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })

    static subscript(id: String) -> SubtitleLanguage? { byID[id] }

    /// Every spelling that identifies a language on its own: codes, aliases, and names in English,
    /// in the language itself and in the user's language. Earlier entries win.
    private static let index: [String: String] = {
        var index: [String: String] = [:]
        func add(_ key: String, _ id: String) {
            let key = fold(key)
            if !key.isEmpty, index[key] == nil { index[key] = id }
        }
        for language in all { add(language.id, language.id) }
        for language in all { language.aliases.forEach { add($0, language.id) } }
        let english = Locale(identifier: "en")
        for language in all {
            add(language.name, language.id)
            [english.localizedString(forIdentifier: language.tag), language.nativeName,
             Locale.current.localizedString(forIdentifier: language.tag)].compactMap { $0 }.forEach { add($0, language.id) }
        }
        return index
    }()

    private static let localizedLanguages: Set<String> = Set(Locale.availableIdentifiers.compactMap {
        Locale(identifier: $0).language.languageCode?.identifier
    })

    private static let regionCodes: Set<String> = Set(Locale.Region.isoRegions.map { $0.identifier.lowercased() })

    // MARK: - Identifying

    /// Normalises a code or name — "pt-BR", "pob", "por", "Brazilian", "Português" — to a language id.
    static func identify(_ token: String) -> String? {
        let key = fold(token).replacingOccurrences(of: "_", with: "-")
        if let id = index[key] { return id }
        let parts = key.split(separator: "-").map(String.init)
        guard parts.count > 1, let base = index[parts[0]] else { return nil }
        return parts.dropFirst().lazy.compactMap { qualified(base, by: $0) }.first ?? base
    }

    /// Identifies an embedded track from its language tag, letting the title name the variant:
    /// "por" titled "Brazilian" is Brazilian Portuguese.
    static func identify(tag: String?, title: String?) -> String? {
        let fromTag = tag.flatMap { identify($0) }
        guard let title, !title.trimmingCharacters(in: .whitespaces).isEmpty else { return fromTag }
        guard let fromTag else { return identify(text: title) }
        guard qualifiers[fromTag] != nil else { return fromTag }
        if let fromTitle = identify(text: title), Self[fromTitle]?.family == fromTag { return fromTitle }
        return refine(fromTag, in: title)
    }

    /// Finds a language named in free text such as a track title: "Spanish (Latin America)", "简体中文".
    static func identify(text: String) -> String? {
        if let id = identify(text) { return id }
        let folded = fold(text)
        // Two-letter words are too often ordinary words ("it", "no") to trust inside a phrase.
        var base = words(in: folded).lazy.filter { $0.count >= 3 }.compactMap { index[$0] }.first
        if base == nil {
            base = index.lazy.filter { $0.key.unicodeScalars.contains { $0.value >= 0x2E80 } && folded.contains($0.key) }
                .max { $0.key.count < $1.key.count }?.value
        }
        return base.map { refine($0, in: text) }
    }

    /// Guesses the language from a subtitle filename such as "Movie.2019.eng.srt", "Movie.pt-BR.forced.srt"
    /// or "Subs/2_Brazilian.Portuguese.srt".
    static func guess(fromFilename filename: String) -> String? {
        let base = ((filename as NSString).lastPathComponent as NSString).deletingPathExtension
        var tokens = base.split(whereSeparator: { ".-_ []()".contains($0) }).map(String.init)
        while let last = tokens.last, isFlag(last, after: tokens.dropLast().last) { tokens.removeLast() }
        guard let last = tokens.last else { return nil }
        let previous = tokens.count > 1 ? tokens[tokens.count - 2] : nil

        // A language followed by its region: "pt.BR", "zh-Hant", "Portuguese (Brazil)", "en-US".
        if let previous, let language = identify(previous) {
            if let variant = qualified(language, by: last) { return variant }
            if previous.count <= 3, isRegionOrScript(last) { return language }
        }
        if last.count >= 2, let language = identify(last) {
            // A region before the language: "Brazilian.Portuguese".
            if let previous, let variant = qualified(language, by: previous) { return variant }
            return language
        }
        // Something else trails the language ("Movie.English.YIFY.srt"). Only longer words count here, and never
        // the first, which is where the title starts ("Ice.Age.srt" isn't Icelandic).
        for index in tokens.indices.dropFirst().reversed() where tokens[index].count >= 3 {
            guard let language = identify(tokens[index]) else { continue }
            let neighbours = [tokens[index - 1], index + 1 < tokens.count ? tokens[index + 1] : nil].compactMap { $0 }
            return neighbours.lazy.compactMap { qualified(language, by: $0) }.first ?? language
        }
        return nil
    }

    static func name(for token: String) -> String? {
        identify(token).flatMap { Self[$0]?.name }
    }

    static func badge(for token: String) -> String {
        identify(token).flatMap { Self[$0]?.badge } ?? token.uppercased()
    }

    // MARK: - Choosing

    /// How well a track's language satisfies one preference.
    enum Match: Int, Comparable {
        /// The language asked for, or any variant when the whole family was asked for.
        case exact
        /// The right language, but the track doesn't say which variant it is.
        case unlabeledVariant

        static func < (a: Match, b: Match) -> Bool { a.rawValue < b.rawValue }
    }

    struct Rank: Comparable {
        var match: Match
        /// Position of the preference it satisfies.
        var preference: Int

        static func < (a: Rank, b: Rank) -> Bool { (a.match, a.preference) < (b.match, b.preference) }
    }

    static func match(_ track: String?, preference: String) -> Match? {
        guard let track else { return nil }
        if track == preference { return .exact }
        guard let t = Self[track], let p = Self[preference] else { return nil }
        if p.isFamily, t.family == p.id { return .exact }
        if t.isFamily, p.family == t.id { return .unlabeledVariant }
        return nil
    }

    /// Exact matches for any preference come before unlabeled variants, so with [Portuguese (Portugal), English]
    /// an English track wins over one that's only "Portuguese".
    static func rank(_ track: String?, in preferences: [String]) -> Rank? {
        preferences.enumerated().compactMap { index, preference in
            match(track, preference: preference).map { Rank(match: $0, preference: index) }
        }.min()
    }

    /// The best-ranked item; ties go to whichever comes first.
    static func best<Item>(_ items: [Item], for preferences: [String], language: (Item) -> String?) -> Item? {
        items.enumerated()
            .compactMap { offset, item in rank(language(item), in: preferences).map { (rank: $0, offset: offset, item: item) } }
            .min { ($0.rank, $0.offset) < ($1.rank, $1.offset) }?.item
    }

    /// OpenSubtitles codes to search for. A family searches all its variants; a variant also searches
    /// the family's unlabeled code where OpenSubtitles has one, ranked after exact matches.
    static func searchCodes(for preferences: [String]) -> [String] {
        var codes: Set<String> = []
        for language in preferences.compactMap({ Self[$0] }) {
            if language.isOnline { codes.insert(language.id) }
            codes.formUnion(language.variants)
            if let family = language.family.flatMap({ Self[$0] }), family.isOnline { codes.insert(family.id) }
        }
        return codes.sorted()
    }

    // MARK: - Preferences

    /// The user's system languages as subtitle languages, e.g. ["pt-PT", "en-PT"] → ["pt-pt", "en"].
    static func defaultPreferences(systemLanguages: [String] = Locale.preferredLanguages) -> [String] {
        var result: [String] = []
        for language in systemLanguages {
            if let id = identify(language), !result.contains(id) { result.append(id) }
        }
        return result.isEmpty ? ["en"] : Array(result.prefix(3))
    }

    /// Earlier versions stored bare "pt" and "zh" with no way to pick a variant. Those become the variant the
    /// system language names, or stay as the whole family when it doesn't name one. Unknown codes are dropped.
    static func migrate(_ stored: [String], systemLanguages: [String] = Locale.preferredLanguages) -> [String] {
        let system = defaultPreferences(systemLanguages: systemLanguages)
        var result: [String] = []
        for code in stored {
            guard var id = Self[code] != nil ? code : identify(code), let language = Self[id] else { continue }
            if language.isFamily, !language.isOnline, let variant = system.first(where: { Self[$0]?.family == id }) {
                id = variant
            }
            if !result.contains(id) { result.append(id) }
        }
        return result.isEmpty ? system : result
    }

    /// Drops codes that aren't in the catalog, falling back to the system languages if nothing is left.
    static func validated(_ stored: [String]) -> [String] {
        var result: [String] = []
        for code in stored where Self[code] != nil && !result.contains(code) { result.append(code) }
        return result.isEmpty ? defaultPreferences() : result
    }

    // MARK: - Helpers

    static func fold(_ string: String) -> String {
        string.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func words(in folded: String) -> [String] {
        folded.split(whereSeparator: { !($0.isLetter || $0.isNumber || $0 == "&") }).map(String.init)
    }

    /// The variant of `language` that `word` names, if it names one.
    private static func qualified(_ language: String, by word: String) -> String? {
        let key = fold(word)
        return qualifiers[language]?.first { $0.0 == key }?.1
    }

    /// Looks through `text` for a word that names a variant of `language`.
    private static func refine(_ language: String, in text: String) -> String {
        guard let table = qualifiers[language] else { return language }
        let folded = fold(text)
        for word in words(in: folded) {
            if let variant = qualified(language, by: word) { return variant }
        }
        // Chinese titles run words together ("简体中文字幕"), so look for those as substrings.
        for (key, variant) in table where key.unicodeScalars.contains(where: { $0.value >= 0x2E80 }) && folded.contains(key) {
            return variant
        }
        return language
    }

    private static func isRegionOrScript(_ token: String) -> Bool {
        let key = token.lowercased()
        return (key.count == 2 && regionCodes.contains(key)) || ["latn", "cyrl", "arab", "hans", "hant"].contains(key)
            || (key.count == 3 && key.allSatisfy(\.isNumber))
    }

    /// Words that trail the language in subtitle filenames: "Movie.en.forced.srt", "Movie.eng.SDH.srt", "Movie.en.2.srt".
    private static func isFlag(_ token: String, after previous: String?) -> Bool {
        let key = token.lowercased()
        let flags: Set<String> = ["forced", "sdh", "cc", "default", "full", "signs", "songs", "sub", "subs", "subtitle",
                                  "subtitles", "dialog", "dialogue", "commentary", "hoh", "impaired", "hearing"]
        if flags.contains(key) { return true }
        // "hi" (hearing impaired) and track numbers only count after a language, so "Movie.hi.srt" stays Hindi.
        guard key == "hi" || (key.count <= 2 && key.allSatisfy(\.isNumber)) else { return false }
        return previous.flatMap { identify($0) } != nil
    }
}
