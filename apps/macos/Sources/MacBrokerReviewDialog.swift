import AppKit

@MainActor
enum MacBrokerReviewDialog {
    static func approve(_ scope: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Review exact package Apply"
        alert.informativeText = "Read the full device, package, removal and hash scope before approving."
        alert.addButton(withTitle: "Apply Exact Plan")
        alert.addButton(withTitle: "Cancel")
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 720, height: 400))
        scroll.hasVerticalScroller = true
        scroll.contentView.postsBoundsChangedNotifications = true
        let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 700, height: 400))
        text.isEditable = false; text.isSelectable = true; text.isRichText = false
        text.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        text.string = scope
        text.isVerticallyResizable = true; text.isHorizontallyResizable = false
        text.textContainer?.widthTracksTextView = true
        text.autoresizingMask = [.width]
        if let container = text.textContainer, let layout = text.layoutManager {
            layout.ensureLayout(for: container)
            text.frame.size.height = max(400, layout.usedRect(for: container).height + 24)
        }
        scroll.documentView = text
        alert.accessoryView = scroll
        let approve = alert.buttons[0]
        approve.isEnabled = false
        let update: () -> Void = {
            approve.isEnabled = scroll.contentView.documentVisibleRect.maxY >= text.bounds.maxY - 2
        }
        let observer = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: .main) { _ in
                update()
            }
        update()
        let response = alert.runModal()
        NotificationCenter.default.removeObserver(observer)
        return response == .alertFirstButtonReturn && approve.isEnabled
    }
}
