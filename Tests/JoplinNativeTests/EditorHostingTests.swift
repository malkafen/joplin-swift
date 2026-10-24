import AppKit
import SwiftUI
import Testing
@testable import JoplinNative

@MainActor
@Suite(.serialized) struct EditorHostingTests {
    @MainActor
    final class Host {
        let window: NSWindow
        let host: NSHostingView<MarkdownEditor>
        let bridge = EditorBridge()
        let stepper = SearchStepper()
        var changes: [String] = []
        var modes: [VimEngine.Mode] = []

        init(_ text: String) {
            _ = NSApplication.shared
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled, .resizable],
                              backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            host = NSHostingView(rootView: MarkdownEditor(text: "", noteId: "", typography: Typography(), readableWidth: false,
                                                          isEditable: true, bridge: bridge, onChange: { _ in },
                                                          onDropFiles: { _ in nil }, onPasteImage: { _ in nil }))
            host.frame = window.contentLayoutRect
            window.contentView = host
            update(text)
        }

        func update(_ text: String, noteId: String = "n", typography: Typography = Typography(), highlights: [String] = [],
                    vim: Bool = false, editable: Bool = true, readable: Bool = true) {
            host.rootView = MarkdownEditor(text: text, noteId: noteId, typography: typography, readableWidth: readable,
                                           highlights: highlights, vimMode: vim, onVimMode: { [unowned self] in modes.append($0) },
                                           isEditable: editable, bridge: bridge, stepper: stepper,
                                           onChange: { [unowned self] in changes.append($0) },
                                           onDropFiles: { _ in "dropped" }, onPasteImage: { _ in "pasted" })
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }

        var textView: MarkdownTextView { bridge.textView as! MarkdownTextView }
        var coordinator: MarkdownEditor.Coordinator { textView.delegate as! MarkdownEditor.Coordinator }

