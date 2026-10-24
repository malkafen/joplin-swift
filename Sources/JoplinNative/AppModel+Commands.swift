import AppKit
import JoplinCore

extension AppModel {
    static let fontSizes: ClosedRange<Double> = 9...36

    var editorTypography: Typography {
        Typography(family: editorFont, size: CGFloat(editorFontSize), codeFamily: codeFont)
    }

    var previewTypography: Typography {
        Typography(family: previewFont, size: CGFloat(previewFontSize), codeFamily: codeFont)
    }

    func adjustTextSize(by step: Double) {
        let range = Self.fontSizes
        editorFontSize = min(range.upperBound, max(range.lowerBound, editorFontSize + step))
        previewFontSize = min(range.upperBound, max(range.lowerBound, previewFontSize + step))
    }

    func resetTextSize() {
        editorFontSize = 14
        previewFontSize = 15
    }

    func cycleLayout() {
        let all = EditorLayout.allCases
        layout = all[((all.firstIndex(of: layout) ?? 0) + 1) % all.count]
    }

    func focusTitle() {
        titleFocusRequest += 1
    }

    func focusTags() {
        if !showNoteTags { showNoteTags = true }
        DispatchQueue.main.async { [weak self] in
            guard let field = self?.tagField else { return }
            field.window?.makeFirstResponder(field)
        }
    }

    func focusSearch(in window: NSWindow? = nil) {
        guard let window = window ?? NSApp.keyWindow ?? NSApp.mainWindow else { return }
        if let item = window.toolbar?.items.compactMap({ $0 as? NSSearchToolbarItem }).first {
            item.beginSearchInteraction()
            return
        }
        if let root = window.contentView?.superview, let field = Self.firstSearchField(in: root) {
            window.makeFirstResponder(field)
        }
    }

    private static func firstSearchField(in view: NSView) -> NSSearchField? {
        if let field = view as? NSSearchField { return field }
        for sub in view.subviews {
            if let field = firstSearchField(in: sub) { return field }
        }
        return nil
    }

    func stepMatch(forward: Bool) {
        guard currentNote != nil, let tv = layout == .preview ? searchStepper.preview : searchStepper.editor else { return }
        searchStepper.step(forward: forward, in: tv)
    }

    func findInNote(in window: NSWindow? = nil) {
        let window = window ?? NSApp.keyWindow
        let preview = searchStepper.preview
        let inPreview = layout == .preview || (preview != nil && window?.firstResponder === preview)
        guard currentNote != nil, let tv = inPreview ? preview : searchStepper.editor, let window = tv.window else {
            NSSound.beep()
            return
        }
        window.makeFirstResponder(tv)
        let item = NSMenuItem()
        item.tag = NSTextFinder.Action.showFindInterface.rawValue
        tv.performTextFinderAction(item)
    }

    func hotkey(for action: ShortcutAction) -> Hotkey? {
        if let custom = shortcuts[action] { return custom }
        return action.defaultHotkey
    }

    func setHotkey(_ hotkey: Hotkey?, for action: ShortcutAction) {
        shortcuts[action] = .some(hotkey)
        defaults.set(hotkey?.storage ?? "", forKey: action.defaultsKey)
    }

    func resetShortcut(_ action: ShortcutAction) {
        shortcuts[action] = nil
        defaults.removeObject(forKey: action.defaultsKey)
    }

    func restoreShortcuts() {
        for action in ShortcutAction.allCases {
            guard let stored = defaults.string(forKey: action.defaultsKey) else { continue }
            let hotkey = Hotkey(storage: stored)
            if let latin = hotkey?.latinized() {
                setHotkey(latin, for: action)
            } else {
                shortcuts[action] = .some(hotkey)
            }
        }
    }

    func shortcutConflict(for action: ShortcutAction) -> String? {
        guard let key = hotkey(for: action) else { return nil }
        if let other = ShortcutAction.allCases.first(where: { $0 != action && hotkey(for: $0) == key }) { return other.title }
        return ShortcutAction.reserved[key]
    }

    func startRecordingShortcut(_ action: ShortcutAction) {
        stopRecordingShortcut()
        recordingShortcut = action
        shortcutMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return self.recordShortcut(event) ? nil : event
        }
    }

    func stopRecordingShortcut() {
        if let monitor = shortcutMonitor { NSEvent.removeMonitor(monitor) }
        shortcutMonitor = nil
        recordingShortcut = nil
    }

    @discardableResult
    func recordShortcut(_ event: NSEvent) -> Bool {
        guard let action = recordingShortcut else { return false }
        let plain = event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty
        if event.keyCode == 53 && plain {
            stopRecordingShortcut()
            return true
        }
        if (event.keyCode == 51 || event.keyCode == 117) && plain {
            setHotkey(nil, for: action)
            stopRecordingShortcut()
            return true
        }
        guard let hotkey = Hotkey(event: event) else {
            NSSound.beep()
            return true
        }
        setHotkey(hotkey, for: action)
        stopRecordingShortcut()
        return true
    }
}
