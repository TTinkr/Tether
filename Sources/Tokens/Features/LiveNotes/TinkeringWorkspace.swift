


//
import AppKit
import SwiftUI


// Constants — colours for the live-notes paper, ink, pencil, red and grid lines


// This file's own palette, separate from the academic* colours in Design/Paper.swift.
let tinkerPaper  = Color(red: 0.995, green: 0.992, blue: 0.982)
let tinkerInk    = Color(red: 0.09, green: 0.10, blue: 0.14)
let tinkerPencil = Color(red: 0.22, green: 0.23, blue: 0.28)
let tinkerRed    = Color(red: 0.72, green: 0.18, blue: 0.16)
let tinkerGrid   = Color(red: 0.42, green: 0.50, blue: 0.58)


// tinkerFont() — native system typography at a given size


func tinkerFont(_ size: CGFloat) -> Font { .system(size: size) }


// TinkeringWorkspaceView — Content-only tinkering workspace


/// Content-only tinkering workspace. The hosting window owns drag, minimize and resize grip.
struct TinkeringWorkspaceView: View {


    // State and layout


    /*
    transcript: the words so far. reflection: the model's notes text. countdown: seconds left before
    delivery, or nil. generationStatus and reflectionSource describe where the notes came from.
    recentResponses are the model's earlier answers, newest first.
    */
    let transcript: String
    let reflection: String
    let modelName: String
    let countdown: Int?
    let takeOffNow: () -> Void
    var generationStatus: String = ""
    var reflectionSource: String = ""
    var recentResponses: [TokenPauseAsides.WorkspaceSnapshot] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            /*
            During the send countdown: the cleaned-up transcript, then a "Refining…" line with a
            "Send now" button. Otherwise: the generated notes in a scroll view, a thin red rule, and
            the live transcript pinned below them (at most 160 points tall).
            */
            if countdown != nil {
                TinkeringTranscriptView(text: TinkeringDocument.cleanPreview(transcript))
                    .frame(minHeight: 40, maxHeight: .infinity)
                HStack(spacing: 8) {
                    Text("Refining…")
                        .font(tinkerFont(13))
                        .foregroundStyle(tinkerPencil)
                    Spacer(minLength: 4)
                    Button(action: takeOffNow) {
                        Text("Send now")
                            .font(tinkerFont(13))
                            .foregroundStyle(tinkerRed)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                            .frame(minWidth: 120, minHeight: 36)
                            .background(tinkerRed.opacity(0.10), in: Capsule())
                            .overlay(Capsule().stroke(tinkerRed.opacity(0.7), lineWidth: 1))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .focusable(false)
                }
            } else {
                ScrollView(.vertical) {
                    generatedContent
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(minHeight: 64, maxHeight: .infinity)
                Rectangle().fill(tinkerRed.opacity(0.35)).frame(height: 1)
                TinkeringTranscriptView(text: transcript)
                    .frame(minHeight: 64, maxHeight: 160)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(TinkeringGraphPaper())
    }

//
// :)
//
//
    // The generated notes — table, steps and earlier answers


    @ViewBuilder private var generatedContent: some View {
        /*
        The notes text is parsed into a document (title, rows, steps, question). Until the newest reply
        has any rows, the previous reply is shown instead, so the panel does not go blank between
        replies.
        */
        let source   = reflectionSource.isEmpty ? transcript : reflectionSource
        let current  = TinkeringDocument.parse(reflection, source: source)
        let previous = recentResponses.first.map { TinkeringDocument.parse($0.text, source: $0.source) }
        let document = current.rows.isEmpty ? (previous ?? current) : current
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Table").font(.system(size: 13, weight: .semibold)).foregroundStyle(tinkerRed)
                Spacer()
                Text(generationStatus.isEmpty ? "Waiting for words…" : generationStatus)
                    .font(.system(size: 11)).foregroundStyle(tinkerPencil)
            }
            if document.rows.isEmpty {
                HStack {
                    Text("Topic").foregroundStyle(tinkerRed)
                    Text(transcript.isEmpty ? "Listening for words…" : "Preparing the first table…")
                }.font(.system(size: 13)).padding(.vertical, 6)
            } else {
                if !document.title.isEmpty {
                    Text(verbatim: document.title).font(tinkerFont(20)).foregroundStyle(tinkerInk)
                }
                table(document.rows)
                if !document.steps.isEmpty { flow(document.steps) }
                if !document.question.isEmpty {
                    Text(verbatim: "? " + document.question).font(tinkerFont(18)).foregroundStyle(tinkerInk)
                }
            }
            // Footer naming the model that wrote this ("Qwen" is used when no name was given).
            Text(modelName.isEmpty ? "Qwen · generated" : "\(modelName) · generated")
                .font(.system(size: 10)).foregroundStyle(tinkerPencil)
            /*
            Up to three earlier replies that differ from the current one, each shown as plain rows
            under an "Earlier N" label, if they have rows.
            */
            ForEach(Array(recentResponses.filter { $0.text != reflection }.prefix(3).enumerated()), id: \.offset) { index, snapshot in
                let earlier = TinkeringDocument.parse(snapshot.text, source: snapshot.source)
                if !earlier.rows.isEmpty {
                    Divider()
                    Text("Earlier \(index + 1)").font(.system(size: 10)).foregroundStyle(tinkerPencil)
                    ForEach(Array(earlier.rows.enumerated()), id: \.offset) { _, row in
                        Text(verbatim: "\(row.emoji) \(row.label): \(row.value)")
                            .font(tinkerFont(13)).foregroundStyle(tinkerPencil)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    /*
    One grid row per item: emoji, red label, and the value in the pencil font, with a light divider
    between rows.
    */
    private func table(_ rows: [TinkeringDocument.Row]) -> some View {
        Grid(alignment: .topLeading, horizontalSpacing: 8, verticalSpacing: 4) {
            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                if index > 0 { Divider().overlay(tinkerGrid.opacity(0.5)) }
                GridRow {
                    Text(verbatim: row.emoji).font(.system(size: 13))
                    Text(verbatim: row.label)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(tinkerRed)
                    Text(verbatim: row.value)
                        .font(tinkerFont(18))
                        .foregroundStyle(tinkerInk)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

//
// :)
//
//
    // Steps drawn as small outlined boxes, one under another, joined by thin 10-point connector lines.
    private func flow(_ steps: [String]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                if index > 0 {
                    Rectangle().fill(tinkerPencil.opacity(0.55))
                        .frame(width: 1, height: 10)
                        .padding(.leading, 14)
                }
                Text(verbatim: step)
                    .font(tinkerFont(13))
                    .foregroundStyle(tinkerInk)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(tinkerPencil.opacity(0.55), lineWidth: 1))
            }
        }
    }


}


// TinkeringGraphPaper — faint graph-paper grid, 32 points apart, with no material layers


/// Faint graph-paper lines over the opaque tinkerPaper fill; no material layers.
struct TinkeringGraphPaper: View {
    var body: some View {
        /*
        The canvas first fills the whole area with tinkerPaper (so the background is the paper colour,
        not transparent), then draws grid lines every 32 points at a light tint. It lets clicks through.
        */
        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(tinkerPaper))
            var path             = Path()
            let spacing: CGFloat = 32
            for x in stride(from: spacing, to: size.width, by: spacing) {
                path.move(to: CGPoint(x: x, y: 0)); path.addLine(to: CGPoint(x: x, y: size.height))
            }
            for y in stride(from: spacing, to: size.height, by: spacing) {
                path.move(to: CGPoint(x: 0, y: y)); path.addLine(to: CGPoint(x: size.width, y: y))
            }
            context.stroke(path, with: .color(tinkerGrid.opacity(0.14)), lineWidth: 0.5)
        }
        .allowsHitTesting(false)
    }
}


// TinkeringTranscriptView — Live raw transcript pinned to the newest line


/*
A read-only, plain-text AppKit text view with an overlay scroller. Text uses a 21-point
system font on fixed 32-point lines; the view is not selectable.
*/
/// Live raw transcript pinned to the newest line. Keeps the whole string in textStorage and
/// only scrolls when the text actually changed, so manual scrollback survives redraws.
struct TinkeringTranscriptView: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView                   = NSTextView.scrollableTextView()
        scrollView.drawsBackground       = false
        scrollView.borderType            = .noBorder
        scrollView.hasVerticalScroller   = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers    = true
        scrollView.scrollerStyle         = .overlay
        if let textView = scrollView.documentView as? NSTextView {
            textView.isEditable         = false
            textView.isSelectable       = false
            textView.isRichText         = false
            textView.drawsBackground    = false
            textView.textContainerInset = NSSize(width: 0, height: 2)
            textView.textContainer?.lineFragmentPadding = 2
            textView.textContainer?.widthTracksTextView = true
            textView.isHorizontallyResizable = false
            textView.font = .systemFont(ofSize: 21)
            textView.textColor = NSColor(white: 0.10, alpha: 1)
            let paragraph = NSMutableParagraphStyle()
            paragraph.minimumLineHeight = 32
            paragraph.maximumLineHeight = 32
            textView.defaultParagraphStyle = paragraph
        }
        return scrollView
    }

//
// :)
//
//
    /*
    Only when the words changed: put them in, lay the text out so its end is known, and scroll to
    the end so the newest line is visible.
    */
    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView, textView.string != text else { return }
        textView.string = text
        if let container = textView.textContainer { textView.layoutManager?.ensureLayout(for: container) }
        textView.scrollToEndOfDocument(nil)
    }
}