        func wait(_ done: () -> Bool) {
            let deadline = Date().addingTimeInterval(30)
            while !done(), Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        }
    }

    @Test func loadsEditsAndReportsChanges() {
        let h = Host("# Title\n\nbody")
        let tv = h.textView
        #expect(tv.string == "# Title\n\nbody")
        #expect(tv.maxLineWidth != nil)
        tv.setSelectedRange(NSRange(location: 13, length: 0))
        tv.insertText("!", replacementRange: tv.selectedRange())
        #expect(h.changes.last == "# Title\n\nbody!")
        h.update("# Title\n\nbody!")
        #expect(tv.string == "# Title\n\nbody!")
        h.update("# Title\n\nchanged elsewhere")
        #expect(tv.string == "# Title\n\nchanged elsewhere")
        #expect(tv.selectedRange().location <= (tv.string as NSString).length)
        h.update("# Title\n\nchanged elsewhere", editable: false, readable: false)
        #expect(!tv.isEditable && tv.maxLineWidth == nil)
        h.update("other note", noteId: "m")
        #expect(tv.string == "other note" && tv.selectedRange().location == 0)
        h.window.close()
    }

    @Test func typographyRestylesTheText() throws {
        let h = Host("plain **bold**")
        h.update("plain **bold**", typography: Typography(family: .monospaced, size: 20))
        let font = try #require(h.textView.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        #expect(font.pointSize == 20 && font.isFixedPitch)
        #expect((h.textView.typingAttributes[.font] as? NSFont)?.pointSize == 20)
        h.window.close()
    }

    @Test func vimModeComesAndGoes() {
        let h = Host("line one\nline two")
        h.update("line one\nline two", vim: true)
        #expect(h.textView.vim != nil)
        #expect(h.modes.last == .normal)
        h.textView.vim?.handle(key: "v")
        h.update("line one\nline two", vim: false)
        #expect(h.textView.vim == nil)
        #expect(h.textView.selectedRange().length == 0)
        h.window.close()
    }

    @Test func searchTermsRevealTheFirstMatch() {
        let body = (1...200).map { "line \($0)" }.joined(separator: "\n") + "\nneedle"
        let h = Host(body)
        h.window.orderFront(nil)
        h.update(body, highlights: ["needle"])
        #expect(h.coordinator.searchTerms == ["needle"])
        let visible = h.textView.visibleRect
        #expect(visible.minY > 0)
        h.update(body, highlights: [])
        h.window.orderOut(nil)
        h.window.close()
    }

    @Test func hugeNotesLoadInTheBackground() {
        let body = "# Huge\n\n" + (1...40_000).map { "Paragraph \($0) with **bold** and `code`.\n\n" }.joined()
        let h = Host(body)
        let tv = h.textView
        #expect(h.coordinator.isLoadingInBackground)
        #expect(!tv.isEditable)
        #expect((tv.string as NSString).length < (body as NSString).length)
        h.wait { !h.coordinator.isLoadingInBackground }
        #expect(tv.isEditable)
        #expect(tv.textStorage?.length == (body as NSString).length)
        #expect(tv.textStorage?.delegate === h.coordinator)

        let edited = body + "tail"
        tv.setSelectedRange(NSRange(location: 20, length: 0))
        h.update(edited, typography: Typography(size: 18))
        h.update(edited, highlights: ["Paragraph 39999"])
        h.wait { !h.coordinator.isLoadingInBackground && tv.textStorage?.length == (edited as NSString).length }
        #expect(tv.string.hasSuffix("tail"))
        #expect(tv.selectedRange().location == 20)

        h.update(body, noteId: "other")
        h.update("small", noteId: "third")
        h.wait { !h.coordinator.isLoadingInBackground }
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        #expect(tv.string == "small")
        h.window.close()
    }

    @Test func findPanelActionsStepThroughTheSearch() {
        let h = Host("alpha beta alpha")
        let tv = h.textView
        (tv.layoutManager as? SearchMarkingLayoutManager)?.searchTerms = ["alpha"]
        let next = NSMenuItem(title: "Next", action: #selector(NSTextView.performFindPanelAction(_:)), keyEquivalent: "")
        next.tag = NSTextFinder.Action.nextMatch.rawValue
        #expect(tv.validateUserInterfaceItem(next))
        tv.setSelectedRange(NSRange(location: 1, length: 0))
        tv.performFindPanelAction(next)
        #expect(tv.selectedRange() == NSRange(location: 11, length: 5))
        let other = NSMenuItem(title: "Other", action: #selector(NSTextView.performFindPanelAction(_:)), keyEquivalent: "")
        other.tag = NSTextFinder.Action.showFindInterface.rawValue
        _ = tv.validateUserInterfaceItem(other)
        tv.performFindPanelAction(other)
        h.window.close()
    }

    @Test func keysReachTheTextViewOrVim() throws {
        let h = Host("abc")
        let tv = h.textView
        h.window.makeFirstResponder(tv)
        tv.setSelectedRange(NSRange(location: 3, length: 0))
        let key = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                windowNumber: h.window.windowNumber, context: nil, characters: "d",
                                                charactersIgnoringModifiers: "d", isARepeat: false, keyCode: 2))
        tv.keyDown(with: key)
        #expect(tv.string == "abcd")
        h.update("abcd", vim: true)
        tv.keyDown(with: key)
        #expect(tv.string == "abcd")
        h.window.close()
    }

    @Test func leadingParagraphsOfBridgedText() {
        let text = NSMutableString(string: String(repeating: "word ", count: 10) + "\n\n" + String(repeating: "x", count: 100)) as String
        #expect(text.leadingParagraphs(limit: 60) == String(repeating: "word ", count: 10))
        let unbroken = NSMutableString(string: String(repeating: "y", count: 100)) as String
        #expect(unbroken.leadingParagraphs(limit: 30).count == 30)
        #expect("short".leadingParagraphs(limit: 30) == "short")
    }
}
