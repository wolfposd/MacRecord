import AppKit
import SwiftUI

/// A read-only, selectable text view that lays the whole message out as one text flow, so a selection can span
/// several lines and blocks. Right-click offers "Copy" and "Copy Entire Message".
struct SelectableTextView: NSViewRepresentable {
    let attributed: NSAttributedString
    let plainText: String

    func makeNSView(context: Context) -> MessageTextView {
        let view = MessageTextView()
        view.isEditable = false
        view.isSelectable = true
        view.drawsBackground = false
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = false
        view.isHorizontallyResizable = false
        view.isVerticallyResizable = false
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return view
    }

    func updateNSView(_ view: MessageTextView, context: Context) {
        view.plainText = plainText
        if !view.attributedString().isEqual(to: attributed) {
            view.textStorage?.setAttributedString(attributed)
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView view: MessageTextView, context: Context) -> CGSize? {
        let width = max(proposal.width ?? 400, 1)
        guard let container = view.textContainer, let layout = view.layoutManager else { return nil }
        container.size = NSSize(width: width, height: .greatestFiniteMagnitude)
        layout.ensureLayout(for: container)
        let used = layout.usedRect(for: container)
        return CGSize(width: min(width, ceil(used.width)), height: ceil(used.height))
    }
}

final class MessageTextView: NSTextView {
    var plainText = ""

    // Let the enclosing SwiftUI ScrollView handle scrolling.
    override func scrollWheel(with event: NSEvent) { nextResponder?.scrollWheel(with: event) }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        if selectedRange().length > 0 {
            menu.addItem(withTitle: "Copy", action: #selector(copy(_:)), keyEquivalent: "").target = self
        }
        let all = menu.addItem(withTitle: "Copy Entire Message", action: #selector(copyEntireMessage), keyEquivalent: "")
        all.target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Select All", action: #selector(selectAll(_:)), keyEquivalent: "").target = self
        return menu
    }

    @objc private func copyEntireMessage() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(plainText, forType: .string)
    }
}
