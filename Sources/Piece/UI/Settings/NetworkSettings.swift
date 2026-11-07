import SwiftUI

struct NetworkSettings: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var settings = app.settings
        Form {
            Section {
                SpeedLimitRow(
                    direction: "download",
                    systemImage: "arrow.down",
                    tint: .accentColor,
                    limitKB: $settings.downloadLimitKB,
                    suggestedKB: 5_000,
                    rememberedKey: "lastDownloadLimitKB"
                )
                SpeedLimitRow(
                    direction: "upload",
                    systemImage: "arrow.up",
                    tint: .green,
                    limitKB: $settings.uploadLimitKB,
                    suggestedKB: 1_000,
                    rememberedKey: "lastUploadLimitKB"
                )
            } header: {
                Text("Speed limits")
            } footer: {
                Text("Limits apply to all transfers combined.")
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
            Section {
                if app.torrents.policy.hasBattery {
                    Toggle("Pause transfers on battery power", isOn: $settings.pauseOnBattery)
                }
                Toggle("Pause transfers on metered connections", isOn: $settings.pauseOnMetered)
            } header: {
                Text("Pause automatically")
            } footer: {
                Text("Metered connections are Personal Hotspot, cellular and networks set to Low Data Mode. Transfers resume on their own when this no longer applies; a video you're playing keeps downloading.")
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
}

// MARK: - Speed limit row

/// "Limit download speed to [ 5 ] [MB/s]". The checkbox is the only thing that
/// decides whether a limit applies, so the field always shows a real number:
/// it is dimmed while the limit is off and keeps the last value for next time.
private struct SpeedLimitRow: View {
    let direction: String
    let systemImage: String
    let tint: Color
    /// KB/s, 0 = no limit.
    @Binding var limitKB: Int
    /// Value shown (and applied when the box is first ticked) before the user has picked one.
    let suggestedKB: Int

    /// The last limit that was set, so unticking and ticking again restores it.
    @AppStorage private var lastLimitKB: Int
    @State private var unit: SpeedUnit
    /// Bumped to make the field re-read the limit after an entry that was rejected.
    @State private var fieldRevision = 0
    @FocusState private var fieldFocused: Bool

    init(direction: String, systemImage: String, tint: Color, limitKB: Binding<Int>,
         suggestedKB: Int, rememberedKey: String) {
        self.direction = direction
        self.systemImage = systemImage
        self.tint = tint
        _limitKB = limitKB
        self.suggestedKB = suggestedKB
        _lastLimitKB = AppStorage(wrappedValue: 0, rememberedKey)
        let remembered = UserDefaults.standard.integer(forKey: rememberedKey)
        let shown = limitKB.wrappedValue > 0 ? limitKB.wrappedValue : (remembered > 0 ? remembered : suggestedKB)
        _unit = State(initialValue: .natural(for: shown))
    }

    private var isLimited: Bool { limitKB > 0 }
    /// What the field shows: the active limit, or the one that will come back when the box is ticked.
    private var shownKB: Int { isLimited ? limitKB : (lastLimitKB > 0 ? lastLimitKB : suggestedKB) }

    var body: some View {
        HStack(spacing: 8) {
            Toggle(isOn: limitedBinding) {
                Label {
                    Text("Limit \(direction) speed to")
                } icon: {
                    Image(systemName: systemImage).foregroundStyle(tint)
                }
            }
            .toggleStyle(.checkbox)
            Spacer()
            ZStack {
                HStack(spacing: 4) {
                    TextField("Speed", value: fieldBinding,
                              format: .number.precision(.fractionLength(0...3)).grouping(.never))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .monospacedDigit()
                    .frame(width: 72)
                    .focused($fieldFocused)
                    .id(fieldRevision)
                    Picker("Unit", selection: $unit) {
                        ForEach(SpeedUnit.allCases) { Text($0.label).tag($0) }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
                }
                .isHidden(!isLimited)
                
                Text("Unlimited")
                    .foregroundStyle(.secondary)
                    .isHidden(isLimited)
            }
        }
        .onChange(of: limitKB) {
            guard isLimited else { return }
            lastLimitKB = limitKB
            // Follow the value to a sensible unit, unless the user is typing in one.
            if !fieldFocused { unit = .natural(for: limitKB) }
        }
    }

    // MARK: Bindings

    private var limitedBinding: Binding<Bool> {
        Binding(
            get: { isLimited },
            set: { on in
                if on {
                    limitKB = shownKB
                    unit = .natural(for: limitKB)
                } else {
                    limitKB = 0
                }
            }
        )
    }

    /// The limit in the selected unit. An empty or zero entry is rejected and the
    /// field goes back to the current limit; turning the limit off is the checkbox's job.
    private var fieldBinding: Binding<Double?> {
        Binding(
            get: { Double(shownKB) / unit.kilobytes },
            set: { entered in
                guard let entered, entered > 0 else { fieldRevision += 1; return }
                limitKB = min(max(Int((entered * unit.kilobytes).rounded()), 1), SpeedUnit.maximumKB)
            }
        )
    }
}

private enum SpeedUnit: CaseIterable, Identifiable {
    case kilobytes, megabytes

    /// Typed limits are capped here (1 GB/s), well inside what the engine's 32-bit rate field holds.
    static let maximumKB = 1_000_000

    var id: Self { self }
    var label: String { self == .kilobytes ? "KB/s" : "MB/s" }
    var kilobytes: Double { self == .kilobytes ? 1 : 1_000 }

    static func natural(for kb: Int) -> SpeedUnit { kb >= 1_000 ? .megabytes : .kilobytes }
}

#Preview("Network") {
    NetworkSettings()
        .environment(AppModel.shared)
        .settingsPane()
}
