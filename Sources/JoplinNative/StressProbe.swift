import AppKit

@MainActor
enum StressProbe {
    static var segments: [(start: Double, end: Double)] = []
    static var passStart = CFAbsoluteTimeGetCurrent()
    static var out: [[String: Any]] = []
    static var t0 = CFAbsoluteTimeGetCurrent()

    static func start(model: AppModel) {
        let env = ProcessInfo.processInfo.environment
        guard let log = env["JN_STRESS_LOG"] else { return }
        let begin = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.afterWaiting.rawValue, true, -3_000_000) { _, _ in
            passStart = CFAbsoluteTimeGetCurrent()
        }
        let finish = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, true, 3_000_000) { _, _ in
            let now = CFAbsoluteTimeGetCurrent()
            if now - passStart > 0.004 { segments.append((passStart, now)) }
            if segments.count > 20000 { segments.removeFirst(10000) }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), begin, .commonModes)
        CFRunLoopAddObserver(CFRunLoopGetMain(), finish, .commonModes)
        Task { @MainActor in
            await run(model: model, env: env)
            let data = try? JSONSerialization.data(withJSONObject: ["app": "Joplin Native", "steps": out], options: [.prettyPrinted])
            try? data?.write(to: URL(fileURLWithPath: log))
            NSApp.terminate(nil)
        }
    }

    static func now() -> Double { (CFAbsoluteTimeGetCurrent() - t0) * 1000 }
    static func mark() { t0 = CFAbsoluteTimeGetCurrent() }
    static func sleep(_ s: Double) async { try? await Task.sleep(nanoseconds: UInt64(s * 1e9)) }
    static func until(_ timeout: Double = 300, _ cond: () -> Bool) async -> Double? {
        while true {
            if cond() { return now() }
            if now() > timeout * 1000 { return nil }
            await sleep(0.005)
        }
    }
    static var settled = 0

    static func freeze(_ settle: Double = 0.5) async -> Int {
        await sleep(settle)
        let from = t0 - 0.05
        let recent = segments.filter { $0.end >= from }
        settled = Int(((recent.last { $0.end - max($0.start, from) > 0.1 }?.end).map { $0 - t0 } ?? 0) * 1000)
        return Int((recent.map { $0.end - max($0.start, from) }.max() ?? 0) * 1000)
    }

    static func log(_ step: String, _ kw: [String: Any]) {
        var kw = kw; kw["step"] = step; kw["at"] = Date().timeIntervalSince1970
        out.append(kw)
        if let d = try? JSONSerialization.data(withJSONObject: kw), let s = String(data: d, encoding: .utf8) { print(s) }
    }

    static func memory() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        _ = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) } }
        return Int(info.phys_footprint / 1_048_576)
    }

    static func r(_ v: Double?) -> Any { v.map { Int($0.rounded()) } ?? NSNull() }

    static func run(model: AppModel, env: [String: String]) async {
        let launchedAt = Double(env["JN_STRESS_T0"] ?? "") ?? 0
        t0 = CFAbsoluteTimeGetCurrent()
        if model.sidebarSelection == nil { model.sidebarSelection = .allNotes }
        _ = await until { !model.notes.isEmpty && model.searchStepper.editor?.window?.isVisible == true }
        log("launch", ["ready": Int((Date().timeIntervalSince1970 - launchedAt) * 1000), "start": launchedAt])
        await sleep(10)
        log("memory_idle", ["mb": memory(), "processes": 1])
        var lengths: [String: Int] = [:]
        func opened(_ id: String) -> Bool {
            guard let note = model.currentNote, note.id == id, let editor = model.searchStepper.editor else { return false }
            let n = lengths[id] ?? { let n = note.body.utf16.count; lengths[id] = n; return n }()
            return editor.textStorage?.length == n
        }
        func previewTail(_ text: String) -> Bool {
            guard let s = model.searchStepper.preview?.textStorage, s.length > 0 else { return false }
            let from = max(0, s.length - 300)
            return s.mutableString.substring(from: from).contains(text)
        }
        func layout(_ l: EditorLayout) async -> Double? {
            mark(); model.layout = l
            return await until {
                switch l {
                case .editor: return model.searchStepper.editor?.window != nil && model.searchStepper.editor?.visibleRect.isEmpty == false
                default: return model.searchStepper.preview?.window != nil
                }
            }
        }
        func folder(_ name: String) async {
            if let f = model.folders.first(where: { $0.title == name }) { model.sidebarSelection = .folder(f.id) }
            await sleep(1.5)
        }

        let only = env["JN_STRESS_ONLY"] ?? ""
        model.layout = .editor
        await folder("Notebook 00")
        let ids = model.notes.dropFirst().prefix(20).map(\.id)
        var times: [Double] = [], freezes: [Int] = []
        for id in ids where only.isEmpty {
            mark(); model.selectedNoteIDs = [id]
            times.append(await until { opened(id) } ?? 300_000)
            freezes.append(await freeze(0.3))
        }
        let sorted = times.sorted()
        if only.isEmpty { log("switch_notes", ["n": times.count, "median": r(sorted[sorted.count / 2]), "max": r(sorted.last), "freeze_max": freezes.max() ?? 0]) }

        await folder("Huge")
        for name in ["Huge 1 MB", "Huge 5 MB", "Huge 20 MB"] where only.isEmpty || only == name {
            guard let id = model.notes.first(where: { $0.title == name })?.id else { continue }
            let marker = "STRESSEND " + name.replacingOccurrences(of: " ", with: "")
            let typed = name.replacingOccurrences(of: " ", with: "") + "abcde"
            model.layout = .editor; await sleep(1)
            mark(); model.selectedNoteIDs = [id]
            log("open_editor", ["note": name, "ready": r(await until { opened(id) }), "freeze": await freeze(), "settled": settled])
            _ = await layout(.split)
            log("to_split", ["note": name, "ready": r(await until { previewTail(marker) }), "freeze": await freeze(), "settled": settled])
            guard let editor = model.searchStepper.editor else { continue }
            editor.window?.makeFirstResponder(editor)
            await sleep(0.5)
            mark(); editor.moveToEndOfDocument(nil)
            let jumped = await until { model.searchStepper.editor.map { $0.visibleRect.maxY >= $0.bounds.maxY - 50 } ?? false }
            log("jump_end", ["note": name, "ready": r(jumped), "freeze": await freeze(1.5), "settled": settled])
            editor.moveLeft(nil)
            await sleep(1)
            var lat: [Double] = []
            var lastKey = 0.0
            mark()
            for ch in "abcde" {
                let s = CFAbsoluteTimeGetCurrent()
                lastKey = now()
                editor.insertText(String(ch), replacementRange: editor.selectedRange())
                let n = segments.count
                _ = await until { segments.count > n || CFAbsoluteTimeGetCurrent() - s > 0.004 }
                lat.append(((segments.last.map { $0.end > s ? $0.end : CFAbsoluteTimeGetCurrent() } ?? CFAbsoluteTimeGetCurrent()) - s) * 1000)
                await sleep(0.25)
            }
            let up = await until { previewTail(typed) }
            let ls = lat.sorted()
            log("typing_split", ["note": name, "key_median": r(ls[ls.count / 2]), "key_max": r(ls.last),
                                 "preview_updated": r(up.map { $0 - lastKey }), "freeze": await freeze(), "settled": settled])
            _ = await layout(.preview)
            log("to_preview", ["note": name, "ready": r(await until { previewTail(typed) }), "freeze": await freeze(), "settled": settled])
            log("to_editor", ["note": name, "ready": r(await layout(.editor)), "freeze": await freeze(), "settled": settled])
        }

        model.layout = .split
        func id(_ title: String) -> String? { model.notes.first { $0.title == title }?.id }
        for (prev, name) in [("Huge 20 MB", "Huge 1 MB"), ("Huge 1 MB", "Huge 5 MB"), ("Huge 5 MB", "Huge 20 MB")] where only.isEmpty || only == name {
            guard let p = id(prev), let n = id(name) else { continue }
            model.selectedNoteIDs = [p]
            _ = await until { previewTail("STRESSEND " + prev.replacingOccurrences(of: " ", with: "")) }
            await sleep(3)
            mark(); model.selectedNoteIDs = [n]
            let ready = await until { previewTail("STRESSEND " + name.replacingOccurrences(of: " ", with: "")) }
            log("open_split", ["note": name, "ready": r(ready), "freeze": await freeze(2), "settled": settled])
        }
        if only.isEmpty || only == "search" { await searchStep(model: model, env: env, previewTail: previewTail) }
        log("memory_end", ["mb": memory(), "processes": 1])
    }

    static func searchStep(model: AppModel, env: [String: String], previewTail: (String) -> Bool) async {
        if let f = model.folders.first(where: { $0.title == "Huge" }) { model.sidebarSelection = .folder(f.id) }
        await sleep(1.5)
        model.layout = .split
        if let id = model.notes.first(where: { $0.title == "Huge 5 MB" })?.id {
            model.selectedNoteIDs = [id]
            _ = await until { previewTail("STRESSEND Huge5MB") }
        }
        await sleep(3)
        let query = "значение"
        let expected = Int(env["JN_STRESS_EXPECTED"] ?? "") ?? 0
        mark()
        for i in 1...query.count {
            model.searchText = String(query.prefix(i))
            await sleep(0.2)
        }
        let typedEnd = now()
        let res = await until(20) { model.notes.count == expected }
        log("search_typing", ["query": query, "expected": expected, "results_after_last_key": r(res.map { $0 - typedEnd }),
                              "freeze": await freeze(1), "settled": settled, "results": model.notes.count])
    }
}
