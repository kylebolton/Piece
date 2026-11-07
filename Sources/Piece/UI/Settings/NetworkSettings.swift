import SwiftUI

struct NetworkSettings: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var settings = app.settings
        Form {
            Section("Speed limits") {
                LabeledContent("Download") { limitField($settings.downloadLimitKB) }
                LabeledContent("Upload") { limitField($settings.uploadLimitKB) }
            }
            Section("Queue") {
                Stepper("Download up to **\(settings.maxActiveDownloads)** at once",
                        value: $settings.maxActiveDownloads,
                        in: 1...50)
                .monospacedDigit()
                Stepper(
                    "Seed up to **\(settings.maxActiveSeeds)** at once",
                    value: $settings.maxActiveSeeds,
                    in: 0...100
                )
                .monospacedDigit()
            }
            Section("Connection") {
                LabeledContent("Incoming port") {
                    TextField("Port", value: $settings.listenPort, format: .number.grouping(.never))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)
                        .multilineTextAlignment(.trailing)
                }
                Toggle("Open the port on my router automatically (UPnP / NAT-PMP)", isOn: $settings.enablePortMapping)
                Toggle("Find peers without trackers (DHT)", isOn: $settings.enableDHT)
                Toggle("Only connect to peers that support encryption", isOn: $settings.requireEncryption)
            }
        }
        .formStyle(.grouped)
        .onChange(of: settingsFingerprint) { app.torrents.applySettings(app.settings) }
    }

    private var settingsFingerprint: [Int] {
        let s = app.settings
        return [s.downloadLimitKB, s.uploadLimitKB, s.maxActiveDownloads, s.maxActiveSeeds, s.listenPort,
                s.enablePortMapping ? 1 : 0, s.enableDHT ? 1 : 0, s.requireEncryption ? 1 : 0]
    }

    private func limitField(_ value: Binding<Int>) -> some View {
        HStack(spacing: 6) {
            TextField("Unlimited", value: Binding(get: { value.wrappedValue == 0 ? nil : value.wrappedValue },
                                                   set: { value.wrappedValue = max(0, $0 ?? 0) }),
                      format: .number.grouping(.never))
                .textFieldStyle(.roundedBorder)
                .frame(width: 90)
                .multilineTextAlignment(.trailing)
                .monospacedDigit()
            Text("KB/s").foregroundStyle(.secondary)
        }
    }
}

#Preview("Network") {
    NetworkSettings()
        .environment(AppModel.shared)
        .settingsPane()
}
