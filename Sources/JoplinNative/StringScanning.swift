import Foundation

final class TextBox {
    let string: String
    init(_ string: String) { self.string = string }
}

extension String {
    func isLiterally(_ other: String) -> Bool { (self as NSString).isEqual(to: other) }

    var quickLength: Int { utf8.withContiguousStorageIfAvailable(\.count) ?? (self as NSString).length }

    func quickContains(_ ascii: String) -> Bool {
        let needle = Array(ascii.utf8)
        return utf8.withContiguousStorageIfAvailable { memmem($0.baseAddress, $0.count, needle, needle.count) != nil }
            ?? ((self as NSString).range(of: ascii, options: .literal).location != NSNotFound)
    }

    func leadingParagraphs(limit: Int) -> String {
        guard quickLength > limit else { return self }
        if let head = utf8.withContiguousStorageIfAvailable({ bytes -> String in
            let end = limit
            var cut = end, line: Int?
            var i = end - 1
            while i > 0 {
                if bytes[i] == 10 {
                    if line == nil { line = i }
                    if bytes[i - 1] == 10 { cut = i - 1; break }
                }
                i -= 1
            }
            if i == 0 { cut = line ?? end }
            while cut > 0, cut < bytes.count, bytes[cut] & 0xC0 == 0x80 { cut -= 1 }
            return String(decoding: UnsafeBufferPointer(rebasing: bytes[0..<cut]), as: UTF8.self)
        }) {
            return head
        }
        let ns = self as NSString
        let cut = ns.range(of: "\n\n", options: .backwards, range: NSRange(location: 0, length: limit)).location
        return ns.substring(to: cut == NSNotFound ? ns.rangeOfComposedCharacterSequence(at: limit).location : cut)
    }
}
