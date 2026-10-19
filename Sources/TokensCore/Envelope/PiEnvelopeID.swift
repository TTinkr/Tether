


//
import CryptoKit
import Foundation

/*
A local hash of words already pasted, so a pasted π talk can be matched back to its saved
history entry and to its TTH arms. It is not tracking: nothing is stored, sent or looked up,
and the hash cannot be reversed into words.
*/
public enum PiEnvelopeID {
    /// First 8 lowercase hex characters of SHA-256 over the lexical words and seconds (2 decimals).
    public static func id(spokenText: String, seconds: Double?) -> String {
        // Tag names such as <num> are notation, not words; the writer's count text never has them.
        let words = LexicalFidelity.words(in: PiMarkers.stripTags(spokenText)).joined(separator: " ")
        let time = seconds.map { String(format: "%.2f", $0) } ?? "-"
        let digest = SHA256.hash(data: Data((words + "\n" + time).utf8))
        return String(digest.map { String(format: "%02x", $0) }.joined().prefix(8))
    }

    /// The text an owner appends to the stats line as " · π-id a1b2c3d4".
    public static func token(_ id: String) -> String { "π-id " + id }
}

