import AppKit
import SwiftUI

/// How the player draws subtitles: typeface, size and color.
struct SubtitleStyle: Equatable {
    /// An installed font family, or "" for the system font.
    var fontFamily = ""
    /// For the system font a weight such as "semibold" or "bold-italic"; otherwise the face's PostScript name.
    var fontFace = SubtitleTypeface.defaultSystemFace
    /// Multiplies the player's own text size, which follows the height of the video.
    var scale = 1.0
    var color = SubtitleTextColor.white
    /// "#RRGGBB", used when `color` is `.custom`.
    var customColor = SubtitleStyle.defaultCustomColor

    static let defaultCustomColor = "#7FD4FF"
    static let scaleRange = 0.6...1.8

    /// The line the style preview shows. Translators: use the line as it was subtitled or dubbed locally.
    static let sampleLine = LocalizedStringResource(
        "subtitles.preview.sample", defaultValue: "I don't think we're in Kansas anymore.",
        comment: "Sample subtitle in the subtitle style preview. A famous line from The Wizard of Oz; use the wording audiences in this language know.")

    func nsFont(size: CGFloat) -> NSFont {
        SubtitleTypeface.font(family: fontFamily, face: fontFace, size: size)
    }

    func font(size: CGFloat) -> Font {
        Font(nsFont(size: size) as CTFont)
    }

    var textColor: Color {
        switch color {
        case .white: .white
        case .yellow: Color(.sRGB, red: 1, green: 0.88, blue: 0.3)
        case .custom: Self.color(hex: customColor) ?? .white
        }
    }

    /// "System Semibold", "Avenir Next Bold Italic".
    var fontDescription: String {
        let face = SubtitleTypeface.face(fontFace, in: fontFamily)?.name ?? ""
        return [SubtitleTypeface.displayName(of: fontFamily), face].filter { !$0.isEmpty }.joined(separator: " ")
    }

    static func color(hex: String) -> Color? {
        let digits = hex.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "#", with: "")
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else { return nil }
        return Color(.sRGB, red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255,
                     blue: Double(value & 0xFF) / 255)
    }

    static func hex(of color: Color) -> String {
        guard let rgb = NSColor(color).usingColorSpace(.sRGB) else { return defaultCustomColor }
        func byte(_ component: CGFloat) -> Int { Int((min(max(component, 0), 1) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", byte(rgb.redComponent), byte(rgb.greenComponent), byte(rgb.blueComponent))
    }
}

enum SubtitleTextColor: String, CaseIterable, Identifiable {
    case white, yellow, custom

    var id: String { rawValue }

    var title: LocalizedStringResource {
        switch self {
        case .white: "White"
        case .yellow: "Yellow"
        case .custom: "Custom"
        }
    }
}

/// Typefaces subtitles can use: the system font at a few weights, or any installed family and its faces.
enum SubtitleTypeface {
    struct Face: Identifiable, Hashable {
        /// What `SubtitleStyle.fontFace` stores.
        let id: String
        let name: String
        /// On NSFontManager's 0–15 scale, where 5 is regular and 9 is bold.
        let weight: Int
        let isItalic: Bool
    }

    static let defaultSystemFace = "semibold"

    private static let systemWeights: [(id: String, name: String, weight: NSFont.Weight, scale: Int)] = [
        ("regular", "Regular", .regular, 5), ("medium", "Medium", .medium, 6), ("semibold", "Semibold", .semibold, 8),
        ("bold", "Bold", .bold, 9), ("heavy", "Heavy", .heavy, 11),
    ]

    static let systemFaces: [Face] = systemWeights.flatMap { weight in
        [Face(id: weight.id, name: weight.name, weight: weight.scale, isItalic: false),
         Face(id: weight.id + "-italic", name: weight.id == "regular" ? "Italic" : weight.name + " Italic",
              weight: weight.scale, isItalic: true)]
    }

    /// Installed families that can show text, leaving out symbol fonts such as Webdings.
    static let families: [String] = NSFontManager.shared.availableFontFamilies
        .filter { family in
            guard let first = faces(of: family).first, let font = NSFont(name: first.id, size: 12) else { return false }
            // The top four bits hold the family class.
            return font.fontDescriptor.symbolicTraits.rawValue & 0xF000_0000 != NSFontDescriptor.SymbolicTraits.classSymbolic.rawValue
        }
        .sorted { displayName(of: $0).localizedStandardCompare(displayName(of: $1)) == .orderedAscending }

    static func displayName(of family: String) -> String {
        family.isEmpty ? String(localized: "System") : NSFontManager.shared.localizedName(forFamily: family, face: nil)
    }

    static func faces(of family: String) -> [Face] {
        guard !family.isEmpty else { return systemFaces }
        return (NSFontManager.shared.availableMembers(ofFontFamily: family) ?? []).compactMap { member in
            guard member.count >= 4, let postScriptName = member[0] as? String, let name = member[1] as? String,
                  let weight = member[2] as? Int, let traits = member[3] as? UInt else { return nil }
            return Face(id: postScriptName, name: name, weight: weight,
                        isItalic: NSFontTraitMask(rawValue: traits).contains(.italicFontMask))
        }
    }

    static func face(_ id: String, in family: String) -> Face? {
        faces(of: family).first { $0.id == id }
    }

    /// The face in `family` nearest to `face`: same slant if there is one, then the closest weight.
    static func closest(to face: Face?, in family: String) -> Face? {
        let weight = face?.weight ?? 8, italic = face?.isItalic ?? false
        func distance(_ candidate: Face) -> (Int, Int) {
            (candidate.isItalic == italic ? 0 : 1, abs(candidate.weight - weight))
        }
        return faces(of: family).min { distance($0) < distance($1) }
    }

    /// Falls back to the system font when an installed face has since been removed.
    static func font(family: String, face: String, size: CGFloat) -> NSFont {
        if !family.isEmpty, let font = NSFont(name: face, size: size) { return font }
        let systemFace = systemFaces.first { $0.id == face } ?? systemFaces.first { $0.id == defaultSystemFace }!
        let weight = systemWeights.first { $0.scale == systemFace.weight }?.weight ?? .semibold
        let font = NSFont.systemFont(ofSize: size, weight: weight)
        guard systemFace.isItalic else { return font }
        let traits = font.fontDescriptor.symbolicTraits.union(.italic)
        return NSFont(descriptor: font.fontDescriptor.withSymbolicTraits(traits), size: size) ?? font
    }
}
