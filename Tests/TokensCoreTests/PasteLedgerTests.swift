


//
import Foundation
import Testing
import TokensCore

private let claude = "com.anthropic.claudefordesktop"
private let codex = "com.openai.codex"

/// One synthetic line in the Diagnostics shape.
private func line(_ event: String, day: String = "2026-10-13", time: String = "10:00:00", pid: Int = 1, app: String = "com.tinkr.tokens.community.macos") -> String {
    "\(day)T\(time)Z app=\(app) pid=\(pid) \(event)"
}

private func build(_ lines: [String], today: String? = nil) -> PasteLedger {
    PasteLedgerBuilder.build(lines: lines, timeZone: TimeZone(identifier: "UTC")!, today: today)
}

private func app(_ ledger: PasteLedger, _ bundle: String) -> PasteLedgerCounts {
    ledger.apps.first { $0.bundle == bundle }?.counts ?? .init()
}

@Suite struct PasteLedgerTests {
    @Test func verifiedUnverifiedAndMissedLandUnderTheirApps() {
        let ledger = build([
            // Claude: verified single paste.
            line("capture_target bundle=\(claude) restored=false element=true range=true"),
            line("delivery_preflight bundle=\(claude) window=true focus=true selection=true value=true range=true"),
            line("paste_ack bundle=\(claude) readable=true changed_ms=40 probe=true verified=true staged=0 reason=verified"),
            line("paste_posted verified=true"),
            line("delivery_verified session=A return=true"),
            line("delivery_return_dispatched success=true automatic=true"),
            // Codex: unverified but the editor changed -> landed (2026-10-10 rule).
            line("capture_target bundle=\(codex) restored=false element=true range=false"),
            line("delivery_preflight bundle=\(codex) window=true focus=false selection=false value=false range=false"),
            line("paste_ack bundle=\(codex) readable=false changed_ms=120 probe=false verified=false staged=0"),
            line("clipboard_held_for_unacknowledged_paste"),
            line("paste_posted verified=false"),
            line("delivery_unverified session=B"),
            line("recovery_retained session=B"),
            // Claude: non-empty composer, editor never changed -> missed, then Copy from held words.
            line("capture_target bundle=\(claude) restored=false element=true range=true"),
            line("delivery_preflight bundle=\(claude) window=true focus=true selection=true value=true range=true"),
            line("paste_ack_rules rich=true verified=false prefix=true"),
            line("paste_ack_shape before_utf16=42 inserted_utf16=10 after_utf16=42 selection_start=42 selection_length=0 expected_caret=52 actual_caret=42 actual_selection_length=0"),
            line("paste_ack_diff kind=unchanged"),
            line("paste_ack bundle=\(claude) readable=true changed_ms=none probe=false verified=false staged=0 reason=text"),
            line("paste_posted verified=false"),
            line("delivery_unverified session=C"),
            line("recovery_retained session=C"),
            line("held_words_shown characters=10"),
            line("held_words_copied characters=10"),
            line("held_words_dismissed copied=true"),
        ])
        #expect(app(ledger, claude).landed == 1)
        #expect(app(ledger, claude).missed == 1)
        #expect(app(ledger, claude).unconfirmedIntoNonEmptyEditor == 1)
        #expect(app(ledger, claude).recoveredViaHeldWords == 1)
        #expect(app(ledger, codex).landedUnverified == 1)
        #expect(app(ledger, codex).missed == 0)
        #expect(ledger.overall.pastes == 3 && ledger.overall.landedTotal == 2)
        #expect(ledger.overall.held == 0, "recovery_retained after a delivery_* line is not a second outcome")
        #expect(ledger.failureReasons == [PasteLedgerReason(reason: "unverified_no_editor_change", count: 1)])
        #expect(ledger.apps.map(\.name).sorted() == ["Claude", "Codex"])
    }

