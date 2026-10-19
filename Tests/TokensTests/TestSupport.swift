


//
import Testing

/// Shadows Swift's `precondition` inside the test target only.
///
/// The lifted tests were stand-alone programs that crashed on the first false check. Recording an
/// issue instead lets one run report every failing check with its file and line.
func precondition(_ condition: @autoclosure () throws -> Bool,
                  _ message: @autoclosure () -> String = "",
                  sourceLocation: SourceLocation = #_sourceLocation) rethrows {
    if try !condition() {
        let text = message()
        Issue.record(Comment(rawValue: text.isEmpty ? "check failed" : text), sourceLocation: sourceLocation)
    }
}

