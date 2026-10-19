


//
import Foundation
import Testing
@testable import Tokens

@Suite(.serialized) struct TinkeringDocumentTests {
    @Test static func run() {
        let source = "Choose the dataset. Train for 5 seconds. Compare the errors. Keep the transcript unchanged."
        let output = """
        TITLE: Compare dataset errors
        ROW: goal|Compare the errors|📊
        ROW: constraint|Train for 5 seconds|⏱️
        ROW: detail|Train for 50 seconds|🚀
        ROW: detail|secret medical device|🚀
        STEP: Compare the errors
        STEP: Choose the dataset
        QUESTION: Which dataset should we compare?
        """
        let parsed = TinkeringDocument.parse(output, source: source)
        precondition(parsed.rows.count == 2)
        precondition(parsed.steps == ["Choose the dataset", "Compare the errors"])
        precondition(!parsed.question.isEmpty)
        precondition(TinkeringDocument.parse("ROW: detail||📊", source: source).rows.isEmpty)
        precondition(TinkeringDocument.parse("QUESTION: Try 300 datasets?", source: source).question.isEmpty)
        precondition(TinkeringDocument.parse(output, source: "").rows.isEmpty)
        precondition(TinkeringDocument.cleanPreview("RILEY uses C++, at 5.2 seconds—okay.") == "RILEY uses C++, at 5.2 seconds okay.")
        precondition(TinkeringDocument.parse("ROW: goal|Compare the errors|📊\nROW: goal|Compare the errors|📊", source: source).rows.count == 1)

        /*
        Grounding must require a contiguous source quote. This regression
        reproduces the old substring match that accepted a quote inside a word.
        */
        let boundarySource = "Database is ready now."
        let boundaryLeak = TinkeringDocument.parse(
            "ROW: detail|base is ready|📊\nSTEP: base is ready",
            source: boundarySource)
        precondition(boundaryLeak.rows.isEmpty && boundaryLeak.steps.isEmpty,
                     "quote validation accepted a word-boundary substring")
        print("PASS Tinkering document: source quotes, invented values rejected, source order, blank input, numeric guard, lexical preview, deduplication")
    }
}