    @Test func stagedRouteAndPartialFailures() {
        let ledger = build([
            line("delivery_preflight bundle=\(codex) window=true focus=true selection=true value=true range=true"),
            line("staging_gate bundle=\(codex) three_steps=true stageable=true"),
            line("staging_plan bundle=\(codex) eligible=true pieces=3 continuation=false"),
            line("three_step_paste acknowledged=3 planned=3"),
            line("paste_ack bundle=\(codex) readable=true changed_ms=10 probe=true verified=true staged=3 reason=verified"),
            line("delivery_verified session=S1 return=false"),
            line("delivery_preflight bundle=\(codex) window=true focus=true selection=true value=true range=true"),
            line("three_step_paste stopped=unacknowledged posted=1"),
            line("delivery_failed session=S2 reason=partial_unacknowledged"),
            line("recovery_retained session=S2"),
            line("delivery_preflight bundle=\(claude) window=true focus=false selection=true value=true range=true"),
            line("delivery_failed session=S3 reason=original_editor_changed"),
            line("staged_delivery_first_write verified=true elapsed_ms=80"),
            line("delivery_verified session=S4 return=false"),
        ])
        #expect(ledger.routes["staged"]?.landed == 2)
        #expect(ledger.routes["staged"]?.missed == 1)
        #expect(ledger.routes["single"]?.missed == 1)
        #expect(ledger.failureReasons.map(\.reason).sorted() == ["original_editor_changed", "partial_unacknowledged"])
        #expect(ledger.unclosedAttempts == 0)
    }

    @Test func holdsKeptInAppEmptyAndMidDelivery() {
        let ledger = build([
            line("capture_target_unavailable reason=own_app_frontmost"),
            line("recovery_retained session=H1"),
            line("delivery_kept_in_app session=K1"),
            line("recovery_retained session=K1"),
            line("delivery_empty session=E1"),
            line("capture_target bundle=\(codex) restored=false element=true range=true"),
            line("recovery_retained session=M1"),
            line("delivery_preflight bundle=\(claude) window=true focus=true selection=true value=true range=true"),
            line("recovery_retained session=M2"),
            line("delivery_unverified session=U1"),
            line("delivery_held reason=focus_changed_since_key_edge"),
            line("auto_send_suppressed session=U1 reason=requires_review"),
        ])
        #expect(ledger.overall.held == 2)
        #expect(ledger.overall.keptInApp == 1)
        #expect(app(ledger, "none").held == 1)
        #expect(app(ledger, codex).held == 1)
        #expect(app(ledger, claude).missed == 1)
        #expect(app(ledger, codex).unchecked == 1, "unverified with no paste_ack is unchecked, not missed")
        #expect(app(ledger, codex).landRate == nil)
        let reasons = Dictionary(uniqueKeysWithValues: ledger.failureReasons.map { ($0.reason, $0.count) })
        #expect(reasons == ["held_no_target": 1, "held_before_paste": 1, "held_mid_delivery": 1])
    }

    /// TOK-QA-005: a Home Stop is kept in the app (Tokens in front) or held with no target; a Home
    /// Discard closes nothing and leaves no attempt open.
    @Test func homeStopIsKeptInAppOrHeldWithoutTarget() {
        let ledger = build([
            line("capture_target_unavailable reason=home_stop session=S1"),
            line("delivery_kept_in_app session=S1"),
            line("recovery_retained session=S1"),
            line("capture_target_unavailable reason=home_stop session=S2"),
            line("recovery_retained session=S2"),
            line("capture_discarded reason=home session=S3"),
        ])
        #expect(ledger.overall.keptInApp == 1)
        #expect(ledger.overall.held == 1)
        let reasons = Dictionary(uniqueKeysWithValues: ledger.failureReasons.map { ($0.reason, $0.count) })
        #expect(reasons == ["held_no_target": 1])
        #expect(ledger.unclosedAttempts == 0)
    }

