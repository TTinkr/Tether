import Testing
@testable import TokensCore

@Suite struct LegacyTranscriptAccumulatorTests {
    private func words(_ text: String, at start: Double) -> [TimedWord] {
        text.split(separator: " ").enumerated().map { index, word in
            TimedWord(text: String(word), start: start + Double(index) * 0.2,
                      end: start + Double(index) * 0.2 + 0.15, isFinal: false)
        }
    }

    @Test func pauseResumeKeepsEveryUtteranceAndEmptyFinalKeepsEverything() {
        var transcript = LegacyTranscriptAccumulator()
        for (start, phrase) in [(0.2, "The blue notebook."), (6.0, "Bring the reading lamp."), (12.0, "Right Option.")] {
            transcript.apply(phrase, isFinal: false, words: words(phrase, at: start))
        }
        #expect(transcript.snapshot.text == "The blue notebook. Bring the reading lamp. Right Option.")
        #expect(transcript.snapshot.stableWordCount == 0)
        transcript.apply("", isFinal: true, words: [])
        #expect(transcript.snapshot.text == "The blue notebook. Bring the reading lamp. Right Option.")
        #expect(transcript.snapshot.stableWordCount == 9)
        #expect(transcript.snapshot.timedWords.last?.start == 12.2)
    }

    @Test func revisionsAndCumulativeResultsDoNotDuplicateWords() {
        var transcript = LegacyTranscriptAccumulator()
        transcript.apply("The red", isFinal: false, words: words("The red", at: 0.2))
        transcript.apply("The blue notebook.", isFinal: false, words: words("The blue notebook.", at: 0.2))
        transcript.apply("Bring light", isFinal: false, words: words("Bring light", at: 6))
        transcript.apply("Bring the lamp.", isFinal: false, words: words("Bring the lamp.", at: 6))
        let all = "The blue notebook. Bring the lamp."
        transcript.apply(all, isFinal: true,
                         words: words("The blue notebook.", at: 0.2) + words("Bring the lamp.", at: 6))
        #expect(transcript.snapshot.text == all)
        #expect(transcript.snapshot.stableWordCount == 6)
    }

    @Test func repeatedPhraseAtDifferentAudioTimesStaysRepeated() {
        var transcript = LegacyTranscriptAccumulator()
        transcript.apply("Go again.", isFinal: false, words: words("Go again.", at: 0.2))
        transcript.apply("Go again.", isFinal: true, words: words("Go again.", at: 8))
        #expect(transcript.snapshot.text == "Go again. Go again.")
    }

    @Test func shorterOrUntimedRevisionIsNotGuessedToBeANewSentence() {
        var transcript = LegacyTranscriptAccumulator()
        transcript.apply("I thought there were five", isFinal: false, words: [])
        transcript.apply("There were four", isFinal: false, words: [])
        transcript.apply("", isFinal: false, words: [])
        #expect(transcript.snapshot.text == "There were four")
        #expect(transcript.snapshot.stableWordCount == 0)
        #expect(transcript.snapshot.timedWords.isEmpty)
    }

    @Test func nextSessionStartsEmpty() {
        var transcript = LegacyTranscriptAccumulator()
        transcript.apply("Old words", isFinal: true, words: words("Old words", at: 0.2))
        transcript = .init()
        transcript.apply("New words", isFinal: true, words: words("New words", at: 0.2))
        #expect(transcript.snapshot.text == "New words")
    }

    @Test func cumulativeFinalWithoutTimingDoesNotRepeatRetainedPrefix() {
        var transcript = LegacyTranscriptAccumulator()
        transcript.apply("First words", isFinal: false, words: words("First words", at: 0.2))
        transcript.apply("Last words", isFinal: false, words: words("Last words", at: 6))
        transcript.apply("First words Last words", isFinal: true, words: [])
        #expect(transcript.snapshot.text == "First words Last words")
    }

    @Test func lateEarlierRangeDoesNotEraseLaterUtterance() {
        var transcript = LegacyTranscriptAccumulator()
        transcript.apply("First words", isFinal: false, words: words("First words", at: 0.2))
        transcript.apply("Last words", isFinal: false, words: words("Last words", at: 6))
        transcript.apply("First words", isFinal: true, words: words("First words", at: 0.2))
        #expect(transcript.snapshot.text == "First words Last words")
    }

    @Test func timingGapDoesNotEraseRangeProvenanceBeforeLaterUtterance() {
        var transcript = LegacyTranscriptAccumulator()
        transcript.apply("First words", isFinal: false, words: words("First words", at: 0.2))
        transcript.apply("Middle words", isFinal: false, words: words("Middle words", at: 6))
        transcript.apply("First words Middle words", isFinal: false, words: [])
        transcript.apply("Last words", isFinal: true, words: words("Last words", at: 12))
        #expect(transcript.snapshot.text == "First words Middle words Last words")
        #expect(transcript.failure == nil)
    }

    @Test func finalizedUntimedWordsSurviveTheNextUtterance() {
        var transcript = LegacyTranscriptAccumulator()
        transcript.apply("Earlier sentence", isFinal: true, words: [])
        transcript.apply("Later sentence", isFinal: false, words: [], pauseRevision: 1)
        #expect(transcript.snapshot.text == "Earlier sentence Later sentence")
        #expect(transcript.failure == nil)
    }

