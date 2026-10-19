import Foundation
import Testing
@testable import Tokens

struct CandidateCodingTests {
    @Test func legacySoundCategoryStillDecodes() throws {
        let legacy = Data(#""wispr""#.utf8)
        let decoded = try JSONDecoder().decode(Candidate.self, from: legacy)
        #expect(decoded == .whisper)
        #expect(String(data: try JSONEncoder().encode(decoded), encoding: .utf8) == #""whisper""#)
    }

    @Test func currentSoundCategoriesRoundTrip() throws {
        for candidate in Candidate.benchmarkClasses + [.silence, .texture] {
            let data = try JSONEncoder().encode(candidate)
            #expect(try JSONDecoder().decode(Candidate.self, from: data) == candidate)
        }
    }

    @Test func unknownCategoryIsRejected() {
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(Candidate.self, from: Data(#""unknown-sound""#.utf8))
        }
    }
}
