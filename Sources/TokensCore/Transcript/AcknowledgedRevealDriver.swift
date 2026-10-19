import Foundation

/// A bounded transport adapter for TranscriptRevealPlan. All platform guards and
/// exact cumulative text/caret verification remain injected by the delivery owner.
/// This driver never posts while a previous write is awaiting acknowledgement.
public enum AcknowledgedRevealDriver {
    public struct Configuration: Sendable {
        public var sampleMicroseconds: UInt32 = 8_333
        /// The opening follows the same character frontier as the rest of the body.
        public var minimumBodyBatch = 1
        public var maximumBodyBatch = 96
        /// Some rich editors cannot acknowledge a caret after trailing whitespace.
        /// Carry it into the next write without altering authored bytes. Opt-in:
        /// this transport policy does not establish destination compatibility.
        public var deferTrailingWhitespace = false
        public init() {}
    }

    public enum PostResult: Equatable {
        /// The callback guarantees no event or write was issued.
        case refused(String)
        case posted
        /// A write may have happened. Treat as partial, never replay or submit.
        case uncertain(String)
    }

    public enum Outcome: Equatable {
        /// Every component, including final metadata, was individually verified.
        /// The caller still owes the final Auto-send lease check and send delay.
        case delivered(acknowledgedWrites: Int)
        case stopped(reason: String, postedWrites: Int, acknowledgedWrites: Int, acknowledgedPayload: String)
    }

    /// `guardFailure` must check cancellation plus the existing focus/window,
    /// caret, secure-input and clipboard ownership guards. `post` must repeat
    /// its atomic preflight before mutating. `acknowledge` receives the newly posted
    /// piece (not the cumulative payload). Its callback owns the prior target
    /// snapshot and blocks until that piece's insertion and resulting cumulative
    /// editor text/caret are verified, returning a reason otherwise;
    /// it must never infer acknowledgement from elapsed time. It owns updating the
    /// target snapshot used by the next guarded post. Neither callback may retry a
    /// possibly delivered piece. Returning nil from acknowledge is proof, not hope.
    public static func run(
        plan: TranscriptRevealPlan,
        acknowledgedPrefix: String = "",
        configuration: Configuration = Configuration(),
        guardFailure: () -> String?,
        post: (String) -> PostResult,
        acknowledge: (String) -> String?,
        now: () -> TimeInterval,
        wait: (UInt32) -> Void
    ) -> Outcome {
        var posted = 0, acknowledged = 0, committed = acknowledgedPrefix
        var deferred = ""
        var lastClock: TimeInterval?, lastPostTime: TimeInterval?
        func sampleTime() -> TimeInterval? {
            let value = now()
            guard value.isFinite, lastClock.map({ value >= $0 }) ?? true else { return nil }
            lastClock = value
            return value
        }
        func stop(_ reason: String) -> Outcome {
            .stopped(reason: reason, postedWrites: posted,
                     acknowledgedWrites: acknowledged, acknowledgedPayload: committed)
        }
        let payload = plan.completeText
        guard payload.utf8.starts(with: acknowledgedPrefix.utf8),
              String(payload.prefix(acknowledgedPrefix.count)).utf8.elementsEqual(acknowledgedPrefix.utf8)
        else { return stop("prefix_diverged") }
        guard configuration.sampleMicroseconds > 0, configuration.minimumBodyBatch > 0,
              configuration.maximumBodyBatch >= configuration.minimumBodyBatch
        else { return stop("invalid_reveal_configuration") }
        let markerCount = plan.marker.count, body = Array(plan.body)
        let prefixCount = acknowledgedPrefix.count
        var bodyCount = min(body.count, max(0, prefixCount - markerCount))
        guard plan.safeBodyCount(upTo: bodyCount) == bodyCount else { return stop("prefix_inside_protected_span") }
        guard prefixCount <= markerCount + body.count || acknowledgedPrefix.utf8.elementsEqual(payload.utf8)
        else { return stop("prefix_inside_metadata") }

        func write(_ incoming: String, final: Bool = false) -> String? {
            deferred += incoming
            let count = configuration.deferTrailingWhitespace && !final
                ? Self.postableCount(in: deferred, after: committed.count, plan: plan) : deferred.count
            guard count > 0 else { return guardFailure() }
            let piece = String(deferred.prefix(count))
            deferred = String(deferred.dropFirst(count))
            if let reason = guardFailure() { return reason }
            guard let postedAt = sampleTime() else { return "invalid_reveal_clock" }
            switch post(piece) {
            case .refused(let reason): return reason
            case .uncertain(let reason): posted += 1; return reason
            case .posted: posted += 1; lastPostTime = postedAt
            }
            if let reason = acknowledge(piece) { return reason }
            acknowledged += 1
            committed += piece
            return guardFailure()
        }

        if let reason = guardFailure() { return stop(reason) }
        if committed.utf8.elementsEqual(payload.utf8) { return .delivered(acknowledgedWrites: 0) }
        if prefixCount < markerCount {
            if let reason = write(String(plan.marker.dropFirst(prefixCount))) { return stop(reason) }
        }
        // Marker acknowledgement does not consume the body's visual budget.
        guard let started = sampleTime() else { return stop("invalid_reveal_clock") }
        while bodyCount < body.count {
            if let reason = guardFailure() { return stop(reason) }
            guard let current = sampleTime() else { return stop("invalid_reveal_clock") }
            let desired = plan.visibleBodyCount(at: current - started)
            // After a delayed ACK, a finished curve still does not authorize a
            // huge tail paste. Catch up using capped, separately verified writes.
            let cap = min(body.count, bodyCount + min(configuration.maximumBodyBatch, body.count - bodyCount))
            let end = min(desired, cap)
            let finalBody = end == body.count
            if end <= bodyCount || (!finalBody && end - bodyCount < configuration.minimumBodyBatch) {
                wait(configuration.sampleMicroseconds)
                continue
            }
            let piece = String(body[bodyCount..<end])
            if let reason = write(piece) { return stop(reason) }
            bodyCount = end
            // ACK latency already counts toward the minimum transport cadence.
            // Only wait the remaining interval; never add a cosmetic hold after
            // an editor has already taken longer than one sample to acknowledge.
            if bodyCount < body.count, let lastPostTime {
                guard let current = sampleTime() else { return stop("invalid_reveal_clock") }
                let remaining = Double(configuration.sampleMicroseconds) - (current - lastPostTime) * 1_000_000
                if remaining > 0 { wait(UInt32(min(Double(configuration.sampleMicroseconds), remaining.rounded(.up)))) }
            }
        }
        if let reason = write(plan.metadata, final: true) { return stop(reason) }
        return .delivered(acknowledgedWrites: acknowledged)
    }

