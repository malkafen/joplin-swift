import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 340)
        } content: {
            NoteListView()
                .navigationSplitViewColumnWidth(min: 230, ideal: 290, max: 460)
        } detail: {
            NoteEditorView()
        }
        .alert(model.alert?.title ?? "", isPresented: isPresented(\.alert), presenting: model.alert) { _ in
            Button("OK") {}
        } message: { info in
            Text(info.message)
        }
        .alert(model.textPrompt?.title ?? "", isPresented: isPresented(\.textPrompt), presenting: model.textPrompt) { prompt in
            TextField(prompt.placeholder, text: $model.promptText)
            Button(prompt.confirmLabel) { prompt.action(model.promptText) }
                .keyboardShortcut(.defaultAction)
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog(model.confirmation?.title ?? "", isPresented: isPresented(\.confirmation),
                            presenting: model.confirmation) { c in
            Button(c.destructiveLabel, role: .destructive) { c.action() }
            Button("Cancel", role: .cancel) {}
        } message: { c in
            Text(c.message)
        }
    }

    private func isPresented<T>(_ keyPath: ReferenceWritableKeyPath<AppModel, T?>) -> Binding<Bool> {
        Binding(
            get: { model[keyPath: keyPath] != nil },
            set: { if !$0 { model[keyPath: keyPath] = nil } }
        )
    }
}
