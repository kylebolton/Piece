import SwiftUI

extension View {
    /// Like `popover(isPresented:)`, but it stays open while the person works in another window of the app,
    /// such as the Colors panel a `ColorPicker` opens. SwiftUI's popovers close as soon as that panel is clicked,
    /// which also cuts the panel off from the picker. Content gets no environment from this view, so pass in
    /// what it needs.
    func semitransientPopover<Content: View>(isPresented: Binding<Bool>, arrowEdge: Edge = .bottom,
                                             @ViewBuilder content: @escaping () -> Content) -> some View {
        background(PopoverAnchor(isPresented: isPresented, arrowEdge: arrowEdge, content: content))
    }
}

private struct PopoverAnchor<Content: View>: NSViewRepresentable {
    @Binding var isPresented: Bool
    var arrowEdge: Edge
    var content: () -> Content

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        let coordinator = context.coordinator
        coordinator.onClose = { isPresented = false }
        if isPresented {
            if let popover = coordinator.popover {
                (popover.contentViewController as? NSHostingController<Content>)?.rootView = content()
            } else if view.window != nil {
                let controller = NSHostingController(rootView: content())
                controller.sizingOptions = .preferredContentSize
                let popover = NSPopover()
                popover.behavior = .semitransient
                popover.animates = true
                popover.contentViewController = controller
                popover.delegate = coordinator
                coordinator.popover = popover
                popover.show(relativeTo: view.bounds, of: view, preferredEdge: rectEdge(in: view))
            }
        } else if let popover = coordinator.popover {
            coordinator.popover = nil
            popover.close()
        }
    }

    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
        coordinator.popover?.close()
    }

    private func rectEdge(in view: NSView) -> NSRectEdge {
        switch arrowEdge {
        case .top: view.isFlipped ? .minY : .maxY
        case .bottom: view.isFlipped ? .maxY : .minY
        case .leading: .minX
        case .trailing: .maxX
        }
    }

    final class Coordinator: NSObject, NSPopoverDelegate {
        var popover: NSPopover?
        var onClose: () -> Void = {}

        func popoverDidClose(_ notification: Notification) {
            popover = nil
            onClose()
        }
    }
}
