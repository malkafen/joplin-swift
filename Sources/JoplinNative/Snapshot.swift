import AppKit
import JoplinCore

@MainActor
enum Snapshot {
    static func scheduleIfRequested(model: AppModel, env: [String: String] = ProcessInfo.processInfo.environment,
                                    quit: @escaping @MainActor () -> Void = { NSApp.terminate(nil) }) {
        StressProbe.start(model: model)
        guard let path = env["JN_SNAPSHOT"] else { return }
        if model.sidebarSelection == nil { model.sidebarSelection = .allNotes }
        let delay = Double(env["JN_SNAPSHOT_DELAY"] ?? "") ?? 3
        if let profile = env["JN_IMPORT_DESKTOP"] {
            after(min(0.5, delay / 4)) {
                model.importJoplinDesktop(profile: profile == "1" ? Store.joplinDesktopProfile : URL(fileURLWithPath: profile))
            }
        }
        if let query = env["JN_SEARCH"] { model.searchText = query }
        if env["JN_VIM"] == "1" { model.vimMode = true }
        if env["JN_EXPAND_ALL"] == "1" { model.expandAllFolders() }
        if let offset = Double(env["JN_SIDEBAR_SCROLL"] ?? "") {
            after(delay * 0.7) {
                if let content = visibleWindow?.contentView { scrollSidebar(in: content, to: offset) }
            }
        }
        if let layout = env["JN_LAYOUT"].flatMap(EditorLayout.init(rawValue:)) { model.layout = layout }
        if let appearance = env["JN_APPEARANCE"] {
            NSApp.appearance = NSAppearance(named: appearance == "dark" ? .darkAqua : .aqua)
        }
        if let index = Int(env["JN_SELECT_INDEX"] ?? "") {
            after(min(1, delay / 2)) {
                if model.notes.indices.contains(index) { model.selectedNoteIDs = [model.notes[index].id] }
            }
        }
        if let keys = env["JN_VIM_KEYS"] {
            after(delay * 0.8) {
                guard let content = visibleWindow?.contentView, let vim = editor(in: content)?.vim else { return }
                for c in keys { vim.handle(key: c == "\n" ? "\r" : String(c)) }
            }
        }
        if let fraction = Double(env["JN_SCROLL"] ?? "") {
            after(delay * 0.75) {
                if let content = visibleWindow?.contentView { scrollAll(in: content, to: fraction) }
            }
        }
        after(delay) {
            if let window = visibleWindow, let rep = windowServerImage(window) ?? cachedImage(window) {
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            }
            if env["JN_SNAPSHOT_QUIT"] == "1" { quit() }
        }
    }

    private static func after(_ seconds: Double, _ body: @escaping @MainActor () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
            MainActor.assumeIsolated { body() }
        }
    }

    static var visibleWindow: NSWindow? {
        NSApp.windows.first { $0.isVisible && $0.contentView != nil }
    }

    static func editor(in view: NSView) -> MarkdownTextView? {
        if let tv = view as? MarkdownTextView { return tv }
        for sub in view.subviews { if let tv = editor(in: sub) { return tv } }
        return nil
    }

    static func scrollSidebar(in view: NSView, to offset: Double) {
        func find(_ v: NSView) -> FolderMarkerView? {
            if let marker = v as? FolderMarkerView { return marker }
            for sub in v.subviews { if let m = find(sub) { return m } }
            return nil
        }
        guard let scroll = find(view)?.enclosingScrollView else { return }
        scroll.contentView.scroll(to: NSPoint(x: 0, y: CGFloat(offset) - scroll.contentInsets.top))
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    static func scrollAll(in view: NSView, to fraction: Double) {
        if let scroll = view as? NSScrollView, let doc = scroll.documentView, doc is NSTextView {
            let maxY = max(0, doc.frame.height - scroll.contentView.bounds.height)
            scroll.contentView.scroll(to: NSPoint(x: 0, y: maxY * fraction))
            scroll.reflectScrolledClipView(scroll.contentView)
        }
        view.subviews.forEach { scrollAll(in: $0, to: fraction) }
    }

    static func windowServerImage(_ window: NSWindow) -> NSBitmapImageRep? {
        typealias CreateImage = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else { return nil }
        let create = unsafeBitCast(symbol, to: CreateImage.self)
        let includingWindow: UInt32 = 1 << 3, boundsIgnoreFraming: UInt32 = 1 << 0, bestResolution: UInt32 = 1 << 3
        guard let image = create(.null, includingWindow, UInt32(window.windowNumber), boundsIgnoreFraming | bestResolution)?
            .takeRetainedValue() else { return nil }
        return NSBitmapImageRep(cgImage: image)
    }

    static func cachedImage(_ window: NSWindow) -> NSBitmapImageRep? {
        guard let view = window.contentView?.superview ?? window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep
    }
}
