import Foundation
import Testing
@testable import JoplinCore

private let joplinNote = """
My note

First line
Second line with \\n literal

id: 0123456789abcdef0123456789abcdef
parent_id: fedcba9876543210fedcba9876543210
created_time: 2024-03-05T10:11:12.345Z
updated_time: 2024-03-05T10:11:13.000Z
is_conflict: 0
latitude: 0.00000000
longitude: 0.00000000
altitude: 0.0000
author:
source_url: https://example.com
is_todo: 1
todo_due: 0
todo_completed: 1709633472345
source: joplin-desktop
source_application: net.cozic.joplin-desktop
application_data:
order: 0
user_created_time: 2024-03-05T10:11:12.345Z
user_updated_time: 2024-03-05T10:11:13.000Z
encryption_cipher_text:
encryption_applied: 0
markup_language: 1
is_shared: 0
share_id:
conflict_original_id:
master_key_id:
user_data:
deleted_time: 0
some_future_field: ignored
type_: 1
"""

@Suite struct SerializerTests {
    @Test func unserializeJoplinNote() throws {
        let (type, fields) = try Serializer.unserialize(joplinNote)
        #expect(type == .note)
        #expect(fields["title"] as? String == "My note")
        #expect(fields["body"] as? String == "First line\nSecond line with \\n literal")
        #expect(fields["id"] as? String == "0123456789abcdef0123456789abcdef")
        #expect(fields["created_time"] as? Int64 == 1709633472345)
        #expect(fields["todo_completed"] as? Int64 == 1709633472345)
        #expect(fields["is_todo"] as? Int64 == 1)
        #expect(fields["latitude"] as? Double == 0)
        #expect(fields["source_url"] as? String == "https://example.com")
        #expect(fields["some_future_field"] == nil)
    }

    @Test func serializeRoundTrip() throws {
        let (type, fields) = try Serializer.unserialize(joplinNote)
        let text = try Serializer.serialize(type: type, fields: fields)
        #expect(text.hasPrefix("My note\n\nFirst line\n"))
        #expect(text.contains("created_time: 2024-03-05T10:11:12.345Z"))
        #expect(text.contains("latitude: 0.00000000"))
        #expect(text.contains("altitude: 0.0000"))
        #expect(text.hasSuffix("type_: 1"))
        let (_, again) = try Serializer.unserialize(text)
        #expect(again["body"] as? String == fields["body"] as? String)
        #expect(again["user_updated_time"] as? Int64 == fields["user_updated_time"] as? Int64)
    }

    @Test func serializesEveryPropertyInSchemaOrder() throws {
        for type in ModelType.syncable {
            let text = try Serializer.serialize(type: type, fields: ["id": fixtureId(1), "title": "T"])
            let keys = text.components(separatedBy: "\n").compactMap { line -> String? in
                guard let colon = line.firstIndex(of: ":") else { return nil }
                return String(line[..<colon])
            }
            let expected = Schema.fields[type]!.map(\.name).filter { $0 != "title" && $0 != "body" } + ["type_"]
            #expect(keys == expected, "\(type)")
        }
    }

    @Test func missingFieldsUseSchemaDefaults() throws {
        let text = try Serializer.serialize(type: .note, fields: ["id": fixtureId(1)])
        #expect(text.hasPrefix("\n\nid: "))
        #expect(text.contains("markup_language: 1"))
        #expect(text.contains("created_time: \n"))
        let resource = try Serializer.serialize(type: .resource, fields: ["id": fixtureId(2)])
        #expect(resource.contains("size: -1"))
    }

    @Test func escapingOfPropertyNewlines() throws {
        let text = try Serializer.serialize(type: .folder, fields: [
            "id": "0123456789abcdef0123456789abcdef", "title": "Folder", "user_data": "a\nb\\nc\rd\\re",
        ])
        #expect(text.contains("user_data: a\\nb\\\\nc\\rd\\\\re"))
        let (_, fields) = try Serializer.unserialize(text)
        #expect(fields["user_data"] as? String == "a\nb\\nc\rd\\re")
    }

    @Test func bodyIsNotEscaped() {
        #expect(Serializer.formatValue("body", "a\nb") == "a\nb")
        #expect(Serializer.formatValue("author", "a\nb") == "a\\nb")
    }

    @Test func emptyBodyNote() throws {
        let text = try Serializer.serialize(type: .note, fields: ["id": "0123456789abcdef0123456789abcdef", "title": "T", "body": ""])
        #expect(text.hasPrefix("T\n\nid: "))
        let (_, fields) = try Serializer.unserialize(text)
        #expect(fields["title"] as? String == "T")
        #expect(fields["body"] as? String == "")
    }