    @Test func unknownLinesAreCountedNotDropped() {
        let ledger = build([
            "garbage that is not an event",
            "2026-10-13 10:00:00 app=x pid=1 paste_ack",
            "2026-10-13T10:00:00Z pid=1 app=x paste_ack",
            "2026-10-13T10:00:00Z app=x pid=1 Paste-Ack",
            "   ",
            line("updater_restart_retry"),
            line("shortcut_monitor_started listen_event=true"),
            line("paste_posted verified=true"),
        ])
        #expect(ledger.linesRead == 7)
        #expect(ledger.linesUnparsed == 4)
        #expect(ledger.otherEvents == 2)
        #expect(ledger.unclosedAttempts == 1)

        // A copied or edited log with CRLF endings: every line still counts, none are merged.
        let crlf = build([
            line("capture_target bundle=\(claude) restored=false element=true range=true") + "\r\n"
                + line("paste_ack bundle=\(claude) readable=true changed_ms=5 probe=true verified=true staged=0") + "\r\n"
                + "garbage\r\n"
                + line("delivery_verified session=C1") + "\r\n",
        ])
        #expect(crlf.linesRead == 4)
        #expect(crlf.linesUnparsed == 1)
        #expect(crlf.overall.landed == 1)
        #expect(crlf.unclosedAttempts == 0)
    }

