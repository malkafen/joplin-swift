import Foundation
import Testing
@testable import JoplinCore

@Suite struct ModelsTests {
    @Test func folderEmoji() {
        func folder(_ icon: String) -> Folder { Folder(row: Row(values: ["id": fixtureId(1), "icon": icon])) }
        #expect(folder(#"{"emoji":"📒","name":"","type":1}"#).emoji == "📒")
        #expect(folder("").emoji == nil)
        #expect(folder("not json").emoji == nil)
        #expect(folder(#"{"emoji":""}"#).emoji == nil)
        #expect(folder(#"["📒"]"#).emoji == nil)
    }

    @Test func resourceNaming() {
        func resource(_ values: [String: Any]) -> Resource { Resource(row: Row(values: values.merging(["id": fixtureId(7)]) { a, _ in a })) }
        let png = resource(["mime": "image/png", "file_extension": "png", "title": "Photo", "filename": "p.png", "size": Int64(10)])
        #expect(png.storageName == "\(fixtureId(7)).png")
        #expect(png.isImage)
        #expect(png.displayName == "Photo")
        #expect(png.size == 10)

        let bare = resource(["mime": "application/pdf", "filename": "doc.pdf"])
        #expect(bare.storageName == fixtureId(7))
        #expect(!bare.isImage)
        #expect(bare.displayName == "doc.pdf")
        #expect(resource([:]).displayName == fixtureId(7))
    }

    @Test func noteSummaryBuildsSnippet() {
        let summary = NoteSummary(row: Row(values: ["id": fixtureId(1), "title": "T", "is_todo": Int64(1), "snippet": "# Head\n\n**bold** text"]))
        #expect(summary.isTodo)
        #expect(summary.snippet == "Head bold text")
    }

    @Test(arguments: [
        ("# Title\nBody", "Title Body"),
        ("![img](:/abc) after", "after"),
        ("[link text](https://x.y)", "link text"),
        ("<b>html</b>", "html"),
        ("- [ ] todo\n- [x] done", "todo done"),
        ("* item\n+ other\n1. first", "item other first"),
        ("> quoted", "quoted"),
        ("`code` ~~gone~~ _it_", "code gone it"),
        ("   spaced\n\n\nlines   ", "spaced lines"),
    ])
    func snippet(markdown: String, expected: String) {
        #expect(Snippet.make(from: markdown) == expected)
    }

    @Test func enums() {
        #expect(NoteSort.allCases.map(\.rawValue) == ["updated", "created", "title"])
        #expect(NoteFilter.folder("a") != NoteFilter.tag("a"))
        #expect(ModelType.allCases.count == 8)
    }
}