    @Test func nonNoteItemsHaveNoBody() throws {
        let text = "Tag title\n\nignored body\n\nid: \(fixtureId(3))\ntype_: 5"
        let (type, fields) = try Serializer.unserialize(text)
        #expect(type == .tag)
        #expect(fields["title"] as? String == "Tag title")
        #expect(fields["body"] == nil)
    }

    @Test func itemWithoutTitleSection() throws {
        let (type, fields) = try Serializer.unserialize("id: \(fixtureId(4))\ntype_: 2")
        #expect(type == .folder)
        #expect(fields["title"] == nil)
        #expect(fields["id"] as? String == fixtureId(4))
    }

    @Test func numericConversions() throws {
        let text = """
        N

        id: \(fixtureId(5))
        is_todo: 1.0
        order: abc
        latitude: 55.75583300
        longitude: not-a-number
        type_: 1
        """
        let (_, fields) = try Serializer.unserialize(text)
        #expect(fields["is_todo"] as? Int64 == 1)
        #expect(fields["order"] as? Int64 == 0)
        #expect(fields["latitude"] as? Double == 55.755833)
        #expect(fields["longitude"] as? Double == 0)
    }

    @Test func formatsValuesLikeJoplin() {
        #expect(Serializer.formatValue("latitude", 55.7558) == "55.75580000")
        #expect(Serializer.formatValue("longitude", -0.5) == "-0.50000000")
        #expect(Serializer.formatValue("altitude", 12.0) == "12.0000")
        #expect(Serializer.formatValue("order", 3.0) == "3")
        #expect(Serializer.formatValue("order", 3.25) == "3.25")
        #expect(Serializer.formatValue("is_todo", true) == "1")
        #expect(Serializer.formatValue("is_todo", false) == "0")
        #expect(Serializer.formatValue("author", nil) == "")
        #expect(Serializer.formatValue("author", NSNull()) == "")
        #expect(Serializer.formatValue("todo_due", Int64(42)) == "42")
        #expect(Serializer.formatValue("source_url", URL(string: "https://x.y")!) == "https://x.y")
    }

    @Test func formatsTimeFieldsFromAnyNumericType() {
        let iso = "2024-03-05T10:11:12.345Z"
        #expect(Serializer.formatValue("created_time", Int64(1709633472345)) == iso)
        #expect(Serializer.formatValue("created_time", 1709633472345) == iso)
        #expect(Serializer.formatValue("created_time", 1709633472345.0) == iso)
        #expect(Serializer.formatValue("created_time", "1709633472345") == iso)
        #expect(Serializer.formatValue("created_time", "garbage") == "")
        #expect(Serializer.formatValue("created_time", nil) == "")
    }

    @Test func timeParsing() {
        #expect(Serializer.formatTime(0) == "")
        #expect(Serializer.parseTime("") == 0)
        #expect(Serializer.parseTime("2024-03-05T10:11:12Z") == 1709633472000)
        #expect(Serializer.parseTime("2024-03-05T10:11:12.345Z") == 1709633472345)
        #expect(Serializer.parseTime("yesterday") == 0)
    }

    @Test func rejectsPathTraversal() {
        for ext in ["../x", "a/b", "a\\b", ".."] {
            #expect(throws: SerializerError.self) {
                try Serializer.unserialize("x\n\nid: \(fixtureId(1))\nfile_extension: \(ext)\ntype_: 4")
            }
        }
    }

    @Test func rejectsInvalidIds() {
        for id in ["../../etc", String(repeating: "z", count: 32), "abc"] {
            #expect(throws: SerializerError.self) { try Serializer.unserialize("x\n\nid: \(id)\ntype_: 4") }
        }
    }

    @Test func errors() throws {
        let invalid = #expect(throws: SerializerError.self) { try Serializer.unserialize("title\n\nnot a property") }
        #expect(invalid?.description == "Invalid property format: not a property")

        let missing = #expect(throws: SerializerError.self) { try Serializer.unserialize("title\n\nid: \(fixtureId(1))") }
        #expect(missing?.description == "Missing required property: type_")

        let nonNumeric = #expect(throws: SerializerError.self) { try Serializer.unserialize("type_: x") }
        #expect(nonNumeric?.description == "Missing required property: type_")

        let masterKey = #expect(throws: SerializerError.self) { try Serializer.unserialize("type_: 9") }
        #expect(masterKey?.description == "Unsupported item type: 9")

        let unknown = #expect(throws: SerializerError.self) { try Serializer.unserialize("type_: 99") }
        #expect(unknown?.description == "Unsupported item type: 99")

        let serialize = #expect(throws: SerializerError.self) { try Serializer.serialize(type: .setting, fields: [:]) }
        #expect(serialize?.description == "Unsupported item type: 3")

        let malformed = #expect(throws: SerializerError.self) { try Serializer.unserialize("x\n\nid: abc\ntype_: 4") }
        #expect(malformed?.description == "Malformed item: invalid id abc")
    }
}
