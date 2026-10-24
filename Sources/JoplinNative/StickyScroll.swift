import AppKit
import Observation
import SwiftUI

@MainActor
@Observable
final class StickyFolders {
    struct Row: Equatable {
        var id: String
        var minY: CGFloat
        var maxY: CGFloat
        var minX: CGFloat = 0
    }

    private(set) var ids: [String] = []
    private(set) var rowHeight: CGFloat = 28
    private(set) var indents: [Int: CGFloat] = [:]

    var enabled = true {
        didSet { update() }
    }

    @ObservationIgnored var parentOf: [String: String] = [:] {
        didSet { update() }
    }

    @ObservationIgnored private var markers: [ObjectIdentifier: FolderMarkerView] = [:]
    @ObservationIgnored private(set) weak var scrollView: NSScrollView?
    @ObservationIgnored private var observer: NSObjectProtocol?
    @ObservationIgnored private var updateScheduled = false

    static let maxRows = 6

    func register(_ marker: FolderMarkerView) {
        markers[ObjectIdentifier(marker)] = marker
        if scrollView == nil, let scroll = marker.enclosingScrollView { attach(scroll) }
        scheduleUpdate()
    }

    func unregister(_ marker: FolderMarkerView) {
        markers[ObjectIdentifier(marker)] = nil
        scheduleUpdate()
    }

    func attach(_ scroll: NSScrollView) {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        scrollView = scroll
        scroll.contentView.postsBoundsChangedNotifications = true
        observer = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: scroll.contentView,
                                                          queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.update() }
        }
    }

    private func scheduleUpdate() {
        guard !updateScheduled else { return }
        updateScheduled = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                self?.updateScheduled = false
                self?.update()
            }
        }
    }

    func depth(_ id: String) -> Int { Self.ancestors(of: id, parentOf: parentOf).count }

    func update() {
        guard enabled, let scroll = scrollView, let document = scroll.documentView else {
            if !ids.isEmpty { ids = [] }
            return
        }
        var rows: [Row] = []
        for marker in markers.values where marker.window != nil && marker.window === scroll.window {
            guard let id = marker.folderId, !marker.isHiddenOrHasHiddenAncestor else { continue }
            let rowView = marker.enclosingRowView
            let frame = rowView.map { $0.convert($0.bounds, to: document) } ?? marker.convert(marker.bounds, to: document)
            let content = marker.convert(marker.bounds, to: document)
            rows.append(Row(id: id, minY: frame.minY, maxY: frame.maxY, minX: content.minX))
            if frame.height > 8 { rowHeight = frame.height }
        }
        for row in rows {
            let d = depth(row.id)
            if indents[d] != row.minX { indents[d] = row.minX }
        }
        let top = Self.visibleTop(of: scroll)
        let pinned = Self.sticky(rows: rows, top: top, rowHeight: rowHeight, parentOf: parentOf, maxRows: Self.maxRows)
        if pinned != ids { ids = pinned }
    }

    static func visibleTop(of scroll: NSScrollView) -> CGFloat {
        guard let document = scroll.documentView else { return 0 }
        let y = scroll.isFlipped ? scroll.contentInsets.top : scroll.bounds.maxY - scroll.contentInsets.top
        return document.convert(NSPoint(x: 0, y: y), from: scroll).y
    }

    static func ancestors(of id: String, parentOf: [String: String]) -> [String] {
        var chain: [String] = []
        var current = parentOf[id]
        while let p = current, !p.isEmpty, !chain.contains(p), p != id, chain.count < 64 {
            chain.insert(p, at: 0)
            current = parentOf[p]
        }
        return chain
    }

    static func sticky(rows: [Row], top: CGFloat, rowHeight: CGFloat, parentOf: [String: String], maxRows: Int) -> [String] {
        let sorted = rows.sorted { $0.minY < $1.minY }
        var pinned: [String] = []
        while pinned.count < 64 {
            let edge = top + CGFloat(pinned.count) * rowHeight
            guard let row = sorted.first(where: { $0.minY + $0.maxY > 2 * edge }) else { break }
            let chain = ancestors(of: row.id, parentOf: parentOf)
            guard chain.count > pinned.count, Array(chain.prefix(pinned.count)) == pinned else { break }
            let next = chain[pinned.count]
            if let own = sorted.first(where: { $0.id == next }), own.minY >= edge - 1 { break }
            pinned.append(next)
        }
        while let last = pinned.last {
            let bottom = top + CGFloat(pinned.count) * rowHeight
            guard let below = sorted.first(where: { $0.minY + $0.maxY > 2 * bottom }) else { break }
            if below.id != last, ancestors(of: below.id, parentOf: parentOf).contains(last) { break }
            pinned.removeLast()
        }
        return pinned.count > maxRows ? Array(pinned.suffix(maxRows)) : pinned
    }

    func reveal(_ id: String) {
        guard let scroll = scrollView, let document = scroll.documentView,
              let marker = markers.values.first(where: { $0.folderId == id && $0.window != nil }) else { return }
        let rowView = marker.enclosingRowView
        let frame = rowView.map { $0.convert($0.bounds, to: document) } ?? marker.convert(marker.bounds, to: document)
        let pinnedAbove = CGFloat(Self.ancestors(of: id, parentOf: parentOf).count) * rowHeight
        let shift = frame.minY - pinnedAbove - Self.visibleTop(of: scroll)
        let y = scroll.contentView.bounds.minY + shift
        scroll.contentView.scroll(to: NSPoint(x: scroll.contentView.bounds.minX, y: max(-scroll.contentInsets.top, y)))
        scroll.reflectScrolledClipView(scroll.contentView)
    }
}

final class FolderMarkerView: NSView {
    var folderId: String?
    weak var tracker: StickyFolders?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        MainActor.assumeIsolated {
            guard let tracker else { return }
            if window != nil { tracker.register(self) } else { tracker.unregister(self) }
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    var enclosingRowView: NSTableRowView? {
        var v = superview
        while let current = v {
            if let row = current as? NSTableRowView { return row }
            v = current.superview
        }
        return nil
    }
}

struct FolderMarker: NSViewRepresentable {
    let id: String
    let tracker: StickyFolders

    func makeNSView(context: Context) -> FolderMarkerView {
        let view = FolderMarkerView()
        view.folderId = id
        view.tracker = tracker
        return view
    }

    func updateNSView(_ view: FolderMarkerView, context: Context) {
        if view.folderId != id {
            view.folderId = id
            tracker.update()
        }
    }
}

struct StickyFolderHeader: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let sticky = model.sticky
        if !sticky.ids.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(sticky.ids.enumerated()), id: \.element) { index, id in
                    if let folder = model.folders.first(where: { $0.id == id }) {
                        let depth = sticky.depth(id)
                        let indent = sticky.indents[depth] ?? (12 + CGFloat(depth) * 16)
                        Button {
                            model.sidebarSelection = .folder(id)
                            sticky.reveal(id)
                        } label: {
                            FolderRow(folder: folder, accentIcon: true)
                                .lineLimit(1)
                                .padding(.leading, indent)
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .frame(height: sticky.rowHeight)
                        .help(model.folderPath(id))
                        .zIndex(Double(-index))
                    }
                }
            }
            .background(.bar)
            .overlay(alignment: .bottom) { Divider() }
            .transition(.opacity)
        }
    }
}
