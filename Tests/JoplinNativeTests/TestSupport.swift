import AppKit
import Foundation
@testable import JoplinCore
@testable import JoplinNative

func temporaryDirectory(_ prefix: String = "jn-ui-test") -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

func fixtureId(_ n: Int) -> String {
    String(format: "%032x", n)
}

let tinyPNG = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==")!

@MainActor
final class ModelHarness {
    let store: Store
    let defaults: UserDefaults
    let pasteboard: NSPasteboard
    let server: FakeJoplinServer
    private(set) var opened: [URL] = []
    private(set) lazy var model: AppModel = {
        let model = AppModel(store: store, defaults: defaults, pasteboard: pasteboard, syncTransport: server) { [unowned self] in
            self.opened.append($0)
        }
        model.findPasteboard = findPasteboard
        model.searchDelay = 0
        return model
    }()
    let findPasteboard = NSPasteboard(name: NSPasteboard.Name("jn-find-\(UUID().uuidString)"))

    init(welcome: Bool = true, server: FakeJoplinServer = FakeJoplinServer(), directory: URL = temporaryDirectory(),
         defaults configure: (UserDefaults) -> Void = { _ in }) throws {
        self.server = server
        store = try Store(directory: directory)
        if !welcome { store.setSetting("welcome_created", "1") }
        let suite = "jn-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        configure(defaults)
        pasteboard = NSPasteboard(name: NSPasteboard.Name("jn-tests-\(UUID().uuidString)"))
    }

    deinit {
        pasteboard.releaseGlobally()
        findPasteboard.releaseGlobally()
    }
}