    @Test func deliveryHeldKeepsItsReason() {
        let ledger = build([
            line("capture_target bundle=\(codex) restored=false element=true range=true"),
            line("delivery_held reason=focus_changed_since_key_edge"),
            line("recovery_retained session=D1"),
            line("capture_target bundle=\(claude) restored=false element=true range=true"),
            line("delivery_held reason=editing_thinking_notes"),
            line("recovery_retained session=D2"),
            // A stale delivery_held is cleared by the next key down.
            line("delivery_held reason=focus_changed_since_key_edge"),
            line("capture_target bundle=\(claude) restored=false element=true range=true"),
            line("recovery_retained session=D3"),
            // A non-code reason never reaches the ledger.
            line("capture_target bundle=\(claude) restored=false element=true range=true"),
            line("delivery_held reason=secret-word"),
            line("recovery_retained session=D4"),
        ])
        #expect(app(ledger, codex).held == 1)
        #expect(app(ledger, claude).held == 3)
        let reasons = Dictionary(uniqueKeysWithValues: ledger.failureReasons.map { ($0.reason, $0.count) })
        #expect(reasons == ["focus_changed_since_key_edge": 1, "editing_thinking_notes": 1,
                            "held_before_paste": 1, "held_other": 1])
    }

    @Test func olderBuildsWithoutADeliveryLineStillCount() {
        let ledger = build([
            // Older build: an unconfirmed paste whose Return was forwarded.
            line("capture_target bundle=\(claude) restored=false element=true range=true"),
            line("delivery_preflight bundle=\(claude) window=true focus=true selection=true value=true range=true"),
            line("paste_ack bundle=\(claude) readable=true changed_ms=80 probe=false verified=false staged=0"),
            line("delivery_return_dispatched success=true automatic=true"),
            line("agent_send_dispatched_unconfirmed session=O1"),
            // A talk that never logged its delivery line: closed from paste_ack at the next key down.
            line("capture_target bundle=\(codex) restored=false element=true range=false"),
            line("paste_ack bundle=\(codex) readable=true changed_ms=5 probe=true verified=true staged=0"),
            line("paste_posted verified=true"),
            line("capture_target bundle=\(codex) restored=false element=true range=false"),
            // Preflight only, then the next talk: nothing posted, counted unclosed.
            line("delivery_preflight bundle=\(codex) window=true focus=true selection=true value=true range=true"),
            line("capture_target_unavailable reason=own_app_frontmost"),
            line("recovery_retained session=none"),
        ])
        #expect(app(ledger, claude).landedUnverified == 1)
        #expect(app(ledger, codex).landed == 1)
        #expect(ledger.inferredFromAck == 1)
        #expect(ledger.unclosedAttempts == 1)
        #expect(app(ledger, "none").held == 1)
    }

    @Test func processesDoNotMix() {
        let ledger = build([
            line("delivery_preflight bundle=\(claude) window=true focus=true selection=true value=true range=true", pid: 1),
            line("delivery_preflight bundle=\(codex) window=true focus=true selection=true value=true range=true", pid: 2),
            line("paste_ack bundle=\(codex) readable=true changed_ms=none probe=false verified=false staged=0 reason=caret", pid: 2),
            line("paste_ack bundle=\(claude) readable=true changed_ms=5 probe=true verified=true staged=0 reason=verified", pid: 1),
            line("delivery_unverified session=P2", pid: 2),
            line("delivery_verified session=P1 return=false", pid: 1),
        ])
        #expect(app(ledger, claude).landed == 1)
        #expect(app(ledger, codex).missed == 1)
    }

    @Test func sevenDayTrendIsAnchoredAndComplete() {
        let ledger = build([
            line("delivery_verified session=a", day: "2026-10-01"),
            line("delivery_verified session=b", day: "2026-10-08"),
            line("delivery_failed session=c reason=x", day: "2026-10-10"),
            line("delivery_verified session=d", day: "2026-10-13", time: "23:59:59"),
        ], today: "2026-10-14")
        #expect(ledger.lastSevenDays.map(\.day) == ["2026-10-08", "2026-10-09", "2026-10-10", "2026-10-11", "2026-10-12", "2026-10-13", "2026-10-14"])
        #expect(ledger.lastSevenDays.reduce(0) { $0 + $1.counts.pastes } == 3)
        #expect(ledger.firstDay == "2026-10-01" && ledger.lastDay == "2026-10-13")
        let anchoredOnLog = build([line("delivery_verified session=z", day: "2026-10-13")])
        #expect(anchoredOnLog.lastSevenDays.last?.day == "2026-10-13" && anchoredOnLog.lastSevenDays.count == 7)
    }

    @Test func everyPasteEventIsRecognised() {
        let lines = PasteLedgerBuilder.pasteEvents.sorted().map { line("\($0) session=s bundle=\(codex)") }
        let ledger = build(lines)
        #expect(Set(ledger.pasteEventCounts.keys) == PasteLedgerBuilder.pasteEvents)
        #expect(ledger.otherEvents == 0 && ledger.linesUnparsed == 0)
    }

    @Test func freeTextFieldsNeverReachTheLedger() throws {
        let ledger = build([
            line("delivery_preflight bundle=\(claude) note=secretword window=true focus=true selection=true value=true range=true"),
            line("paste_ack bundle=\(claude) readable=true changed_ms=none probe=false verified=false staged=0 reason=text extra=secretword"),
            line("delivery_unverified session=secretsession"),
            line("free text secretword here"),
        ])
        let json = String(decoding: try JSONEncoder().encode(ledger), as: UTF8.self)
        #expect(!json.contains("secretword") && !json.contains("secretsession"))
        #expect(!ledger.markdown().contains("secretword"))
    }

    @Test func markdownShowsClaudeAndCodexSeparately() {
        let ledger = build([
            line("paste_ack bundle=\(claude) readable=true changed_ms=none probe=false verified=false staged=0 reason=text"),
            line("delivery_unverified session=1"),
            line("paste_ack bundle=\(codex) readable=false changed_ms=30 probe=false verified=false staged=0 reason=text"),
            line("delivery_unverified session=2"),
            line("paste_ack bundle=com.google.Chrome readable=true changed_ms=5 probe=true verified=true staged=0 reason=verified"),
            line("delivery_verified session=3 return=false"),
        ])
        let markdown = ledger.markdown()
        #expect(markdown.contains("| Claude | 1 | 0 | 0 | 1 | 0% | 0 |"))
        #expect(markdown.contains("| Codex | 1 | 0 | 1 | 0 | 100% | 0 |"))
        #expect(markdown.contains("| Chrome | 1 | 1 | 0 | 0 | 100% | 0 |"))
        #expect(markdown.contains("## Last 7 days"))
        #expect(markdown.contains("| 2026-10-13 | 0/1 | 1/1 | 1/1 |"))
        #expect(ledger.lastSevenDaysByGroup["Claude"]?.last?.counts.missed == 1)
    }
}

