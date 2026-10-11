import AVKit
import SwiftUI
import UniformTypeIdentifiers

struct VideoSurface: NSViewRepresentable {
    var player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .floating
        view.showsFullScreenToggleButton = true
        view.allowsPictureInPicturePlayback = true
        view.videoGravity = .resizeAspect
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
    }
}

struct PlayerWindow: View {
    @Environment(AppModel.self) private var app
    @State private var showSubtitles = false
    @State private var isHovering = false
    @State private var hideTask: Task<Void, Never>?

    var body: some View {
        let model = app.player
        ZStack {
            Color.black
            VideoSurface(player: model.player)

            // Subtitles drawn by the app, so any file format and timing offset works.
            if let cue = model.cueText, !model.isExternal {
                GeometryReader { proxy in
                    VStack {
                        Spacer()
                        Text(cue)
                            .font(.system(size: max(16, proxy.size.height * 0.045) * AppSettings.shared.subtitleFontScale, weight: .semibold))
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.white)
                            .shadow(color: .black, radius: 2, x: 0, y: 1)
                            .shadow(color: .black.opacity(0.8), radius: 6)
                            .padding(.horizontal, 28)
                            // Step above the floating transport controls while they're showing.
                            .padding(.bottom, isHovering ? max(150, proxy.size.height * 0.3) : proxy.size.height * 0.07)
                            .frame(maxWidth: .infinity)
                    }
                }
                .allowsHitTesting(false)
            }

            statusOverlay(model)

            VStack {
                HStack(spacing: 6) {
                    if !model.audioStreams.isEmpty, model.audioStreams.count > 1 {
                        Menu {
                            ForEach(model.audioStreams, id: \.index) { stream in
                                Button {
                                    model.selectAudio(stream: stream.index)
                                } label: {
                                    let name = [stream.language.flatMap(SubtitleLanguage.name(for:)) ?? stream.title ?? "Track \(stream.index)",
                                                stream.codec.uppercased()].joined(separator: " — ")
                                    if (model.selectedAudioStream ?? model.audioStreams.first(where: \.isDefault)?.index ?? model.audioStreams.first?.index) == stream.index {
                                        Label(name, systemImage: "checkmark")
                                    } else {
                                        Text(name)
                                    }
                                }
                            }
                        } label: {
                            Image(systemName: "waveform").frame(width: 30, height: 30)
                        }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .fixedSize()
                        .help("Audio track")
                    }
                    Menu {
                        ForEach([Float(0.5), 0.75, 1, 1.25, 1.5, 2, 3], id: \.self) { speed in
                            Button {
                                model.setRate(speed)
                            } label: {
                                let name = speed == 1 ? "Normal" : String(format: "%g×", speed)
                                if abs(model.rate - speed) < 0.01 { Label(name, systemImage: "checkmark") } else { Text(name) }
                            }
                        }
                    } label: {
                        Image(systemName: "gauge.with.needle").frame(width: 30, height: 30)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("Playback speed")
                    .accessibilityLabel("Playback speed")

                    Button {
                        showSubtitles.toggle()
                    } label: {
                        Image(systemName: model.selectedSubtitleID == nil ? "captions.bubble" : "captions.bubble.fill")
                            .frame(width: 30, height: 30)
                    }
                    .buttonStyle(.plain)
                    .help("Subtitles")
                    .accessibilityLabel("Subtitles")
                    .popover(isPresented: $showSubtitles, arrowEdge: .bottom) { SubtitlePanel() }
                }
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .glassBackground(in: Capsule())
                .environment(\.colorScheme, .dark)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(12)
                .opacity(isHovering || showSubtitles || !model.isPlaying || model.status != .ready ? 1 : 0)
                Spacer()
                bottomNotices(model)
            }
        }
        .frame(minWidth: 520, minHeight: 300)
        .onContinuousHover { phase in
            switch phase {
            case .active:
                if !isHovering { withAnimation(.easeOut(duration: 0.15)) { isHovering = true } }
                hideTask?.cancel()
                hideTask = Task {
                    try? await Task.sleep(for: .seconds(3))
                    guard !Task.isCancelled else { return }
                    withAnimation(.easeOut(duration: 0.4)) { isHovering = false }
                }
            case .ended:
                withAnimation(.easeOut(duration: 0.4)) { isHovering = false }
            }
        }
        .navigationTitle(windowTitle(model))
        .onAppear { model.isWindowVisible = true }
        .onDisappear {
            model.isWindowVisible = false
            // Closing the window while casting leaves the film playing on the TV.
            if !model.isExternal { model.stop() }
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url, FileKind(path: url.path) == .subtitle else { return }
                Task { @MainActor in model.addSubtitleFile(url) }
            }
            return true
        }
    }

    private func windowTitle(_ model: PlayerModel) -> String {
        guard let item = model.item else { return "Player" }
        if let detail = item.detail, !detail.isEmpty { return "\(item.title) — \(detail)" }
        return item.title
    }

    @ViewBuilder
    private func statusOverlay(_ model: PlayerModel) -> some View {
        switch model.status {
        case .idle:
            VStack(spacing: 8) {
                Image(systemName: "play.rectangle").font(.system(size: 40, weight: .light))
                Text("Nothing is playing")
            }
            .foregroundStyle(.white.opacity(0.5))
        case .preparing(let message):
            statusCard(title: message, detail: model.bufferingDetail, showsSpinner: true)
        case .failed(let message):
            VStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle").font(.system(size: 34, weight: .light))
                Text("This file couldn't be played").font(.headline)
                Text(message).font(.callout).foregroundStyle(.white.opacity(0.7)).multilineTextAlignment(.center).frame(maxWidth: 420)
                HStack {
                    Button("Try Again", systemImage: "arrow.clockwise") { model.retry() }
                    if let item = model.item, case .file(let url) = item.origin {
                        Button("Show in Finder", systemImage: "folder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                    }
                }
                .padding(.top, 4)
            }
            .foregroundStyle(.white)
            .padding(24)
        case .ready:
            if model.isExternal {
                VStack(spacing: 8) {
                    Image(systemName: "airplayvideo").font(.system(size: 44, weight: .light))
                    Text("Playing on AirPlay").font(.headline)
                }
                .foregroundStyle(.white.opacity(0.8))
                .allowsHitTesting(false)
            } else if model.isBuffering, !model.bufferingDetail.isEmpty {
                statusCard(title: "Buffering…", detail: model.bufferingDetail, showsSpinner: true)
            }
        }
    }

    /// The resume offer and any non-fatal warning, sitting just above the transport controls.
    @ViewBuilder
    private func bottomNotices(_ model: PlayerModel) -> some View {
        VStack(spacing: 8) {
            if let from = model.resumedFrom {
                HStack(spacing: 10) {
                    Text("Resumed at \(Format.duration(from))")
                    Button("Start Over") { model.startOver() }.buttonStyle(.borderless)
                }
                .font(.callout)
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .glassBackground(in: Capsule())
                .environment(\.colorScheme, .dark)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            if let notice = model.notice {
                Label(notice, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .glassBackground(in: Capsule())
                    .environment(\.colorScheme, .dark)
            }
        }
        .padding(.bottom, 90)
        .animation(.smooth, value: model.resumedFrom)
    }

    private func statusCard(title: String, detail: String, showsSpinner: Bool) -> some View {
        VStack(spacing: 10) {
            if showsSpinner { ProgressView().controlSize(.large) }
            Text(title).font(.headline)
            if !detail.isEmpty {
                Text(detail).font(.callout).monospacedDigit().foregroundStyle(.white.opacity(0.75))
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 28)
        .padding(.vertical, 20)
        .glassBackground(in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .environment(\.colorScheme, .dark)
        .allowsHitTesting(false)
    }
}

/// Subtitle picker: local and embedded tracks, online search and timing.
struct SubtitlePanel: View {
    @Environment(AppModel.self) private var app
    @State private var query = ""

    var body: some View {
        let model = app.player
        @Bindable var bindable = app.player
        VStack(alignment: .leading, spacing: 12) {
            Text("Subtitles").font(.headline)

            VStack(alignment: .leading, spacing: 2) {
                trackButton(title: "Off", isSelected: model.selectedSubtitleID == nil) {
                    Task { await model.select(subtitle: nil) }
                }
                ForEach(model.subtitleTracks) { track in
                    trackButton(title: track.menuTitle, isSelected: model.selectedSubtitleID == track.id) {
                        Task { await model.select(subtitle: track) }
                    }
                }
            }

            if let status = model.subtitleStatus {
                Label(status, systemImage: status.hasSuffix("…") ? "hourglass" : "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text("Find online").font(.subheadline.weight(.semibold))
                HStack {
                    TextField("Title (leave empty to match this file)", text: $query)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { search(model) }
                    if model.isSearchingOnline {
                        ProgressView().controlSize(.small)
                    } else {
                        Button("Search") { search(model) }
                    }
                }
                if !model.onlineResults.isEmpty {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(model.onlineResults.prefix(30)) { result in
                                Button {
                                    Task { await model.select(online: result) }
                                } label: {
                                    HStack(spacing: 6) {
                                        Text(result.language.uppercased())
                                            .font(.caption2.weight(.bold))
                                            .padding(.horizontal, 4)
                                            .padding(.vertical, 1)
                                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 3))
                                        Text(result.release).font(.caption).lineLimit(1).truncationMode(.middle)
                                        Spacer(minLength: 4)
                                        if result.hashMatch {
                                            Image(systemName: "checkmark.seal.fill").foregroundStyle(.green).help("Exact match for this file")
                                        }
                                        if model.selectedSubtitleID == "online:\(result.fileID)" {
                                            Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
                                        }
                                    }
                                    .padding(.vertical, 3)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .frame(maxHeight: 150)
                }
            }

            Divider()

            HStack {
                Text("Timing")
                Spacer()
                Button { bindable.subtitleDelay -= 0.25 } label: { Image(systemName: "minus") }
                    .accessibilityLabel("Show subtitles earlier")
                Text(String(format: "%+.2f s", model.subtitleDelay)).monospacedDigit().frame(width: 64)
                Button { bindable.subtitleDelay += 0.25 } label: { Image(systemName: "plus") }
                    .accessibilityLabel("Show subtitles later")
            }
            .font(.callout)

            Button("Choose Subtitle File…") {
                let panel = NSOpenPanel()
                panel.allowedContentTypes = ["srt", "vtt", "ass", "ssa"].compactMap { UTType(filenameExtension: $0) }
                if panel.runModal() == .OK, let url = panel.url { model.addSubtitleFile(url) }
            }
        }
        .padding(16)
        .frame(width: 360)
    }

    private func search(_ model: PlayerModel) {
        let text = query.trimmingCharacters(in: .whitespaces)
        Task { await model.searchOnline(query: text.isEmpty ? nil : text) }
    }

    private func trackButton(title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Image(systemName: "checkmark").opacity(isSelected ? 1 : 0).foregroundStyle(Color.accentColor)
                Text(title).lineLimit(1).truncationMode(.middle)
                Spacer()
            }
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
