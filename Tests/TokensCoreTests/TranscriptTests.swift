


//
import Testing
@testable import TokensCore


// TranscriptSnapshotTests — joining and counting words


@Suite struct TranscriptSnapshotTests {
    @Test func joinsSettledAndChangingWordsAndCountsOnlySettledOnes() {
        let changing = TranscriptSnapshot(finalizedText: "Words appear", volatileText: "instantly even when wrong")
        #expect(changing.text == "Words appear instantly even when wrong")
        #expect(changing.stableWordCount == 2)

        let settled = TranscriptSnapshot(finalizedText: "Words appear instantly even when corrected", volatileText: "")
        #expect(settled.stableWordCount == 6)
    }
}


// TranscriptAccumulatorTests — partials replace, finals stay


@Suite struct TranscriptAccumulatorTests {
    @Test func aPartialReplacesThePreviousPartialAndAFinalIsKept() {
        var transcript = TranscriptAccumulator()
        transcript.apply("hello", isFinal: false)
        #expect(transcript.snapshot == TranscriptSnapshot(finalizedText: "", volatileText: "hello"))
        transcript.apply("hello brave", isFinal: false)
        #expect(transcript.snapshot.text == "hello brave")
        transcript.apply("hello brave", isFinal: true)
        transcript.apply("world", isFinal: false)
        transcript.apply("world corrected", isFinal: false)
        transcript.apply("world corrected", isFinal: true)
        #expect(transcript.snapshot.text == "hello brave world corrected")
    }

    @Test func aRepeatedFinalPhraseIsKeptAsSpoken() {
        var transcript = TranscriptAccumulator()
        transcript.apply("world corrected", isFinal: true)
        transcript.apply("world corrected", isFinal: true)
        #expect(transcript.snapshot.text == "world corrected world corrected")
    }

    @Test func recognizerTimesFollowTheWordsOfTheFinalText() {
        // The recognizer punctuates and groups its timed runs differently from the text.
        var transcript = TranscriptAccumulator()
        transcript.apply("Okay, so it's 2.5. Then we email.", isFinal: true, words: [
            TimedWord(text: "Okay", start: 0, end: 0.3, isFinal: true), .untimed(",", isFinal: true),
            TimedWord(text: "so", start: 0.4, end: 0.5, isFinal: true),
            TimedWord(text: "it's", start: 0.6, end: 0.8, isFinal: true),
            TimedWord(text: "2", start: 0.9, end: 1.0, isFinal: true),
            TimedWord(text: ".5.", start: 1.0, end: 1.3, isFinal: true),
            TimedWord(text: "then", start: 3.1, end: 3.3, isFinal: true),
            TimedWord(text: "we", start: 3.4, end: 3.5, isFinal: true),
            TimedWord(text: "email", start: 3.6, end: 4.0, isFinal: true),
        ])
        let timed = transcript.snapshot.timedWords
        #expect(timed.map(\.text) == ["Okay,", "so", "it's", "2.5.", "Then", "we", "email."])
        #expect(timed[3].start == 0.9)
        #expect(timed[3].end == 1.3)
        let everyWordIsTimed = timed.allSatisfy { $0.hasTiming }
        #expect(everyWordIsTimed)
    }

    @Test func wordsWithoutRecognizerTimesStayUntimed() {
        var transcript = TranscriptAccumulator()
        transcript.apply("no times here", isFinal: true)
        #expect(transcript.snapshot.timedWords.isEmpty)
        #expect(transcript.snapshot.text == "no times here")
    }
}


// TimedWordAlignmentTests — times follow the words or are refused


@Suite struct TimedWordAlignmentTests {
    private func timed(_ text: String, starts: [Double], length: Double = 0.2) -> [TimedWord] {
        zip(text.split(separator: " "), starts).map {
            TimedWord(text: String($0), start: $1, end: $1 + length, isFinal: true)
        }
    }

//
// :)
//
//
    @Test func identicalWordsPassThroughUnchanged() {
        let words = timed("so it is", starts: [0, 1, 2])
        #expect(TimedWordAlignment.align(words: ["so", "it", "is"], to: words) == words)
    }

    @Test func differentCharactersAreNeverAligned() {
        // "it's" and "it is" are different letters, so the times cannot be trusted.
        #expect(TimedWordAlignment.align(words: ["so", "it", "is"], to: timed("so it's", starts: [0, 1])) == nil)
    }

    @Test func emptyInputHasNoAlignment() {
        #expect(TimedWordAlignment.align(words: [], to: timed("a", starts: [0])) == nil)
        #expect(TimedWordAlignment.align(words: ["a"], to: []) == nil)
    }

    @Test func aWordSplitAcrossRunsSpansAllOfThem() throws {
        let runs = [TimedWord(text: "2", start: 0.9, end: 1.0, isFinal: true),
                    TimedWord(text: ".5.", start: 1.0, end: 1.3, isFinal: true)]
        let aligned = try #require(TimedWordAlignment.align(words: ["2.5."], to: runs))
        #expect(aligned == [TimedWord(text: "2.5.", start: 0.9, end: 1.3, isFinal: true)])
    }
}

