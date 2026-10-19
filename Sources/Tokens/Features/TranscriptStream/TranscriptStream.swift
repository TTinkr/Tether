


//
import AVFoundation
import AppKit
import Combine
import Speech
import SwiftUI


// latestMeasuredLines() — the last N wrapped lines of a text, measured at a width and font


/*
Returns the text from the start of its last `count` lines, as the system text layout would wrap
it at `width` with `font`. If the text is empty, the width or count is not positive, or it
already fits in `count` lines, the text comes back unchanged.
*/
func latestMeasuredLines(
    in text: String,
    font: NSFont,
    width: CGFloat,
    count: Int
) -> String {
    guard !text.isEmpty, width > 0, count > 0 else { return text }

    /*
    Lay the text out off screen with word wrapping and no side padding, in a container that is
    `width` wide and as tall as needed.
    */
    let storage = NSTextStorage(string: text, attributes: [.font: font])
    let layout  = NSLayoutManager()
    let container = NSTextContainer(
        size: NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
    )
    container.lineFragmentPadding = 0
    container.lineBreakMode       = .byWordWrapping
    layout.addTextContainer(container)
    storage.addLayoutManager(layout)
    layout.ensureLayout(for: container)

    // Walk the laid-out lines and note the character position where each one starts.
    var lineStarts: [Int] = []
    var glyphIndex        = 0
    while glyphIndex < layout.numberOfGlyphs {
        var glyphRange = NSRange()
        layout.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: &glyphRange)
        let characterRange = layout.characterRange(
            forGlyphRange: glyphRange,
            actualGlyphRange: nil
        )
        lineStarts.append(characterRange.location)
        glyphIndex = NSMaxRange(glyphRange)
    }

    guard lineStarts.count > count else { return text }
    return (text as NSString).substring(from: lineStarts[lineStarts.count - count])
}


// MainTranscriptStream — big two-lane live words: last three words, then flowing text


struct MainTranscriptStream: View {


    // State and the view


    let text: String
    let phase: TalkPhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /*
    `stream` decides how much of `text` is on screen (it reveals the words in small batches);
    caretVisible is flipped every half second while capturing to make the caret blink.
    */
    @StateObject private var stream = MainWordStreamState()
    @State private var caretVisible = true

