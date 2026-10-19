import Foundation
import Testing

/*
The π the app draws must be the Tokens logo (LogoPi), never a typed π in some font (a pie symbol that differs
from the logo's would read as a different mark). This scans the app's
sources for a `Text("π")`. Older surfaces that public Tokens does not show are listed by file;
anything new fails here instead of shipping.
*/
struct BrandMarkSourceTests {
    static let legacy: Set<String> = [
        "Features/LiveNotes/LiveNotes.swift",
    ]

    @Test func noTypedPiOutsideLegacySurfaces() throws {
        let tokens = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Tokens")
        let files = FileManager.default.enumerator(at: tokens, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []
        #expect(!files.isEmpty)
        var offenders: [String] = []
        for file in files {
            let relative = file.path.replacingOccurrences(of: tokens.path + "/", with: "")
            guard !relative.hasPrefix("Unreached/"), !Self.legacy.contains(relative) else { continue }
            if try String(contentsOf: file, encoding: .utf8).contains("Text(\"π\")") { offenders.append(relative) }
        }
        #expect(offenders.isEmpty, "Draw LogoPi instead of a typed π in: \(offenders.joined(separator: ", "))")
    }
}
