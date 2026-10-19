


//
import AppKit
import SwiftUI
import Testing
@testable import Tokens

@Suite(.serialized) @MainActor struct BubblePresetSurfaceTests {
    func buttons(_ view: NSView) -> [NSButton] {
        (view as? NSButton).map { [$0] } ?? view.subviews.flatMap(buttons)
    }
    @Test func actualSurfaceSeparatesActionsAtBothOrientations() async throws {
        for vertical in [false, true] {
            var finishes = 0, cancels = 0, moves = 0
            let size = vertical ? BubbleLayout.compactVerticalSize : panelDefaultSize
            let root = BubbleControlSurface(vertical: vertical, cancelLabel: "Cancel", finishLabel: "Finish",
                cancel: { cancels += 1 }, finish: { finishes += 1 }) {
                    Text("1.2s").font(.system(size: 10))
                }
            let host = NSHostingView(rootView: root.preferredColorScheme(.light))
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: .aqua)
            window.isReleasedWhenClosed = false
            window.contentView = host; host.frame = NSRect(origin: .zero, size: size)
            try await Task.sleep(nanoseconds: 100_000_000)
            host.layoutSubtreeIfNeeded()
            if let out = ProcessInfo.processInfo.environment["TOKENS_PRESET_RENDER_DIR"] {
                let url = URL(fileURLWithPath: out); try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                try #require(bitmap.representation(using: .png, properties: [:])).write(to: url.appendingPathComponent(vertical ? "bubble-vertical.png" : "bubble-horizontal.png"))
            }
            let controls = buttons(host)
            let move = try #require(controls.compactMap { $0 as? BubblePresetButton }.first)
            let domain = "bubble-surface-\(UUID())"
            let defaults = try #require(UserDefaults(suiteName: domain))
            defer { defaults.removePersistentDomain(forName: domain) }
            move.defaults = defaults; move.onPlacement = { _ in moves += 1 }
            for (id, expectedFinishes, expectedCancels) in [("xmark", 0, 1), ("checkmark", 1, 1)] {
                let button = try #require(controls.first { $0.identifier?.rawValue == id })
                let point = button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: host.superview)
                let hit = host.hitTest(point)
                #expect(hit === button)
                button.performClick(nil)
                #expect(finishes == expectedFinishes && cancels == expectedCancels && moves == 0)
            }
            let middle = move.convert(NSPoint(x: move.bounds.midX, y: move.bounds.midY), to: host.superview)
            #expect(host.hitTest(middle) === move)
            move.performClick(nil)
            #expect(moves == 1 && finishes == 1 && cancels == 1)
            #expect(BubblePlacement.loadPreset(from: defaults) == .left)
            let key = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: 0, context: nil, characters: " ", charactersIgnoringModifiers: " ", isARepeat: false, keyCode: 49))
            move.keyDown(with: key)
            #expect(moves == 2 && BubblePlacement.loadPreset(from: defaults) == .top)
            #expect(move.accessibilityPerformPress())
            #expect(moves == 3 && BubblePlacement.loadPreset(from: defaults) == .right)
            #expect(finishes == 1 && cancels == 1)
            #expect(!window.isVisible)
            window.close()
        }
    }
    @Test func disabledNativeActionsCannotFire() async throws {
        var actions = 0
        let root = BubbleControlSurface(vertical: false, cancelLabel: "Discard", finishLabel: "Paste now",
            cancel: { actions += 1 }, finish: { actions += 1 }, cancelEnabled: false, finishEnabled: false) {
                Text("Pasting…")
            }
        let host = NSHostingView(rootView: root)
        host.frame = NSRect(x: 0, y: 0, width: 272, height: 44)
        host.layoutSubtreeIfNeeded()
        let actionsButtons = buttons(host).filter { ["xmark", "checkmark"].contains($0.identifier?.rawValue ?? "") }
        #expect(actionsButtons.count == 2)
        for button in actionsButtons {
            #expect(!button.isEnabled)
            button.performClick(nil)
        }
        #expect(actions == 0)
    }

    /*
    V3 Settings rows (DESIGN.md §5.3) hosted offscreen: a row is one 56-point square, the bubble
    row with its 72 × 46 picker stays one square, and a note or a value that cannot fit beside
    the title takes exactly one more square.
    */
    @Test func settingsRowsAreWholeSquaresAndTheBubbleRowStaysOne() {
        func height<V: View>(_ view: V, width: CGFloat) -> CGFloat {
            let host = NSHostingView(rootView: view.frame(width: width).preferredColorScheme(.dark))
            host.frame = NSRect(x: 0, y: 0, width: width, height: 400)
            host.layoutSubtreeIfNeeded()
            return host.fittingSize.height
        }
        let cell = TokensUI.paperCell
        let bubble = TokensSettingsRow(title: "Bubble position", caption: "Where the bubble sits while you talk.",
                                       value: TokensBubblePickerGeometry.caption(.right)) {
            TokensBubblePlacementPicker(selection: .right) { _ in }
        }
        #expect(height(bubble, width: 616) == cell)
        // Too narrow for the value beside the title: the value moves to the next rule.
        #expect(height(bubble, width: 300) == 2 * cell)
        let plain = TokensSettingsRow(title: "Auto-send after pasting", caption: "Press Return after a confirmed paste.") {
            Toggle(isOn: .constant(false)) { EmptyView() }.toggleStyle(TokensSwitchStyle())
        }
        #expect(height(plain, width: 616) == cell)
        let note = TokensSettingsRow(title: "Open Tokens when your Mac starts", note: "Allow it in Login Items") {
            Toggle(isOn: .constant(true)) { EmptyView() }.toggleStyle(TokensSwitchStyle())
        }
        #expect(height(note, width: 616) == 2 * cell)
        // Flagged with no value: the caption becomes the note line; with a value, the dot joins it.
        let flagged = TokensSettingsRow(title: "Accessibility", caption: "Off, so the key does nothing yet.",
                                        flagged: true) { EmptyView() }
        #expect(height(flagged, width: 616) == 2 * cell)
        let inline = TokensSettingsRow(title: "Accessibility", caption: "Off, so the key does nothing yet.",
                                       flagged: true, value: "Off") {
            Button("Open Settings") {}.buttonStyle(TokensPrimaryButtonStyle())
        }
        #expect(height(inline, width: 616) == cell)
    }

    /*
    Settings ▸ Talk key exactly as settingsPage builds it, at every column width the shell
    produces (336 is 760 wide at 150%) and with each default key name. Build 63 drew "Dict…n key"
    beside Right Option at 336. The title must always draw at its full width. The row stays one
    square while the title, the 16-point gap and the chip with Change… fit; otherwise it takes a
    second rule (title alone, controls under it) rather than cut the title.
    */
    @Test func dictationKeyRowNeverCutsItsTitle() {
        func fitting<V: View>(_ view: V, width: CGFloat? = nil) -> CGSize {
            let framed = width.map { AnyView(view.frame(width: $0)) } ?? AnyView(view.fixedSize())
            let host = NSHostingView(rootView: framed.preferredColorScheme(.dark))
            host.frame = NSRect(x: 0, y: 0, width: width ?? 800, height: 400)
            host.layoutSubtreeIfNeeded()
            return host.fittingSize
        }
        func controls(_ name: String) -> some View {
            HStack(alignment: .center, spacing: 12) {
                TokensKeyChip(name: name, size: 14)
                Button("Change…") {}.buttonStyle(TokensQuietButtonStyle())
            }
        }
        let cell = TokensUI.paperCell
        let title = fitting(Text("Talk key").font(TokensType.body)).width
        var stacked = 0
        for name in ["Right Option", "Left Option", "Right Command", "Fn"] {
            let oneLine = title + 16 + fitting(controls(name)).width
            for width: CGFloat in [336, 392, 448, 560, 616] {
                var drawn: CGFloat = 0
                let row = TokensSettingsRow(title: "Talk key", caption: "Press once to talk, press again to paste.",
                                            onTitleLayout: { drawn = $0 }) {
                    controls(name)
                }
                let host = NSHostingView(rootView: row.frame(width: width).preferredColorScheme(.dark))
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 2 * cell),
                                      styleMask: [.borderless], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.contentView = host
                host.frame = NSRect(x: 0, y: 0, width: width, height: 2 * cell)
                host.layoutSubtreeIfNeeded()
                host.display()
                let label = "\(name) at \(width): title \(title), drawn \(drawn), one line needs \(oneLine)"
                #expect(drawn >= title - 0.5, "\(label)")
                let expected = oneLine <= width ? cell : 2 * cell
                if expected > cell { stacked += 1 }
                #expect(fitting(row, width: width).height == expected, "\(label)")
                window.close()
            }
        }
        // "Talk key" (build 80) fits beside every default key at the shell's widths; a column
        // narrower than any of them still exercises the second rule.
        if stacked == 0 {
            let narrow: CGFloat = 200
            let row = TokensSettingsRow(title: "Talk key", caption: "Press once to talk, press again to paste.") {
                controls("Right Command")
            }
            #expect(fitting(row, width: narrow).height == 2 * cell)
        }
    }

    /*
    Every other Settings row shape the page builds, at every column width the shell produces (336
    is 760 wide at 150%). The 16-point gap and the stacked arrangement reach all of them, not only
    the Talk key: a long microphone name, Open Login Items with its note, the update row,
    Accessibility recovery, the keep-mic status, Text size and the version line. Each row takes the
    first arrangement whose natural width fits (one line; the value under the title; the title
    alone, value and control on the next rule), so it never takes a third rule for these, and the
    title draws whole whenever any arrangement fits (otherwise it has its own rule to itself).
    */
    @Test func settingsRowsKeepTheirTitlesWholeAndTakeAtMostTwoRules() {
        func fitting<V: View>(_ view: V, width: CGFloat? = nil) -> CGSize {
            let framed = width.map { AnyView(view.frame(width: $0)) } ?? AnyView(view.fixedSize())
            let host = NSHostingView(rootView: framed.preferredColorScheme(.dark))
            host.frame = NSRect(x: 0, y: 0, width: width ?? 900, height: 400)
            host.layoutSubtreeIfNeeded()
            return host.fittingSize
        }
        // The row's 13-point status words (statusText), with the red dot when flagged.
        func status(_ text: String, dot: Bool) -> some View {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if dot { TokensStatusDot(color: TokensUI.red) }
                Text(text).font(TokensType.caption)
            }
        }
        func quiet(_ title: String) -> some View { Button(title) {}.buttonStyle(TokensQuietButtonStyle()) }
        func primary(_ title: String) -> some View { Button(title) {}.buttonStyle(TokensPrimaryButtonStyle()) }
        let toggle = Toggle(isOn: .constant(true)) { EmptyView() }.toggleStyle(TokensSwitchStyle())
        struct Shape {
            let name: String, title: String
            var flagged = false, value: String? = nil, note: String? = nil
            let control: AnyView?
        }
        let shapes: [Shape] = [
            Shape(name: "microphone", title: "MacBook Pro Microphone", value: "Input ready",
                  control: AnyView(quiet("Reconnect"))),
            Shape(name: "long microphone", title: "Elgato Wave:3 USB Condenser Microphone (Aggregate Device)",
                  flagged: true, value: "Reconnect needed", control: AnyView(quiet("Reconnect"))),
            Shape(name: "login approval", title: LoginItemRow.label, note: "Allow it in Login Items",
                  control: AnyView(HStack(alignment: .center, spacing: 12) { quiet("Open Login Items"); toggle })),
            Shape(name: "login outside Applications", title: LoginItemRow.label,
                  value: "Move to Applications to turn on", control: nil),
            Shape(name: "update offer", title: "Check for updates",
                  control: AnyView(HStack(alignment: .center, spacing: 12) { quiet("Later"); primary("Install") })),
            Shape(name: "update restart", title: "Waiting for Tokens to close · retry if needed",
                  control: AnyView(primary("Restart Tokens"))),
            Shape(name: "accessibility relaunch", title: "Accessibility", flagged: true, value: "Allowed, relaunch",
                  control: AnyView(primary("Relaunch"))),
            Shape(name: "accessibility off", title: "Accessibility", flagged: true, value: "Off",
                  control: AnyView(HStack(alignment: .center, spacing: 12) { quiet("Try again"); primary("Open Settings") })),
            Shape(name: "keep mic status", title: "Keep the mic on between talks", value: "Connecting microphone…",
                  control: AnyView(toggle)),
            Shape(name: "text size", title: "Text size", value: "⌘ or ⌃ with + −",
                  control: AnyView(TokensZoomStepper(zoom: 1.5, change: { _ in }))),
            Shape(name: "version", title: "Tokens 0.3.36 (64)", control: AnyView(quiet("Quit Tokens")))]
        let cell = TokensUI.paperCell
        var arrangements: Set<Int> = []
        for shape in shapes {
            let title = fitting(Text(shape.title).font(TokensType.body)).width
            let value = shape.value.map { fitting(status($0, dot: shape.flagged)).width }
            let control = shape.control.map { fitting($0).width }
            // Natural widths of the row's arrangements, in the order the row tries them.
            var candidates: [(ideal: CGFloat, rules: Int, id: Int)] = [
                (title + 16 + (value.map { $0 + (control == nil ? 0 : 12) } ?? 0) + (control ?? 0), 1, 1)]
            if let value { candidates.append((max(title + 16 + (control ?? 0), value), 2, 2)) }
            if let control { candidates.append((max(title, (value.map { $0 + 16 } ?? 0) + control), 2, 3)) }
            for width: CGFloat in [336, 392, 448, 560, 616] {
                var drawn: CGFloat = 0
                let report: (CGFloat) -> Void = { drawn = $0 }
                let row: AnyView = shape.control.map { control in
                    AnyView(TokensSettingsRow(title: shape.title, caption: "Hint.", flagged: shape.flagged, value: shape.value,
                                              note: shape.note, onTitleLayout: report) { control })
                } ?? AnyView(TokensSettingsRow(title: shape.title, caption: "Hint.", flagged: shape.flagged, value: shape.value,
                                               note: shape.note, onTitleLayout: report) { EmptyView() })
                let host = NSHostingView(rootView: row.frame(width: width).preferredColorScheme(.dark))
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 3 * cell),
                                      styleMask: [.borderless], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.contentView = host
                host.frame = NSRect(x: 0, y: 0, width: width, height: 3 * cell)
                host.layoutSubtreeIfNeeded()
                host.display()
                let fits = candidates.first { $0.ideal <= width }
                let chosen = fits ?? candidates[candidates.count - 1]
                arrangements.insert(chosen.id)
                let label = "\(shape.name) at \(width): title \(title), drawn \(drawn), arrangements \(candidates)"
                if fits != nil {
                    #expect(drawn >= title - 0.5, "\(label)")
                } else {
                    // Too long for any rule: it has its rule to itself, cut in the middle, and a
                    // cut title draws at most about one glyph narrower than the room it was given.
                    #expect(drawn >= min(title, width - (control == nil ? 16 : 0)) - 12, "\(label)")
                }
                let rules = chosen.rules + (shape.note == nil ? 0 : 1)
                #expect(fitting(row, width: width).height == CGFloat(rules) * cell, "\(label)")
                window.close()
            }
        }
        // All three arrangements are really exercised at the shell's widths.
        #expect(arrangements == [1, 2, 3])
    }

    @Test func materialRadiusFollowsPanelOrientation() {
        let material = NativeBubbleContainer(frame: NSRect(x: 0, y: 0, width: 272, height: 44))
        material.layout()
        #expect(material.layer?.cornerRadius == 22)
        material.frame = NSRect(x: 0, y: 0, width: 104, height: 148)
        material.layout()
        #expect(material.layer?.cornerRadius == 27)
    }

    @Test func renderActualBubbleStateMatrixOffscreen() async throws {
        guard let out = ProcessInfo.processInfo.environment["TOKENS_PRESET_RENDER_DIR"] else { return }
        let output = URL(fileURLWithPath: out)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for vertical in [false, true] {
            let size = vertical ? BubbleLayout.compactVerticalSize : panelDefaultSize
            let capture: (Bool, LiveThinkingPause?, String) -> AnyView = { confirmed, pause, destination in
                AnyView(BubbleControlSurface(vertical: vertical, cancelLabel: "Discard", finishLabel: "Finish", cancel: {}, finish: {}) {
                    TokensBubbleReadout(vertical: vertical, dev: false, shortcutName: "Right Option",
                        destinationLabel: destination, audioConfirmed: confirmed, pause: pause,
                        waveform: (0..<56).map { 0.45 + sin(Double($0) * 0.8) * 0.4 })
                })
            }
            let states: [(String, AnyView)] = [
                ("starting", capture(false, nil, "Choose a text field")),
                ("listening", capture(true, nil, "Safari · Message")),
                ("thinking", capture(true, LiveThinkingPause(seconds: 12.3456, estimated: false), "Cursor · Long project editor name")),
                ("finalizing", AnyView(BubbleFinalizingSurface(vertical: vertical, seconds: 2, launching: false, canTakeOffNow: true, cancel: {}, takeOffNow: {}))),
                ("pasting", AnyView(BubbleFinalizingSurface(vertical: vertical, seconds: 0, launching: true, canTakeOffNow: false, cancel: {}, takeOffNow: {}))),
                ("unavailable", AnyView(BubbleHeldWordsReadout(text: "A fictional transcript is saved safely for copying.", copied: false))),
                ("copied", AnyView(BubbleHeldWordsReadout(text: "A fictional transcript is saved safely for copying.", copied: true))),
                ("permission", AnyView(TinyStatusSurface(text: "Microphone access unavailable")))
            ]
            for (name, state) in states {
                let stateSize = ["unavailable", "copied", "permission"].contains(name)
                    ? (vertical ? BubbleLayout.recoveryVerticalSize : BubbleLayout.recoveryHorizontalSize) : size
                let host = NSHostingView(rootView: state.preferredColorScheme(.light))
                let window = NSWindow(contentRect: NSRect(origin: .zero, size: stateSize), styleMask: [.borderless], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.appearance = NSAppearance(named: .aqua)
                window.contentView = host
                host.frame = NSRect(origin: .zero, size: stateSize)
                try await Task.sleep(nanoseconds: 30_000_000)
                host.layoutSubtreeIfNeeded()
                let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                try #require(bitmap.representation(using: .png, properties: [:])).write(to:
                    output.appendingPathComponent("state-\(vertical ? "side" : "wide")-\(name).png"))
                #expect(!window.isVisible)
                window.close()
            }
        }
    }

    @Test func renderRegularControlsAndLivePencilOffscreen() async throws {
        guard let out = ProcessInfo.processInfo.environment["TOKENS_PRESET_RENDER_DIR"] else { return }
        let root = VStack(alignment: .leading, spacing: 24) {
            TokensBrandWordmark(width: 180)
            TokensParagraph("Settings and history", size: 24)
            TokensParagraph("Microphone permission and keyboard shortcut", lineLimit: 2)
            TokensButton("Open settings") {}
            TokensParagraph("Live words keep their pencil character.", lineLimit: 2, pencil: true)
        }.padding(32).frame(width: 480, height: 340).background(TokensUI.paper)
        let host = NSHostingView(rootView: root.preferredColorScheme(.light).foregroundStyle(TokensUI.ink))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 340),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        host.frame = NSRect(x: 0, y: 0, width: 480, height: 340)
        try await Task.sleep(nanoseconds: 100_000_000)
        host.layoutSubtreeIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try #require(bitmap.representation(using: .png, properties: [:])).write(to:
            URL(fileURLWithPath: out).appendingPathComponent("system-and-live-typography.png"))
        #expect(!window.isVisible)
        window.close()
    }

//
// :)
//
//
    @Test func nativeSystemMetricsMatchRegularTypesetterAndPencilStaysExplicit() throws {
        let regular = TokensUI.nsFont(15)
        #expect(regular.fontName == NSFont.systemFont(ofSize: 15).fontName)
        #expect(regular.pointSize == 15)
        let attributes = TokensTypesetter.attributes(size: 15, ink: .primary)
        #expect((attributes[.font] as? NSFont) == regular)
        #expect(attributes[.strokeWidth] as? Double == 0)
        #expect(TokensUI.nsFont(15, pencil: true).pointSize == 15 * TokensUI.textScale)
        let sample = "Microphone permission and keyboard shortcut"
        #expect(TokensUI.textWidth(sample, size: 15) == ceil((sample as NSString).size(withAttributes: [.font: regular]).width))
    }
}

