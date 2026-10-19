


//
import AVFoundation
import AppKit
import Combine
import Speech
import SwiftUI


// TinkeringDragHandle — an invisible grip that moves the whole window when dragged


struct TinkeringDragHandle: NSViewRepresentable {
    final class Handle: NSView {
        private var initialFrame = NSRect.zero
        private var initialPoint = NSPoint.zero
        // False: this view does the dragging itself, so the window background does not also move it.
        override var mouseDownCanMoveWindow: Bool { false }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        /*
        Pointer position taken from the event's global (Core Graphics) location with y negated to match
        AppKit's upward y; NSEvent.mouseLocation is only the fallback. See the note in
        TinkeringResizeHandle below for why.
        */
        private func pointer(_ event: NSEvent) -> NSPoint {
            if let point = event.cgEvent?.location { return NSPoint(x: point.x, y: -point.y) }
            return NSEvent.mouseLocation
        }
        override func mouseDown(with event: NSEvent) {
            guard let window else { return }
            initialFrame = window.frame; initialPoint = pointer(event)
        }
        /*
        New position = the position at mouse-down plus how far the pointer has moved, kept so the whole
        window stays inside its screen's visible area.
        */
        override func mouseDragged(with event: NSEvent) {
            guard let window else { return }
            let point = pointer(event)
            let screen = window.screen?.visibleFrame ?? initialFrame
            let x = min(max(initialFrame.minX + point.x - initialPoint.x, screen.minX), screen.maxX - initialFrame.width)
            let y = min(max(initialFrame.minY + point.y - initialPoint.y, screen.minY), screen.maxY - initialFrame.height)
            window.setFrameOrigin(NSPoint(x: x, y: y))
        }
        // Save the window position if the window has an autosave name.
        override func mouseUp(with event: NSEvent) {
            guard let window, !window.frameAutosaveName.isEmpty else { return }
            window.saveFrame(usingName: window.frameAutosaveName)
        }
    }
    func makeNSView(context: Context) -> Handle { Handle() }
    func updateNSView(_ view: Handle, context: Context) {}
}


// TinkeringResizeHandle — a grip that resizes the window from its bottom-right corner


struct TinkeringResizeHandle: NSViewRepresentable {
    final class Handle: NSView {
        private var initialFrame = NSRect.zero
        private var initialPoint = NSPoint.zero
        override var acceptsFirstResponder: Bool { false }
        override var mouseDownCanMoveWindow: Bool { false }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }
        /*
        Use event-global coordinates: background accessibility drags do not
        move NSEvent.mouseLocation. Negate CG's downward y for AppKit deltas.
        */
        private func pointer(for event: NSEvent) -> NSPoint {
            if let point = event.cgEvent?.location { return NSPoint(x: point.x, y: -point.y) }
            return NSEvent.mouseLocation
        }
        override func mouseDown(with event: NSEvent) {
            guard let window else { return }
            initialFrame = window.frame
            initialPoint = pointer(for: event)
        }
        /*
        Width and height follow the pointer but stay between the window's content minimum and the
        smaller of its content maximum and the room left on the screen. The top-left corner is
        fixed: AppKit's y points up, so the new origin.y is `maxY - height`.
        */
        override func mouseDragged(with event: NSEvent) {
            guard let window else { return }
            let point = pointer(for: event)
            let visible = window.screen?.visibleFrame ?? initialFrame
            let maximumWidth = max(window.contentMinSize.width, min(window.contentMaxSize.width, visible.maxX - initialFrame.minX))
            let maximumHeight = max(window.contentMinSize.height, min(window.contentMaxSize.height, initialFrame.maxY - visible.minY))
            let width = min(maximumWidth, max(window.contentMinSize.width, initialFrame.width + point.x - initialPoint.x))
            let height = min(maximumHeight, max(window.contentMinSize.height, initialFrame.height - point.y + initialPoint.y))
            window.setFrame(NSRect(x: initialFrame.minX, y: initialFrame.maxY - height, width: width, height: height), display: true)
        }
        /*
        Saves the frame under "TTTLiveTinkering.v1", the same name TalkModel uses to restore the notes
        panel.
        */
        override func mouseUp(with event: NSEvent) { window?.saveFrame(usingName: "TTTLiveTinkering.v1") }
    }

