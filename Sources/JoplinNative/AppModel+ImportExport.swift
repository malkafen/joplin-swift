import AppKit
import JoplinCore
import UniformTypeIdentifiers

extension AppModel {
    static let jexType = UTType(filenameExtension: "jex") ?? .data

    private func runImport(_ name: String, _ body: () throws -> ImportReport) {
        flushSave()
        do {
            let report = try body()
            reloadAll()
            var message = report.description
            if let first = report.errors.first { message += "\n\nFirst error: \(first)" }
            alert = AlertInfo(title: "\(name) imported", message: message)
        } catch {
            alert = AlertInfo(title: "Import failed", message: "\(error)")
        }
    }

    func importJoplinDesktop(profile: URL = Store.joplinDesktopProfile) {
        runImport("Joplin Desktop profile") { try store.importJoplinDesktopProfile(profile) }
    }

    func importJEXWithPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [Self.jexType]
        panel.allowsOtherFileTypes = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        importJEX(url)
    }

    func importJEX(_ url: URL) {
        runImport(url.lastPathComponent) { try store.importJEX(url) }
    }

    func importRawWithPanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.message = "Choose a Joplin RAW export directory or a Joplin file-system sync folder"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        importRaw(url)
    }

    func importRaw(_ url: URL) {
        runImport(url.lastPathComponent) { try store.importDirectory(url) }
    }

    func exportFileName(folderId: String?) -> String {
        "\(folderId.map { folderTitle($0) } ?? "Joplin Export").jex"
    }

    func exportJEXWithPanel(folderId: String?) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [Self.jexType]
        panel.nameFieldStringValue = exportFileName(folderId: folderId)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        exportJEX(to: url, folderId: folderId)
    }

    func exportJEX(to url: URL, folderId: String?) {
        flushSave()
        do {
            let count = try store.exportJEX(to: url, folderId: folderId)
            alert = AlertInfo(title: "Export complete", message: "\(count) items written to \(url.lastPathComponent).")
        } catch {
            alert = AlertInfo(title: "Export failed", message: "\(error)")
        }
    }
}
