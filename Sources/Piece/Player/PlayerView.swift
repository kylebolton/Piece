import AVKit
import SwiftUI
import UniformTypeIdentifiers

struct VideoSurface: NSViewRepresentable {
    var model: PlayerModel

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = model.player
        view.controlsStyle = .floating
        view.showsFullScreenToggleButton = true
        view.allowsPictureInPicturePlayback = true
        view.videoGravity = .resizeAspect

        // Full screen moves the AVPlayerView into a window of its own, leaving sibling SwiftUI
        // views behind. Subtitles live in its content overlay so they travel with the video.
        if let overlay = view.contentOverlayView {
            let activity = ControlsActivity()
            let host = SubtitleHostingView(rootView: SubtitleOverlay(model: model, activity: activity))
            host.activity = activity
            host.frame = overlay.bounds
            host.autoresizingMask = [.width, .height]
            overlay.addSubview(host)
        }
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== model.player { view.player = model.player }
    }
}

/// Whether the player's floating transport controls are probably showing, judged by mouse movement.
@MainActor @Observable
final class ControlsActivity {
    private(set) var isActive = false
    private var hideTask: Task<Void, Never>?

    func pulse() {
        if !isActive { isActive = true }
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            isActive = false
        }
    }

    func end() {
        hideTask?.cancel()
        isActive = false
    }
}

/// Hosts the subtitles inside the video's overlay. Lets clicks through to the player and watches the mouse,
/// since the window's own hover tracking doesn't reach a full-screen player.
private final class SubtitleHostingView: NSHostingView<SubtitleOverlay> {
    var activity: ControlsActivity?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas where area.owner === self { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { activity?.pulse() }
    override func mouseMoved(with event: NSEvent) { activity?.pulse() }
    override func mouseExited(with event: NSEvent) { activity?.end() }
}

/// Subtitles drawn by the app, so any file format and timing offset works.
struct SubtitleOverlay: View {
    var model: PlayerModel
    var activity: ControlsActivity

