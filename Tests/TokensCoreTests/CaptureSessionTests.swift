


//
/*
CaptureSessionTests — delayed callbacks and cancellation
Owns: deterministic checks for overlapping recording generations.
Never: use a microphone or infer native delivery from these unit tests.
*/


import XCTest
@testable import TokensCore

final class CaptureSessionTests: XCTestCase {
    func testStaleStartAndStopCallbacksCannotAffectNewGeneration() {
        var session = CaptureSession()
        let first   = try! XCTUnwrap(session.begin())

        XCTAssertNil(session.begin())
        XCTAssertEqual(session.beginFinishing(), first)
        XCTAssertFalse(session.advance(first, from: .awaitingAccess, to: .starting))
        XCTAssertNil(session.beginFinishing())
        XCTAssertTrue(session.end(first))
        XCTAssertFalse(session.end(first))

        let second = try! XCTUnwrap(session.begin())
        XCTAssertFalse(session.advance(first, from: .awaitingAccess, to: .starting))
        XCTAssertFalse(session.end(first))
        XCTAssertTrue(session.advance(second, from: .awaitingAccess, to: .starting))
        XCTAssertEqual(session.id, second)
        XCTAssertEqual(session.phase, .starting)
    }

    func testCancelInvalidatesCallbacksAndAllowsFreshSession() {
        var session   = CaptureSession()
        let cancelled = try! XCTUnwrap(session.begin())
        XCTAssertTrue(session.advance(cancelled, from: .awaitingAccess, to: .starting))

        session.cancel()
        XCTAssertNil(session.id)
        XCTAssertNil(session.phase)
        XCTAssertFalse(session.advance(cancelled, from: .starting, to: .recording))
        XCTAssertFalse(session.end(cancelled))

        let fresh = try! XCTUnwrap(session.begin())
        XCTAssertTrue(session.advance(fresh, from: .awaitingAccess, to: .starting))
        XCTAssertTrue(session.advance(fresh, from: .starting, to: .recording))
        XCTAssertEqual(session.beginFinishing(), fresh)
        XCTAssertNil(session.begin())
        XCTAssertTrue(session.end(fresh))
        XCTAssertNil(session.id)
        XCTAssertNil(session.phase)
    }
}

