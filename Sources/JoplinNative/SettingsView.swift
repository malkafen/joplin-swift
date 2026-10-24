import JoplinCore
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        TabView {
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gearshape") }
            TextSettings()
                .tabItem { Label("Text", systemImage: "textformat") }
            ShortcutSettings()
                .tabItem { Label("Shortcuts", systemImage: "command") }
            SyncSettings()
                .tabItem { Label("Sync", systemImage: "arrow.triangle.2.circlepath") }
        }
        .onDisappear { model.stopRecordingShortcut() }
        .frame(width: 520)
    }
}

struct GeneralSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                Picker("Default layout", selection: $model.layout) {
                    ForEach(EditorLayout.allCases) { Text($0.label).tag($0) }
                }
                Picker("Sort notes by", selection: $model.sort) {
                    NoteSortOptions()
                }
                Toggle("Uncompleted to-dos on top", isOn: $model.uncompletedTodosOnTop)
                Toggle("Show the date and start of each note in the list", isOn: $model.showNotePreviews)
            }
            Section("Sidebar") {
                Toggle("Keep parent notebooks visible while scrolling", isOn: $model.stickyNotebooks)
            }
            Section("Tags") {
                Toggle("Show tags in the sidebar", isOn: $model.showSidebarTags)
                Toggle("Show tags above notes", isOn: $model.showNoteTags)
            }
            Section("Data") {
                LabeledContent("Location") {
                    Text(model.store.directory.path)
                        .textSelection(.enabled)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([model.store.directory])
                }
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
    }
}

struct TextSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            Section("Editor") {
                FontPicker(title: "Font", selection: $model.editorFont)
                SizeStepper(value: $model.editorFontSize)
                Toggle("Vim key bindings", isOn: $model.vimMode)
            }
            Section("Preview") {
                FontPicker(title: "Font", selection: $model.previewFont)
                SizeStepper(value: $model.previewFontSize)
                Toggle("Load images from the web", isOn: $model.loadRemoteImages)
            }
            Section {
                FontPicker(title: "Code font", selection: $model.codeFont)
                Toggle("Limit line length for easier reading", isOn: $model.readableWidth)
            } footer: {
                Text("⌘+ and ⌘− change the text size of the editor and the preview together, ⌘0 restores it.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
    }
}

struct ShortcutSettings: View {
    var body: some View {
        Form {
            Section {
                ForEach(ShortcutAction.allCases) { ShortcutRecorder(action: $0) }
            } header: {
                Text("Editor layout")
            } footer: {
                Text("Click a shortcut and press the new keys. Esc cancels, ⌫ removes the shortcut.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
    }
}

struct FontPicker: View {
    let title: String
    @Binding var selection: FontFamily
    @State private var installed: [FontFamily] = []

    var body: some View {
        Picker(title, selection: $selection) {
            ForEach(FontFamily.systemDesigns) { Text($0.label).tag($0) }
            Divider()
            ForEach(installed) { Text($0.label).tag($0) }
            if !FontFamily.systemDesigns.contains(selection), !installed.contains(selection) {
                Text(selection.label).tag(selection)
            }
        }
        .onAppear { if installed.isEmpty { installed = FontFamily.installed } }
    }
}

struct SizeStepper: View {
    @Binding var value: Double

    var body: some View {
        LabeledContent("Size") {
            Stepper(value: $value, in: AppModel.fontSizes, step: 1) {
                Text("\(Int(value)) pt").monospacedDigit()
            }
        }
    }
}

struct SyncSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                TextField("Server URL", text: $model.syncURL, prompt: Text("https://joplin.example.com"))
                    .textContentType(.URL)
                TextField("Email", text: $model.syncEmail, prompt: Text("you@example.com"))
                    .textContentType(.username)
                SecureField("Password", text: $model.syncPassword)
                    .textContentType(.password)
                Picker("Sync automatically", selection: $model.syncInterval) {
                    Text("Manually").tag(0)
                    Text("Every minute").tag(1)
                    Text("Every 5 minutes").tag(5)
                    Text("Every 15 minutes").tag(15)
                    Text("Every hour").tag(60)
                }
                SyncSettingsStatus()
            } header: {
                Text("Joplin Server")
            } footer: {
                Text("Uses the same sync target as the Joplin apps. End-to-end encrypted targets are not supported yet.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct SyncSettingsStatus: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.syncStatusLine)
                if !model.syncDetail.isEmpty {
                    Text(model.syncDetail).font(.caption).lineLimit(4)
                }
            }
            .foregroundStyle(model.syncFailed ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
            .textSelection(.enabled)
            Spacer()
            if model.isSyncing { ProgressView().controlSize(.small) }
            Button("Sync Now") { model.syncNowAndRestartTimer() }
                .disabled(!model.isSyncConfigured || model.isSyncing)
        }
    }
}
