import AppKit
import JoplinCore

extension AppModel {
    func updateTitle(_ title: String) {
        guard var note = currentNote, note.title != title else { return }
        note.title = title
        currentNote = note
        patchSummary(note)
        scheduleSave()
    }

    func updateBody(_ body: String) {
        guard var note = currentNote else { return }
        note.body = body
        currentNote = note
        patchSummary(note)
        scheduleSave()
    }

    func editBody(_ body: String) {
        guard storedNote != nil else { return }
        storedNote!.body = body
        bodyRevision += 1
        summaryOutdated = true
        scheduleSave()
    }

    private func patchOutdatedSummary(_ note: Note) {
        guard summaryOutdated else { return }
        summaryOutdated = false
        patchSummary(note)
    }

    private func patchSummary(_ note: Note) {
        guard let i = notes.firstIndex(where: { $0.id == note.id }) else { return }
        var summary = notes[i]
        summary.title = note.title
        summary.snippet = Snippet.make(from: String(note.body.prefix(400)))
        summary.userUpdatedTime = Store.now()
        notes[i] = summary
    }

    private func scheduleSave() {
        pendingSave = true
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            self?.saveInBackground()
        }
    }

    func saveInBackground() {
        saveTask?.cancel()
        saveTask = nil
        guard pendingSave, let note = storedNote else { return }
        guard let writer else { return flushSave() }
        pendingSave = false
        patchOutdatedSummary(note)
        savingNotes[note.id, default: 0] += 1
        nonisolated(unsafe) let db = writer
        saveQueue.async { [weak self] in
            var failure: String?
            let time = Store.now()
            do { try Store.saveNote(note, in: db, at: time) } catch { failure = "\(error)" }
            let stamp = Store.BodyStamp(updatedTime: time, body: note.body)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.finishSave(note.id, stamp: stamp, failure: failure)
                }
            }
        }
    }

    private func finishSave(_ id: String, stamp: Store.BodyStamp, failure: String?) {
        if let count = savingNotes[id] { savingNotes[id] = count > 1 ? count - 1 : nil }
        if let failure {
            alert = AlertInfo(title: "Error", message: failure)
        } else {
            if storedNote?.id == id { loadedStamp = (id, stamp) }
            scheduleAutoSync()
        }
    }

    func waitForSaves() {
        saveQueue.sync {}
    }

    func flushSave() {
        saveTask?.cancel()
        saveTask = nil
        waitForSaves()
        guard pendingSave, let note = storedNote else { return }
        pendingSave = false
        patchOutdatedSummary(note)
        let time = Store.now()
        perform {
            try store.saveNote(note, at: time)
            loadedStamp = (note.id, Store.BodyStamp(updatedTime: time, body: note.body))
        }
    }

    func perform(_ body: () throws -> Void) {
        waitForSaves()
        do {
            try body()
            scheduleAutoSync()
        } catch {
            alert = AlertInfo(title: "Error", message: "\(error)")
        }
    }

    func toggleCheckbox(line: Int) {
        guard let note = currentNote, note.deletedTime == 0 else { return }
        var lines = note.body.components(separatedBy: "\n")
        guard line >= 1, line <= lines.count else { return }
        let s = lines[line - 1]
        if let r = s.range(of: "[ ]") {
            lines[line - 1] = s.replacingCharacters(in: r, with: "[x]")
        } else if let r = s.range(of: "[x]") ?? s.range(of: "[X]") {
            lines[line - 1] = s.replacingCharacters(in: r, with: "[ ]")
        } else {
            return
        }
        updateBody(lines.joined(separator: "\n"))
    }

    func handleLink(_ url: URL) {
        switch url.scheme {
        case "joplincheckbox":
            if let line = Int(url.host ?? "") { toggleCheckbox(line: line) }
        case "joplinitem":
            openItem(id: url.host ?? "")
        default:
            openURL(url)
        }
    }

    func attachmentMarkdown(for urls: [URL]) -> String? {
        var parts: [String] = []
        perform {
            for url in urls {
                let r = try store.addResource(fileAt: url)
                parts.append(r.isImage ? "![\(r.displayName)](:/\(r.id))" : "[\(r.displayName)](:/\(r.id))")
            }
        }
        return parts.isEmpty ? nil : parts.joined(separator: "\n")
    }

    func pastedImageMarkdown(_ png: Data) -> String? {
        var md: String?
        perform {
            let r = try store.addResource(data: png, filename: "Pasted image.png", mime: "image/png", fileExtension: "png")
            md = "![\(r.displayName)](:/\(r.id))"
        }
        return md
    }

    func attachFilesWithPanel() {
        guard currentNote != nil else { return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK else { return }
        attach(panel.urls)
    }

    func attach(_ urls: [URL]) {
        guard let note = currentNote, let md = attachmentMarkdown(for: urls) else { return }
        if editor.textView != nil, layout != .preview {
            editor.insert(md)
        } else {
            updateBody(note.body + (note.body.isEmpty || note.body.hasSuffix("\n") ? "" : "\n") + md)
        }
    }
}