    /// Main-actor delivery must use this suspending variant so ACK polling and
    /// visual pacing leave the event tap, cancellation and physical Return live.
    /// Same one-outstanding-write and failure semantics as run; async callbacks
    /// must suspend (e.g. Task.sleep), never block the actor with usleep.
    @MainActor
    public static func runAsync(
        plan: TranscriptRevealPlan,
        acknowledgedPrefix: String = "",
        configuration: Configuration = Configuration(),
        guardFailure: () -> String?,
        post: (String) -> PostResult,
        acknowledge: (String) async -> String?,
        now: () -> TimeInterval,
        wait: (UInt32) async -> Void
    ) async -> Outcome {
        func currentGuardFailure() -> String? {
            Task.isCancelled ? "cancelled" : guardFailure()
        }
        var posted = 0, acknowledged = 0, committed = acknowledgedPrefix
        var deferred = ""
        var lastClock: TimeInterval?, lastPostTime: TimeInterval?
        func sampleTime() -> TimeInterval? {
            let value = now()
            guard value.isFinite, lastClock.map({ value >= $0 }) ?? true else { return nil }
            lastClock = value
            return value
        }
        func stop(_ reason: String) -> Outcome {
            .stopped(reason: reason, postedWrites: posted,
                     acknowledgedWrites: acknowledged, acknowledgedPayload: committed)
        }
        let payload = plan.completeText
        guard payload.utf8.starts(with: acknowledgedPrefix.utf8),
              String(payload.prefix(acknowledgedPrefix.count)).utf8.elementsEqual(acknowledgedPrefix.utf8)
        else { return stop("prefix_diverged") }
        guard configuration.sampleMicroseconds > 0, configuration.minimumBodyBatch > 0,
              configuration.maximumBodyBatch >= configuration.minimumBodyBatch
        else { return stop("invalid_reveal_configuration") }
        let markerCount = plan.marker.count, body = Array(plan.body)
        let prefixCount = acknowledgedPrefix.count
        var bodyCount = min(body.count, max(0, prefixCount - markerCount))
        guard plan.safeBodyCount(upTo: bodyCount) == bodyCount else { return stop("prefix_inside_protected_span") }
        guard prefixCount <= markerCount + body.count || acknowledgedPrefix.utf8.elementsEqual(payload.utf8)
        else { return stop("prefix_inside_metadata") }

        func write(_ incoming: String, final: Bool = false) async -> String? {
            deferred += incoming
            let count = configuration.deferTrailingWhitespace && !final
                ? Self.postableCount(in: deferred, after: committed.count, plan: plan) : deferred.count
            guard count > 0 else { return currentGuardFailure() }
            let piece = String(deferred.prefix(count))
            deferred = String(deferred.dropFirst(count))
            if let reason = currentGuardFailure() { return reason }
            guard let postedAt = sampleTime() else { return "invalid_reveal_clock" }
            switch post(piece) {
            case .refused(let reason): return reason
            case .uncertain(let reason): posted += 1; return reason
            case .posted: posted += 1; lastPostTime = postedAt
            }
            if let reason = await acknowledge(piece) { return reason }
            acknowledged += 1
            committed += piece
            return currentGuardFailure()
        }

        if let reason = currentGuardFailure() { return stop(reason) }
        if committed.utf8.elementsEqual(payload.utf8) { return .delivered(acknowledgedWrites: 0) }
        if prefixCount < markerCount {
            if let reason = await write(String(plan.marker.dropFirst(prefixCount))) { return stop(reason) }
        }
        // Marker acknowledgement does not consume the body's visual budget.
        guard let started = sampleTime() else { return stop("invalid_reveal_clock") }
        while bodyCount < body.count {
            if let reason = currentGuardFailure() { return stop(reason) }
            guard let current = sampleTime() else { return stop("invalid_reveal_clock") }
            let desired = plan.visibleBodyCount(at: current - started)
            // After a delayed ACK, a finished curve still does not authorize a
            // huge tail paste. Catch up using capped, separately verified writes.
            let cap = min(body.count, bodyCount + min(configuration.maximumBodyBatch, body.count - bodyCount))
            let end = min(desired, cap)
            let finalBody = end == body.count
            if end <= bodyCount || (!finalBody && end - bodyCount < configuration.minimumBodyBatch) {
                await wait(configuration.sampleMicroseconds)
                continue
            }
            let piece = String(body[bodyCount..<end])
            if let reason = await write(piece) { return stop(reason) }
            bodyCount = end
            // ACK latency already counts toward the minimum transport cadence.
            // Only wait the remaining interval; never add a cosmetic hold after
            // an editor has already taken longer than one sample to acknowledge.
            if bodyCount < body.count, let lastPostTime {
                guard let current = sampleTime() else { return stop("invalid_reveal_clock") }
                let remaining = Double(configuration.sampleMicroseconds) - (current - lastPostTime) * 1_000_000
                if remaining > 0 { await wait(UInt32(min(Double(configuration.sampleMicroseconds), remaining.rounded(.up)))) }
            }
        }
        if let reason = await write(plan.metadata, final: true) { return stop(reason) }
        return .delivered(acknowledgedWrites: acknowledged)
    }

    /// Deferred whitespace remains byte-exact and joins the next acknowledged write.
    /// Counts and cuts are whole graphemes, including combined Unicode characters.
    private static func postableCount(in pending: String, after committedCount: Int,
                                      plan: TranscriptRevealPlan) -> Int {
        let characters = Array(pending)
        var count = characters.count
        let markerCount = plan.marker.count
        let bodyEnd = markerCount + plan.body.count
        while count > 0 {
            while count > 0, characters[count - 1].isWhitespace { count -= 1 }
            let absoluteEnd = committedCount + count
            guard absoluteEnd > markerCount, absoluteEnd <= bodyEnd else { break }
            let safeEnd = markerCount + plan.safeBodyCount(upTo: absoluteEnd - markerCount)
            let safeCount = max(0, safeEnd - committedCount)
            if safeCount == count { break }
            count = safeCount
        }
        return count
    }

}