    var body: some View {
        GeometryReader { proxy in
            if let cue = model.cueText, !model.isExternal {
                VStack {
                    Spacer()
                    let style = AppSettings.shared.subtitleStyle
                    Text(cue)
                        .font(style.font(size: max(16, proxy.size.height * 0.045) * style.scale))
                        .multilineTextAlignment(.center)
                        .foregroundStyle(style.textColor)
                        .shadow(color: .black, radius: 2, x: 0, y: 1)
                        .shadow(color: .black.opacity(0.8), radius: 6)
                        .padding(.horizontal, 28)
                        // Step above the floating transport controls while they're showing.
                        .padding(.bottom, activity.isActive ? max(150, proxy.size.height * 0.3) : proxy.size.height * 0.07)
                        .frame(maxWidth: .infinity)
                }
                .animation(.easeOut(duration: 0.2), value: activity.isActive)
            }
        }
        .allowsHitTesting(false)
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
            VideoSurface(model: model)

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
                .liquidGlassEffect(type: .overlay)
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
                .liquidGlassEffect(type: .overlay)
                .environment(\.colorScheme, .dark)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            if let notice = model.notice {
                Label(notice, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .liquidGlassEffect(type: .overlay)
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
        .liquidGlassEffect(type: .card(cornerRadius: 18))
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
                trackButton(title: "Off", isSelected: model.selectedSubtitleID == nil && model.loadingSubtitleID == nil) {
                    Task { await model.select(subtitle: nil) }
                }
                ForEach(model.subtitleTracks) { track in
                    trackButton(title: track.menuTitle, id: track.id, model: model) {
                        Task { await model.select(subtitle: track) }
                    }
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("Find online").font(.subheadline.weight(.semibold))
                HStack {
                    TextField("Title (leave empty to match this file)", text: $query)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { search(model) }
                    Button("Search") { search(model) }
                        .disabled(model.isSearchingOnline)
                }
                onlineResults(model)
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

    /// What the online search is doing: a spinner while it runs, then the matches, or why there are none.
    @ViewBuilder
    private func onlineResults(_ model: PlayerModel) -> some View {
        switch model.onlineSearch {
        case .idle:
            EmptyView()

        case .searching:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Searching OpenSubtitles…")
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: 44)

        case .failed(let message):
            VStack(alignment: .leading, spacing: 6) {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Try Again") { search(model) }
            }

        case .finished(let searched):
            if model.onlineResults.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Label(searched.isEmpty ? "No subtitles found." : "No subtitles found for “\(searched)”.",
                          systemImage: "magnifyingglass")
                        .font(.callout)
                    Text("Only \(preferredLanguageNames) are searched. Try another spelling, or change the languages in Settings → Subtitles.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                let shown = model.onlineResults.prefix(30)
                Text(model.onlineResults.count > shown.count
                     ? "Showing \(shown.count) of \(model.onlineResults.count)" : "\(shown.count) found")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(shown) { result in
                            onlineRow(result, model: model)
                        }
                    }
                }
                .frame(
                    minHeight: 120,
                    maxHeight: 170
                )
            }
        }
    }

    private func onlineRow(_ result: OnlineSubtitle, model: PlayerModel) -> some View {
        let id = "online:\(result.fileID)"
        let isLoading = model.loadingSubtitleID == id
        let failure = model.subtitleFailures[id]
        return Button {
            Task { await model.select(online: result) }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(SubtitleLanguage.badge(for: result.language))
                        .font(.caption2.weight(.bold))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 3))
                        .help(SubtitleLanguage.name(for: result.language) ?? result.language)
                    Text(result.release).font(.caption).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 4)
                    if isLoading {
                        ProgressView().controlSize(.small)
                    } else {
                        if result.hearingImpaired {
                            Image(systemName: "ear").foregroundStyle(.secondary).help("For the deaf and hard of hearing")
                        }
                        if result.hashMatch {
                            Image(systemName: "checkmark.seal.fill").foregroundStyle(.green).help("Exact match for this file")
                        }
                        if failure != nil {
                            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
                        } else if model.selectedSubtitleID == id {
                            Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
                        }
                    }
                }
                if isLoading {
                    Text("Downloading…").font(.caption2).foregroundStyle(.secondary)
                } else if let failure {
                    Text(failure).font(.caption2).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isLoading)
    }

    private var preferredLanguageNames: String {
        let names = AppSettings.shared.subtitleLanguages.compactMap { SubtitleLanguage[$0]?.name }
        return names.isEmpty ? "your preferred languages" : names.formatted(.list(type: .and))
    }

    /// A track in the picker: a spinner while it loads, a checkmark when active, a warning if it failed.
    private func trackButton(title: String, id: String, model: PlayerModel, action: @escaping () -> Void) -> some View {
        let isLoading = model.loadingSubtitleID == id
        let failure = model.subtitleFailures[id]
        return trackButton(title: title, isSelected: model.selectedSubtitleID == id, isLoading: isLoading, failure: failure,
                           action: action)
    }

    private func trackButton(title: String, isSelected: Bool, isLoading: Bool = false, failure: String? = nil,
                             action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    ZStack {
                        Image(systemName: failure == nil ? "checkmark" : "exclamationmark.circle.fill")
                            .opacity(isSelected || failure != nil ? 1 : 0)
                            .foregroundStyle(failure == nil ? Color.accentColor : .orange)
                            .opacity(isLoading ? 0 : 1)
                        if isLoading { ProgressView().controlSize(.mini) }
                    }
                    .frame(width: 16)
                    Text(title).lineLimit(1).truncationMode(.middle)
                    Spacer()
                }
                if isLoading {
                    Text("Loading…").font(.caption2).foregroundStyle(.secondary).padding(.leading, 20)
                } else if let failure {
                    Text(failure).font(.caption2).foregroundStyle(.orange).padding(.leading, 20)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isLoading)
    }
}
