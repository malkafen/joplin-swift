import AppKit
import JoplinCore
import SwiftUI

@main
struct JoplinNativeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    private let model: AppModel

    init() {
        self.init(model: .shared)
    }

    init(model: AppModel) {
        self.model = model
    }

    var body: some Scene {
        Window("Joplin Native", id: "main") {
            ContentView()
                .environment(model)
                .frame(minWidth: 860, minHeight: 480)
        }
        .defaultSize(width: 1240, height: 780)
        .commands {
            SidebarCommands()
            AppCommands(model: model)
        }

        Settings {
            SettingsView()
                .environment(model)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    lazy var model: AppModel = .shared

    func applicationDidFinishLaunching(_ notification: Notification) {
        Snapshot.scheduleIfRequested(model: model)
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.flushSave()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.pathExtension.lowercased() == "jex" { model.importJEX(url) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
