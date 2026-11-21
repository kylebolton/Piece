import AppKit
import Foundation
import IOKit.ps
import Network

/// Decides when transfers have to wait: on battery power or on a metered connection, when the user
/// asked for that. Transfers the user resumes anyway, and the one being played, keep going; those
/// overrides last until the conditions change (plugging in, leaving the metered network…).
@MainActor
@Observable
final class TransferPolicy {
    enum Reason: Hashable {
        case battery, metered
    }

    /// Whether this Mac runs on a battery at all; the battery option only makes sense when it does.
    private(set) var hasBattery = false
    private(set) var onBattery = false
    /// The last connection seen with a network up. Unknown until the first path arrives; counted as
    /// metered meanwhile so nothing gets out on a hotspot at launch.
    private(set) var isMetered: Bool?
    /// The user chose to transfer anyway.
    private(set) var isOverridden = false
    /// Transfers the user resumed while held.
    private(set) var resumedAnyway: Set<String> = []
    /// The transfer being played; it keeps downloading so playback doesn't stall.
    var playingHash: String? { didSet { if playingHash != oldValue { publish() } } }

    /// Why transfers would wait right now, ignoring the overrides.
    private(set) var reasons: Set<Reason> = []
    /// Transfers are being held.
    var isHolding: Bool { !reasons.isEmpty && !isOverridden }

    /// Called whenever the hold or its exemptions change.
    @ObservationIgnored var onChange: ((_ active: Bool, _ exempt: Set<String>) -> Void)?

    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private var pathMonitor: NWPathMonitor?
    @ObservationIgnored private var powerSource: CFRunLoopSource?
    @ObservationIgnored private var wakeObserver: NSObjectProtocol?
    @ObservationIgnored private var published: (active: Bool, exempt: Set<String>)?

    init(settings: AppSettings) {
        self.settings = settings
        (hasBattery, onBattery) = Self.readPower()
    }

    /// Starts watching power and network, and publishes the first decision straight away so the
    /// engine knows it before any transfer is restored.
    func start() {
        guard pathMonitor == nil else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let up = path.status == .satisfied
            let metered = path.isExpensive || path.isConstrained
            Task { @MainActor in self?.pathChanged(up: up, metered: metered) }
        }
        monitor.start(queue: DispatchQueue(label: "Piece.policy.path"))
        pathMonitor = monitor

        let context = Unmanaged.passUnretained(self).toOpaque()
        if let source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let policy = Unmanaged<TransferPolicy>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { policy.powerChanged() }
        }, context)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            powerSource = source
        }
        // Power changes while asleep aren't always announced.
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.powerChanged() }
        }
        observeSettings()
        update()
    }

    /// "Resume Anyway": transfer until the conditions change.
    func overrideHold() {
        guard !isOverridden else { return }
        isOverridden = true
        publish()
    }

    /// Holds transfers again after "Resume Anyway".
    func endOverride() {
        guard isOverridden || !resumedAnyway.isEmpty else { return }
        isOverridden = false
        resumedAnyway = []
        publish()
    }

    /// The user resumed this transfer while held: let it run until the conditions change.
    func resumeAnyway(_ hash: String) {
        guard resumedAnyway.insert(hash).inserted else { return }
        publish()
    }

    /// The user paused it; it no longer needs an exemption.
    func forget(_ hash: String) {
        guard resumedAnyway.remove(hash) != nil else { return }
        publish()
    }

    var summary: String {
        switch (reasons.contains(.battery), reasons.contains(.metered)) {
        case (true, true): "on battery power and a metered connection"
        case (true, false): "on battery power"
        case (false, true): isMetered == nil ? "until the connection is checked" : "on a metered connection"
        case (false, false): ""
        }
    }

    /// Status line text for a held transfer.
    var heldStatus: String {
        switch (reasons.contains(.battery), reasons.contains(.metered)) {
        case (true, true): "Waiting for power and an unmetered network"
        case (true, false): "Waiting for power"
        default: "Waiting for an unmetered network"
        }
    }

    // MARK: - Inputs

    private func pathChanged(up: Bool, metered: Bool) {
        // A network dropping for a moment isn't a change of conditions; keep what was last known.
        guard up, isMetered != metered else { return }
        isMetered = metered
        update()
    }

    private func powerChanged() {
        let (battery, unplugged) = Self.readPower()
        if hasBattery != battery { hasBattery = battery }
        if onBattery != unplugged { onBattery = unplugged }
        update()
    }

    private func observeSettings() {
        withObservationTracking {
            _ = settings.pauseOnBattery
            _ = settings.pauseOnMetered
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.update()
                self?.observeSettings()
            }
        }
    }

    private func update() {
        var now = Set<Reason>()
        if settings.pauseOnBattery, hasBattery, onBattery { now.insert(.battery) }
        if settings.pauseOnMetered, isMetered ?? true { now.insert(.metered) }
        if now != reasons {
            reasons = now
            // Overrides were given for the old conditions.
            isOverridden = false
            resumedAnyway = []
        }
        publish()
    }

    private func publish() {
        guard let onChange else { return }
        var exempt = resumedAnyway
        if let playingHash { exempt.insert(playingHash) }
        let decision = (active: isHolding, exempt: isHolding ? exempt : [])
        guard published?.active != decision.active || published?.exempt != decision.exempt else { return }
        published = decision
        onChange(decision.active, decision.exempt)
    }

    private nonisolated static func readPower() -> (hasBattery: Bool, onBattery: Bool) {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else { return (false, false) }
        let providing = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String?
        let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] ?? []
        let hasBattery = sources.contains { source in
            let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any]
            return description?[kIOPSTypeKey] as? String == kIOPSInternalBatteryType
        }
        return (hasBattery, hasBattery && providing == kIOPSBatteryPowerValue)
    }
}
