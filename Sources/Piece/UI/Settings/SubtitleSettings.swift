import SwiftUI

struct SubtitleSettings: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var settings = app.settings
        Form {
            Section {
                Toggle("Load matching subtitles automatically", isOn: $settings.autoLoadSubtitles)
                LabeledContent("Preferred languages") {
                    VStack(alignment: .trailing, spacing: 6) {
                        ForEach(Array(settings.subtitleLanguages.enumerated()), id: \.element) { index, code in
                            HStack {
                                Text("\(index + 1). \(SubtitleLanguage.name(for: code) ?? code)")
                                Button {
                                    settings.subtitleLanguages.removeAll { $0 == code }
                                } label: {
                                    Image(systemName: "minus.circle.fill")
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(.secondary)
                                .disabled(settings.subtitleLanguages.count <= 1)
                                .accessibilityLabel("Remove \(SubtitleLanguage.name(for: code) ?? code)")
                            }
                        }
                        Menu("Add Language") {
                            ForEach(SubtitleLanguage.all.filter { !settings.subtitleLanguages.contains($0.code) }, id: \.code) { language in
                                Button(language.name) { settings.subtitleLanguages.append(language.code) }
                            }
                        }
                        .fixedSize()
                    }
                }
                LabeledContent("Text size") {
                    Slider(value: $settings.subtitleFontScale, in: 0.6...1.8) {
                        Text("Text size")
                    } minimumValueLabel: {
                        Text("A").font(.caption)
                    } maximumValueLabel: {
                        Text("A").font(.title3)
                    }
                    .labelsHidden()
                    .frame(width: 200)
                }
            }
            Section {
                SecureField("API key", text: $settings.openSubtitlesKey)
                TextField("Username (optional)", text: $settings.openSubtitlesUser)
                SecureField("Password (optional)", text: $settings.openSubtitlesPassword)
            } header: {
                Text("OpenSubtitles")
            } footer: {
                Text("Subtitles inside a download are matched without an account. To search online, create a free API key at opensubtitles.com (Profile → API consumers). Signing in raises the daily download limit.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

#Preview("Subtitles") {
    SubtitleSettings()
        .environment(AppModel.shared)
        .settingsPane()
}
