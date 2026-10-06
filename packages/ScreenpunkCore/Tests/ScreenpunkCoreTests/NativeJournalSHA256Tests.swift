import XCTest
@testable import ScreenpunkCore

final class NativeJournalSHA256Tests: XCTestCase {
    private func digest(_ bytes: Data, split: Int?) throws -> String {
        var hash = NativeJournalSHA256()
        if let split {
            try hash.update(bytes.prefix(split)); try hash.update(bytes.dropFirst(split))
        } else { try hash.update(bytes) }
        return hash.finalized().map { String(format: "%02x", $0) }.joined()
    }
    func testNISTKnownAnswersAndSplitUpdates() throws {
        let vectors: [(String, String)] = [
            ("", "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"),
            ("abc", "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"),
            ("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq", "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1"),
            ("abcdefghbcdefghicdefghijdefghijkefghijklfghijklmghijklmnhijklmnoijklmnopjklmnopqklmnopqrlmnopqrsmnopqrstnopqrstu", "cf5b16a778af8380036ce59e7b0492370b249b11e8f07a51afac45037afee9d1")]
        for (input, expected) in vectors {
            let bytes = Data(input.utf8)
            XCTAssertEqual(try digest(bytes, split: nil), expected)
            for split in 0...bytes.count { XCTAssertEqual(try digest(bytes, split: split), expected) }
        }
    }
    func testPaddingBoundaryKnownAnswers() throws {
        // Fixed hashlib/OpenSSL cross-checks, independent of the implementation.
        let vectors: [(Int, String)] = [
            (55, "9f4390f8d30c2dd92ec9f095b65e2b9ae9b0a925a5258e241c9f1e910f734318"),
            (56, "b35439a4ac6f0948b6d6f9e3c6af0f5f590ce20f1bde7090ef7970686ec6738a"),
            (63, "7d3e74a05d7db15bce4ad9ec0658ea98e3f06eeecf16b4c6fff2da457ddc2f34"),
            (64, "ffe054fe7ae0cb6dc65c3af9b61d5209f439851db43d0ba5997337df154668eb"),
            (65, "635361c48bb9eab14198e76ea8ab7f1a41685d6ad62aa9146d301d4f17eb0ae0")]
        for (length, expected) in vectors {
            let bytes = Data(repeating: 97, count: length)
            XCTAssertEqual(try digest(bytes, split: nil), expected)
            for split in 0...length { XCTAssertEqual(try digest(bytes, split: split), expected) }
        }
    }
}