//
// :)
//
//
    func makeNSView(context: Context) -> Handle { Handle() }
    func updateNSView(_ view: Handle, context: Context) {}
}


// AmbientChip — the small movable π chip that stands in for a hidden notes panel


struct AmbientChip: View {
    @ObservedObject var model: TalkModel
    @ObservedObject var audio: AudioCapture
    /*
    Left: three dots that act as a drag grip. Right: a π button with a dot that is green while the
    microphone is delivering samples and grey otherwise. Clicking the button restores the panel.
    TalkModel puts this view in its own small floating window.
    */
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "ellipsis").frame(width: 18, height: 32)
                .overlay(TinkeringDragHandle()).help("Drag π ttalking")
            Button(action: model.restoreTinkering) {
                HStack(spacing: 6) {
                    Text("π").font(.system(size: 25, design: .serif))
                    Circle().fill(audio.hasRecentHardwareSamples ? Color.green : Color.gray).frame(width: 7, height: 7)
                }.frame(width: 54, height: 32)
            }.buttonStyle(.plain).focusable(false)
                .accessibilityLabel("Restore π ttalking · " + model.ambientStatus)
        }.padding(4).background(.ultraThinMaterial, in: Capsule())
    }
}


// AmbientWorkspace — picks which reflection source feeds the notes panel


struct AmbientWorkspace: View {
    @ObservedObject var model: TalkModel
    @ObservedObject var audio: AudioCapture
    /*
    When the ambient listener owns the capture its own reflection is used; otherwise the one from
    the talk's pause asides.
    */
    var body: some View {
        AmbientWorkspaceContent(model: model, audio: audio,
            reflection: model.ambientOwnsCapture ? model.ambientReflection : model.pauseAsides)
    }
}


// AmbientWorkspaceContent — the notes panel: title row, workspace, and a status row


struct AmbientWorkspaceContent: View {
    @ObservedObject var model: TalkModel
    @ObservedObject var audio: AudioCapture
    @ObservedObject var reflection: TokenPauseAsides
    /*
    Top to bottom: a title row (it reads "Your words" during the send countdown, otherwise
    "π ttalking") that is also a drag grip; the workspace view; and, except during the countdown, a
    status row with the microphone dot, the status text, Pause or Resume listening, and Minimize.
    A resize grip sits in the bottom-right corner.
    */
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(model.finishCountdownSeconds == nil ? "π ttalking" : "Your words")
                    .font(.system(size: 17, weight: .semibold, design: .serif))
                Spacer()
                Text(reflection.modelDisplayName).font(.caption)
            }.padding(12).overlay(TinkeringDragHandle())
            TinkeringWorkspaceView(
                transcript: model.ambientOwnsCapture ? model.ambientTranscript : audio.transcript,
                reflection: reflection.currentText,
                modelName: reflection.modelDisplayName,
                countdown: model.finishCountdownSeconds, takeOffNow: model.takeOffNow,
                generationStatus: reflection.status, reflectionSource: reflection.workspaceSource,
                recentResponses: reflection.recentWorkspaceResponses)
            if model.finishCountdownSeconds == nil {
                HStack {
                    Circle().fill(audio.hasRecentHardwareSamples ? Color.green : Color.gray).frame(width: 7, height: 7)
                    Text(model.ambientStatus).font(.caption)
                    Spacer()
                    Button(model.ambientEnabled ? "Pause listening" : "Resume listening", action: model.toggleAmbientListening)
                        .buttonStyle(.plain).font(.caption).focusable(false)
                    Button("Minimize", action: model.hideTinkeringPanel).buttonStyle(.plain).font(.caption)
                }.padding(10)
            }
        }
        .background(Color(red: 0.995, green: 0.992, blue: 0.982), in: RoundedRectangle(cornerRadius: 20))
        .foregroundStyle(academicInk)
        .preferredColorScheme(.light)
        .overlay(alignment: .bottomTrailing) { TinkeringResizeHandle().frame(width: 20, height: 20) }
    }
}

//
// :)
//
//
// LiveTinkeringCard — a glass card version of the notes panel (not used)