    var body: some View {
        GeometryReader { proxy in
            /*
            Two equal lanes side by side. The 25 points taken off the width are the two 12-point gaps and
            the 0.8-point divider between the lanes (24.8, rounded up).
            */
            let laneWidth = max(1, (proxy.size.width - 25) / 2)
            let smoothTail = latestMeasuredLines(
                in: stream.visibleText,
                font: serifFont,
                width: laneWidth,
                count: 2
            )
            /*
            Left lane: just the last three words of the text, large, in red serif (clear while there
            is no text). Then a thin divider. Right lane: the revealed text cut to its last two
            lines, in italic, with the blinking caret on the end.
            */
            HStack(alignment: .top, spacing: 12) {
                Text(immediateTail)
                    .font(.system(size: 20, weight: .semibold, design: .serif))
                    .foregroundStyle(academicRed.opacity(text.isEmpty ? 0 : 0.82))
                    .lineLimit(2)
                    .frame(width: laneWidth, alignment: .topLeading)

                Rectangle()
                    .fill(academicPencil.opacity(0.10))
                    .frame(width: 0.8, height: 40)

                Text(writingText(smoothTail.isEmpty ? " " : smoothTail, caret: phase == .capturing && caretVisible))
                    .font(.system(size: 13.5, weight: .regular, design: .serif))
                    .italic()
                    .foregroundStyle(academicInk.opacity(text.isEmpty ? 0 : 0.76))
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .onReceive(Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()) { _ in
            if phase == .capturing { caretVisible.toggle() }
        }
        .onAppear {
            stream.ingest(text, phase: phase, reduceMotion: effectiveReduceMotion)
        }
        .onChange(of: text) { _, updated in
            stream.ingest(updated, phase: phase, reduceMotion: effectiveReduceMotion)
        }
        .onChange(of: phase) { _, updated in
            stream.ingest(text, phase: updated, reduceMotion: effectiveReduceMotion)
        }
        .onChange(of: effectiveReduceMotion) { _, _ in
            stream.ingest(text, phase: phase, reduceMotion: effectiveReduceMotion)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Live transcript")
        .accessibilityValue(text)
    }

//
// :)
//
//
    // Helpers — font, last three words, Reduce Motion


    private var serifFont: NSFont {
        let baseFont   = NSFont.systemFont(ofSize: 13.5, weight: .regular)
        let descriptor = baseFont.fontDescriptor.withDesign(.serif) ?? baseFont.fontDescriptor
        return NSFont(descriptor: descriptor, size: 13.5) ?? baseFont
    }

    private var immediateTail: String {
        let words = text.split(whereSeparator: { $0.isWhitespace })
        return words.suffix(3).joined(separator: " ")
    }

    /*
    Reduce Motion counts unless the TTTAnimateTranscript.v1 setting is on; the launch argument
    --reduced-motion-preview forces it on regardless.
    */
    private var effectiveReduceMotion: Bool {
        (reduceMotion && !UserDefaults.standard.bool(forKey: "TTTAnimateTranscript.v1")) ||
            ProcessInfo.processInfo.arguments.contains("--reduced-motion-preview")
    }


}


// TerminalStream — the live words as a two-line terminal: small line above, current below


struct TerminalStream: View {


    // State and the view


    let text: String
    let phase: TalkPhase
    let pauseRevision: Int
    var splitCompact = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var reveal = WordRevealState()
    /*
    pauseBreakOffsets: character positions in the text where a pause forced a new line (the last 8
    are kept). streamOpacity dips briefly when a correction is made. The retiring..., contextOpacity
    and mote values drive the small animation that plays when the upper line scrolls away (see retire).
    */
    @State private var pauseBreakOffsets: [Int] = []
    @State private var streamOpacity            = 1.0
    @State private var retiringText             = ""
    @State private var retiringOffset: CGFloat  = 0
    @State private var retiringOpacity          = 0.0
    @State private var contextOpacity           = 0.30
    @State private var binaryMote               = "0"
    @State private var moteOffset: CGFloat      = 0
    @State private var moteOpacity              = 0.0
    @State private var retirementCount          = 0

    var body: some View {
        GeometryReader { proxy in
            /*
            Redraws up to 60 times a second while a talk is capturing, and is paused at any other time.
            The caret flips about 2.6 times a second.
            */
            TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: phase != .capturing)) { timeline in
                let lines = terminalLines(
                    reveal.visibleText,
                    width: proxy.size.width,
                    forcedBreakOffsets: pauseBreakOffsets
                )
                let caret = phase == .capturing && Int(timeline.date.timeIntervalSinceReferenceDate * 2.63).isMultiple(of: 2)
                    ? "│" : " "
                ZStack(alignment: .leading) {
                    /*
                    Upper line: the previous line, tiny and faded. Lower line: the current line, in
                    italic. It is cut from the front (truncationMode .head) so the newest words stay
                    visible; when nothing has been heard yet it reads "listening…".
                    */
                    VStack(alignment: .leading, spacing: 2) {
                        Text(lines.previous.isEmpty ? " " : lines.previous)
                            .font(.system(size: splitCompact ? 6.3 : 7, weight: .regular, design: .serif))
                            .foregroundStyle(terminalInk)
                            .opacity(contextOpacity)
                            .lineLimit(1)
                        Text(writingText(
                            lines.current.isEmpty
                                ? (reveal.visibleText.isEmpty ? "listening…" : " ")
                                : lines.current, caret: caret == "│"
                        ))
                            .font(.system(
                                size: splitCompact ? 7.4 : 10.5,
                                weight: splitCompact ? .regular : .semibold,
                                design: .serif
                            ))
                            .italic()
                            .foregroundStyle(terminalInk.opacity(0.82))
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                    /*
                    The line that has just scrolled away: it drifts down 8 points and fades out (see
                    retire).
                    */
                    if !retiringText.isEmpty {
                        Text(retiringText)
                            .font(.system(size: splitCompact ? 6.3 : 7, weight: .regular, design: .serif))
                            .foregroundStyle(terminalInk)
                            .lineLimit(1)
                            .offset(y: retiringOffset)
                            .opacity(retiringOpacity)
                    }
                    /*
                    A tiny "0" or "1" at the right edge that drifts down and fades each time a line
                    retires.
                    */
                    Text(binaryMote)
                        .font(.system(size: 6.5, weight: .regular, design: .serif))
                        .foregroundStyle(terminalInk)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .offset(y: moteOffset)
                        .opacity(moteOpacity)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                .opacity(streamOpacity)
                /*
                When the upper line changes to something else, the old upper line retires with an
                animation.
                */
                .onChange(of: lines.previous) { oldValue, newValue in
                    guard !oldValue.isEmpty, oldValue != newValue else { return }
                    retire(oldValue)
                }
            }
        }
        .onAppear { reveal.ingest(text, phase: phase, reduceMotion: effectiveReduceMotion) }
        .onChange(of: text) { _, updated in
            reveal.ingest(updated, phase: phase, reduceMotion: effectiveReduceMotion)
        }
        /*
        Each time the pause counter goes up while capturing, the next words start a new line: the
        current text length is remembered as a forced break (skipped if it equals the last one; at most
        8 kept), the reveal buffer is flushed so the words up to the pause show at once, and a log line
        is written.
        */
        .onChange(of: pauseRevision) { oldValue, newValue in
            guard phase == .capturing, newValue > oldValue else { return }
            let offset = Array(text).count
            guard offset > 0, pauseBreakOffsets.last != offset else { return }
            pauseBreakOffsets.append(offset)
            if pauseBreakOffsets.count > 8 { pauseBreakOffsets.removeFirst() }
            reveal.flushBuffer(text, phase: phase, reduceMotion: effectiveReduceMotion)
            Diagnostics.event("display_pause_break offset=\(offset)")
        }
        // Forced breaks are cleared on every phase change, then the text is re-ingested for the new phase.
        .onChange(of: phase) { _, updated in
            if updated == .capturing {
                pauseBreakOffsets.removeAll(keepingCapacity: true)
            } else {
                pauseBreakOffsets.removeAll()
            }
            reveal.ingest(text, phase: updated, reduceMotion: effectiveReduceMotion)
        }
        /*
        The recogniser rewrote text that was already on screen: dip the whole stream to 48% and ease it
        back to full over 0.14 seconds.
        */
        .onChange(of: reveal.correctionRevision) { _, _ in
            streamOpacity = 0.48
            withAnimation(.easeOut(duration: 0.14)) { streamOpacity = 1 }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(phase == .delivered ? "\(appName) text delivered" : "\(appName) live transcript")
        .accessibilityValue(text)
    }

//
// :)
//
//
    // Helpers — line wrapping and the retiring-line animation


    private var terminalInk: Color {
        Color(nsColor: .labelColor)
    }

    private var effectiveReduceMotion: Bool {
        (reduceMotion && !UserDefaults.standard.bool(forKey: "TTTAnimateTranscript.v1")) ||
            ProcessInfo.processInfo.arguments.contains("--reduced-motion-preview")
    }

    /*
    Wraps the revealed text into lines and returns the last two as (previous, current). A line holds
    at most 5 words and must fit `width` in the stream's serif font. Each forced break position
    starts a new line. If the text ends right after a forced break and no word follows yet, an
    empty line is added, so the current line is blank until the next word arrives.
    */
    private func terminalLines(
        _ source: String,
        width: CGFloat,
        forcedBreakOffsets: [Int]
    ) -> (previous: String, current: String) {
        let characters = Array(source)
        guard !characters.isEmpty else { return ("", "") }
        let fontSize: CGFloat = splitCompact ? 7.4 : 10.5
        let fontWeight: NSFont.Weight = splitCompact ? .regular : .semibold
        let fallbackFont = NSFont.systemFont(ofSize: fontSize, weight: fontWeight)
        let serifDescriptor = fallbackFont.fontDescriptor.withDesign(.serif)
        let currentFont = serifDescriptor.flatMap { NSFont(descriptor: $0, size: fontSize) } ?? fallbackFont
        func measuredWidth(_ text: String, font: NSFont) -> CGFloat {
            (text as NSString).size(withAttributes: [.font: font]).width
        }
        var wrapped: [[String]] = []
        let breaks              = forcedBreakOffsets
            .filter { $0 > 0 && $0 <= characters.count }
            .sorted()
        let boundaries = [0] + Array(Set(breaks)).sorted() + [characters.count]
        for segmentIndex in 0..<(boundaries.count - 1) {
            let start          = boundaries[segmentIndex]
            let end            = boundaries[segmentIndex + 1]
            let segment        = start < end ? String(characters[start..<end]) : ""
            let words          = segment.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            var line: [String] = []
            for word in words {
                let candidate = (line + [word]).joined(separator: " ")
                if line.isEmpty || (line.count < 5 && measuredWidth(candidate, font: currentFont) <= width) {
                    line.append(word)
                } else {
                    wrapped.append(line)
                    line = [word]
                }
            }
            if !line.isEmpty { wrapped.append(line) }
            if segmentIndex > 0, words.isEmpty, end == characters.count { wrapped.append([]) }
        }

        let current  = wrapped.last?.joined(separator: " ") ?? ""
        let previous = wrapped.dropLast().last?.joined(separator: " ") ?? ""
        return (previous, current)
    }

    /*
    Plays when the upper line changes. Under Reduce Motion everything is simply reset. Otherwise
    the old line is placed at 18% opacity and drifts down 8 points while fading over 0.45 s, the
    faded upper line is hidden and then restored to 30%, and the "0"/"1" mote (alternating each
    time) starts at 24% opacity and fades out over 0.3 s.
    */
    private func retire(_ text: String) {
        guard !effectiveReduceMotion else {
            retiringText    = ""
            retiringOpacity = 0
            contextOpacity  = 0.30
            moteOpacity     = 0
            return
        }
        retirementCount &+= 1
        retiringText    = text
        retiringOffset  = 0
        retiringOpacity = 0.18
        contextOpacity  = 0
        binaryMote      = retirementCount.isMultiple(of: 2) ? "0" : "1"
        moteOffset      = 0
        moteOpacity     = 0.24
        withAnimation(.easeOut(duration: 0.45)) {
            retiringOffset  = 8
            retiringOpacity = 0
            contextOpacity  = 0.30
        }
        withAnimation(.easeOut(duration: 0.30)) {
            moteOffset  = 6
            moteOpacity = 0
        }
    }


}

//
// :)
//
//
// twoLineTail() — the end of a text that fits in two lines of a given width


/*
Measures with the 12.5-point semibold system font. The result starts at a whole word where it
can, so the shown tail never begins mid-word.
*/
func twoLineTail(_ text: String, width: CGFloat) -> String {
    let characters = Array(text)
    guard !characters.isEmpty, width > 1 else { return text }
    let font = NSFont.systemFont(ofSize: 12.5, weight: .semibold)
    let lineHeight = ceil(font.ascender - font.descender + font.leading + 1)
    let attributes: [NSAttributedString.Key: Any] = [.font: font]

    // True if the text from character `start` to the end needs at most two lines at this width.
    func fits(from start: Int) -> Bool {
        let candidate = String(characters[start...])
        let bounds = (candidate as NSString).boundingRect(
            with: NSSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: attributes
        )
        return bounds.height <= lineHeight * 2 + 0.5
    }

    /*
    If everything fits, return it all. Otherwise binary-search for the first start position from
    which the rest fits (shorter tails always fit better, so a search works), then skip any spaces
    at the cut.
    */
    guard !fits(from: 0) else { return text }
    var low  = 0
    var high = characters.count - 1
    while low < high {
        let middle = (low + high) / 2
        if fits(from: middle) { high = middle } else { low = middle + 1 }
    }
    while low < characters.count, characters[low].isWhitespace { low += 1 }
    /*
    If the cut landed in the middle of a word, move forward to the start of the next word, provided
    the text still fits from there.
    */
    if low > 0, low < characters.count,
       !characters[low].isWhitespace, !characters[low - 1].isWhitespace,
       let boundary = characters[low...].firstIndex(where: { $0.isWhitespace }) {
        var wordAligned = boundary
        while wordAligned < characters.count, characters[wordAligned].isWhitespace {
            wordAligned += 1
        }
        if wordAligned < characters.count, fits(from: wordAligned) {
            low = wordAligned
        }
    }
    return low < characters.count ? String(characters[low...]) : ""
}