    @Test func ambiguousUntimedPauseRetainsBothFragmentsInsteadOfOnlyLastSentence() {
        var transcript = LegacyTranscriptAccumulator()
        transcript.apply("Earlier sentence", isFinal: false, words: [])
        transcript.apply("Later sentence", isFinal: false, words: [], pauseRevision: 1)
        #expect(transcript.hasAmbiguousReset)
        #expect(transcript.snapshot.text.contains("Earlier sentence"))
        #expect(transcript.snapshot.text == "Earlier sentence Later sentence")
        #expect(transcript.snapshot.stableWordCount == 0)
        transcript.apply("", isFinal: true, words: [])
        #expect(transcript.snapshot.text.contains("Earlier sentence"))
    }

    @Test func firstPartialCanGainTimingAndCorrectBeforeAPause() {
        var transcript = LegacyTranscriptAccumulator()
        transcript.apply("The red", isFinal: false, words: [])
        transcript.apply("The blue notebook", isFinal: true, words: words("The blue notebook", at: 0.2))
        #expect(transcript.snapshot.text == "The blue notebook")
        #expect(transcript.failure == nil)
    }

    @Test func repeatedCallbackDuringSilenceDoesNotConsumePauseBoundary() {
        var transcript = LegacyTranscriptAccumulator()
        transcript.apply("Earlier sentence", isFinal: false, words: [])
        transcript.apply("Earlier sentence", isFinal: false, words: [], pauseRevision: 1)
        transcript.apply("Later sentence", isFinal: false, words: [], pauseRevision: 1)
        #expect(transcript.hasAmbiguousReset)
        #expect(transcript.snapshot.text.contains("Earlier sentence"))
        #expect(transcript.snapshot.text.contains("Later sentence"))
    }
    @Test func ambiguousResetKeepsEarlierWordsWhileLaterPartialsRevise() {
        var transcript = LegacyTranscriptAccumulator()
        transcript.apply("First sentence", isFinal: false, words: [])
        transcript.apply("Second", isFinal: false, words: [], pauseRevision: 1)
        transcript.apply("Second sentence", isFinal: false, words: [], pauseRevision: 1)
        transcript.apply("Second sentence corrected", isFinal: false, words: words("Second sentence corrected", at: 6), pauseRevision: 1)
        transcript.apply("Second sentence corrected", isFinal: false, words: [], pauseRevision: 2)
        transcript.apply("Third sentence", isFinal: false, words: [], pauseRevision: 2)
        transcript.apply("Third sentence finished", isFinal: true, words: [], pauseRevision: 2)
        #expect(transcript.snapshot.text == "First sentence Second sentence corrected Third sentence finished")
        #expect(transcript.hasAmbiguousReset)
        #expect(transcript.snapshot.stableWordCount == 0)
        #expect(transcript.failure == nil)
    }

    @Test func suffixRangeCannotEraseEarlierWordsInsideACumulativeResult() {
        var transcript = LegacyTranscriptAccumulator()
        transcript.apply("First sentence Last sentence", isFinal: false, words: words("First sentence Last sentence", at: 0.2))
        transcript.apply("Last corrected", isFinal: true, words: words("Last corrected", at: 0.6))
        #expect(transcript.snapshot.text == "First sentence Last sentence Last corrected")
        #expect(transcript.hasAmbiguousReset)
    }

    @Test func cumulativeTimingAfterAmbiguityCannotCollapsePreservedPrefix() {
        var transcript = LegacyTranscriptAccumulator()
        transcript.apply("Earlier words", isFinal: false, words: [])
        transcript.apply("Later words", isFinal: false, words: [], pauseRevision: 1)
        transcript.apply("Earlier words Later words", isFinal: false, words: words("Earlier words Later words", at: 0.2), pauseRevision: 1)
        transcript.apply("Later words corrected", isFinal: true, words: [], pauseRevision: 1)
        #expect(transcript.snapshot.text == "Earlier words Later words corrected")
        #expect(transcript.hasAmbiguousReset)
    }

    @Test func repeatedOpeningAtAnotherAmbiguousPauseIsPreserved() {
        var transcript = LegacyTranscriptAccumulator()
        transcript.apply("First thought", isFinal: false, words: [])
        transcript.apply("Go home", isFinal: false, words: [], pauseRevision: 1)
        transcript.apply("Go home again", isFinal: true, words: [], pauseRevision: 2)
        #expect(transcript.snapshot.text == "First thought Go home Go home again")
        #expect(transcript.hasAmbiguousReset)
    }

    @Test func ambiguousActiveWordsCanGainTimingBeforeADisjointResult() {
        var transcript = LegacyTranscriptAccumulator()
        transcript.apply("First", isFinal: false, words: [])
        transcript.apply("Second", isFinal: false, words: [], pauseRevision: 1)
        transcript.apply("Second", isFinal: false, words: words("Second", at: 6), pauseRevision: 1)
        transcript.apply("Third", isFinal: true, words: words("Third", at: 7), pauseRevision: 1)
        #expect(transcript.snapshot.text == "First Second Third")
        #expect(transcript.hasAmbiguousReset)
    }

    @Test func ambiguousCumulativeCorrectionRetainsActiveRangeForNextPhrase() {
        var transcript = LegacyTranscriptAccumulator()
        transcript.apply("First", isFinal: false, words: [])
        transcript.apply("Second", isFinal: false, words: [], pauseRevision: 1)
        transcript.apply("First Second corrected", isFinal: false,
            words: words("First", at: 0.2) + words("Second corrected", at: 6), pauseRevision: 1)
        transcript.apply("Third", isFinal: true, words: words("Third", at: 7), pauseRevision: 1)
        #expect(transcript.snapshot.text == "First Second corrected Third")
        #expect(transcript.hasAmbiguousReset)
    }

}
