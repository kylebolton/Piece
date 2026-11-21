import AppKit
import SwiftUI

/// A small floating, non-activating toast near the bottom of the main screen.
/// Only one toast is shown at a time; a new one replaces the current one.
/// Clicking a toast dismisses it early.
@MainActor
enum Toast {
    private static var panel: NSPanel?
    private static var dismissTask: Task<Void, Never>?

    private static let fadeDuration: TimeInterval = 0.3
    private static let bottomOffset: CGFloat = 100
    private static let maxWidth: CGFloat = 300

    static func show(_ message: String, systemImage: String = "checkmark.circle.fill", duration: TimeInterval = 3) {
        dismissTask?.cancel()
        panel?.orderOut(nil)

        let controller = NSHostingController(rootView: ToastView(message: message, systemImage: systemImage) {
            Toast.dismiss()
        })
        let size = controller.sizeThatFits(in: CGSize(width: maxWidth, height: .greatestFiniteMagnitude))

        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentViewController = controller
        panel.setContentSize(size)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]

        if let screen = NSScreen.main?.visibleFrame {
            panel.setFrameOrigin(NSPoint(
                x: screen.midX - panel.frame.width / 2,
                y: screen.minY + bottomOffset
            ))
        }

        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = fadeDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().alphaValue = 1
        }
        Toast.panel = panel

        dismissTask = Task {
            try? await Task.sleep(for: .seconds(fadeDuration + duration))
            guard !Task.isCancelled else { return }
            dismiss()
        }
    }

    private static func dismiss() {
        dismissTask?.cancel()
        dismissTask = nil
        guard let panel else { return }
        Toast.panel = nil
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = fadeDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().alphaValue = 0
        }, completionHandler: {
            panel.orderOut(nil)
        })
    }
}

private struct ToastView: View {
    let message: String
    let systemImage: String
    let onTap: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .resizable()
                .scaledToFit()
                .frame(width: 16, height: 16)
            Text(message)
                .multilineTextAlignment(.leading)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(.ultraThickMaterial, in: RoundedRectangle(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(Color.primary.opacity(0.25), lineWidth: 1.5))
        .contentShape(RoundedRectangle(cornerRadius: 20))
        .onTapGesture(perform: onTap)
    }
}
