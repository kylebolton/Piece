import SwiftUI

/// Font, size and color for subtitles, with a live preview. Shown in a popover from Settings → Subtitles.
struct SubtitleStyleEditor: View {
    @Bindable var settings: AppSettings

    private var faces: [SubtitleTypeface.Face] { SubtitleTypeface.faces(of: settings.subtitleFontFamily) }

    /// Switching family keeps the closest face, so Bold Italic stays Bold Italic where the family has it.
    private var family: Binding<String> {
        Binding {
            settings.subtitleFontFamily
        } set: { family in
            let current = SubtitleTypeface.face(settings.subtitleFontFace, in: settings.subtitleFontFamily)
            settings.subtitleFontFamily = family
            settings.subtitleFontFace = SubtitleTypeface.closest(to: current, in: family)?.id ?? SubtitleTypeface.defaultSystemFace
        }
    }

    /// Choosing a color in the panel also switches to Custom.
    private var customColor: Binding<Color> {
        Binding {
            SubtitleStyle.color(hex: settings.subtitleCustomColor) ?? .white
        } set: { color in
            settings.subtitleCustomColor = SubtitleStyle.hex(of: color)
            settings.subtitleTextColor = .custom
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            SubtitlePreview(style: settings.subtitleStyle)
                .padding([.horizontal, .top], 14)
            Form {
                Picker("Font", selection: family) {
                    Text("System").tag("")
                    Divider()
                    ForEach(SubtitleTypeface.families, id: \.self) { family in
                        Text(SubtitleTypeface.displayName(of: family)).tag(family)
                    }
                }
                Picker("Style", selection: $settings.subtitleFontFace) {
                    ForEach(faces) { face in
                        Text(face.name).tag(face.id)
                    }
                }
                LabeledContent("Size") {
                    HStack(spacing: 8) {
                        Slider(value: $settings.subtitleFontScale, in: SubtitleStyle.scaleRange) {
                            Text("Size")
                        } minimumValueLabel: {
                            Text("A").font(.caption)
                        } maximumValueLabel: {
                            Text("A").font(.title3)
                        }
                        .labelsHidden()
                        Text(settings.subtitleFontScale, format: .percent.precision(.fractionLength(0)))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 38, alignment: .trailing)
                    }
                    .frame(width: 210)
                }
                LabeledContent("Color") {
                    HStack(spacing: 8) {
                        Picker("Color", selection: $settings.subtitleTextColor) {
                            ForEach(SubtitleTextColor.allCases) { color in
                                Text(color.title).tag(color)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .fixedSize()
                        ColorPicker("Custom Color", selection: customColor, supportsOpacity: false)
                            .labelsHidden()
                            .help("Choose the custom color")
                    }
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .scrollDisabled(true)
            .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Restore Defaults") { settings.subtitleStyle = SubtitleStyle() }
                    .disabled(settings.subtitleStyle == SubtitleStyle())
            }
            .padding([.horizontal, .bottom], 14)
            .padding(.top, -6)
        }
        .frame(width: 400)
    }
}

/// A subtitle over a dark scene, drawn the way the player draws it.
struct SubtitlePreview: View {
    var style: SubtitleStyle

    var body: some View {
        ZStack(alignment: .bottom) {
            LinearGradient(colors: [Color(red: 0.36, green: 0.44, blue: 0.52), Color(red: 0.16, green: 0.17, blue: 0.19),
                                    Color(red: 0.05, green: 0.05, blue: 0.06)],
                           startPoint: .top, endPoint: .bottom)
            Text(SubtitleStyle.sampleLine)
                .font(style.font(size: 17 * style.scale))
                .multilineTextAlignment(.center)
                .foregroundStyle(style.textColor)
                .shadow(color: .black, radius: 2, x: 0, y: 1)
                .shadow(color: .black.opacity(0.8), radius: 6)
                .padding(.horizontal, 16)
                .padding(.bottom, 14)
        }
        .frame(height: 130)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("Subtitle preview"))
    }
}

/// "Aa" in the subtitle style, as a compact summary next to the button that opens the editor.
struct SubtitleStyleSwatch: View {
    var style: SubtitleStyle

    var body: some View {
        Text(verbatim: "Aa")
            .font(style.font(size: 13))
            .foregroundStyle(style.textColor)
            .frame(width: 34, height: 22)
            .background(Color(red: 0.12, green: 0.13, blue: 0.15), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            .accessibilityHidden(true)
    }
}

#Preview("Subtitle Style") {
    SubtitleStyleEditor(settings: AppSettings.shared)
}