/*
Nothing in the app creates a LiveTinkeringCard at the moment; AmbientWorkspaceContent is the
notes panel that is actually hosted.
*/
struct LiveTinkeringCard: View {
    @ObservedObject var reflection: TokenPauseAsides
    var hide: () -> Void = {}
    private var text: String { reflection.currentText.isEmpty ? "Listening for context…" : reflection.currentText }
    /// Display only: list markers are stripped and paragraphs renumbered; the
    /// delivered reflection text is untouched.
    private var paragraphs: [String] {
        text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: #"^(?:#{1,3}\s+|[-*•]\s+|\d+[.)]\s+)"#, with: "", options: .regularExpression) }
            .filter { !$0.isEmpty }.prefix(6).map { $0 }
    }
    /*
    A glass card: a drag-grip title row with a minimize button, the numbered notes in a scroll view,
    and a corner grip drawn as three diagonal lines. The background stacks a thin material, a faint
    white tint, the graph paper and a soft top sheen under a white rim.
    */
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 20, style: .continuous)
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                HStack {
                    Text("π ttalking").font(.system(size: 18, weight: .semibold, design: .serif))
                    Spacer()
                    Text(reflection.modelDisplayName).font(.system(size: 11))
                }
                .frame(height: 26).overlay(TinkeringDragHandle())
                .help("Drag to move this panel")
                // Outside the drag overlay so the click reaches the button.
                Button(action: hide) {
                    Image(systemName: "minus")
                        .font(.system(size: 11, weight: .bold))
                        .frame(width: 22, height: 22)
                        .background(Color.white.opacity(0.7), in: Circle())
                        .overlay(Circle().stroke(academicRed.opacity(0.35), lineWidth: 0.75))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .focusable(false)
                .help("Minimize to the movable π chip; listening continues")
                .accessibilityLabel("Minimize π ttalking")
            }.foregroundStyle(academicRed)
            ScrollView {
                // Paragraph spacing reads as a blank line between points.
                VStack(alignment: .leading, spacing: 20) {
                    ForEach(Array(paragraphs.enumerated()), id: \.offset) { index, paragraph in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            if paragraphs.count > 1 {
                                Text("\(index + 1).").fontWeight(.semibold).monospacedDigit()
                                    .foregroundStyle(academicRed.opacity(0.9))
                            }
                            Text(.init(paragraph))
                                .lineSpacing(5)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }.font(.system(size: 22)).foregroundStyle(academicPencil.opacity(0.92))
                    }
                }.padding(.trailing, 4)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
            HStack(alignment: .bottom) {
                Spacer()
                HStack(spacing: 5) {
                    Canvas { context, size in
                        for inset in [0.0, 5.0, 10.0] {
                            var line = Path()
                            line.move(to: CGPoint(x: inset, y: size.height))
                            line.addLine(to: CGPoint(x: size.width, y: inset))
                            context.stroke(line, with: .color(academicPencil.opacity(0.7)), lineWidth: 1.5)
                        }
                    }.frame(width: 15, height: 15)
                }
                .frame(width: 28, height: 26)
                .contentShape(Rectangle())
                .overlay(TinkeringResizeHandle())
                .help("Drag this corner to resize; this does not enter full screen")
                .accessibilityLabel("Drag to resize π ttalking")
            }
        }.padding(18)
         .frame(minWidth: 320, maxWidth: .infinity, minHeight: 190, maxHeight: .infinity, alignment: .topLeading)
         .background {
             ZStack {
                 shape.fill(.ultraThinMaterial).opacity(0.65)
                 shape.fill(Color.white.opacity(0.04))
                 AcademicGraphPaper(paperOpacity: 0)
                 // Gloss: a soft top sheen, fading before the text.
                 shape.fill(LinearGradient(stops: [.init(color: .white.opacity(0.14), location: 0),
                                                   .init(color: .white.opacity(0.04), location: 0.32),
                                                   .init(color: .clear, location: 0.6)],
                                           startPoint: .top, endPoint: .bottom))
             }
         }
         .overlay(shape.strokeBorder(LinearGradient(colors: [.white.opacity(0.95), .white.opacity(0.35)],
                                                    startPoint: .top, endPoint: .bottom), lineWidth: 1))
         .clipShape(shape)
         .preferredColorScheme(.light)
    }
}

