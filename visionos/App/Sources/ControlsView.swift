import ARKit
import GameController
import SwiftUI
import TrevorbiltKit

// How to play, for each way of playing. A gamepad (DualSense-style or Xbox-style, as connected) or
// the Sense controllers, drawn as our own illustrations, with a callout on each button that does
// something: the controller's own symbol for it (GameController's, or the drawing's family's with
// nothing connected), what it does and its name in that family. Bare hands as our
// drawing (scripts/make-hand-art.py) with numbered markers and a legend. The launcher's Controls
// tab.
struct ControlsView: View {
    enum Input: String, CaseIterable, Identifiable {
        case hands = "Hands", sense = "Sense", gamepad = "Gamepad"
        var id: Self { self }
    }

    enum Context: String, CaseIterable, Identifiable {
        case onFoot = "On foot", driving = "Driving"
        var id: Self { self }
    }

    @State private var guide = ControlsGuide.shared

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                TrevorbiltHeading("how to ", bold: "play", size: 22)
                // What you hold, then on foot or driving, in one row.
                HStack(spacing: 8) {
                    ForEach(Input.allCases) { input in inputButton(input) }
                    Spacer().frame(width: 8)
                    ForEach(Context.allCases) { context in
                        TrevorbiltChip(context.rawValue, selected: guide.context == context) { guide.context = context }
                    }
                }
                page
            }
            .padding(24)
            .frame(maxWidth: .infinity)
        }
    }

    private func inputButton(_ input: Input) -> some View {
        let connected = switch input {
        case .hands: false
        case .sense: guide.senseConnected
        case .gamepad: guide.gamepadConnected
        }
        return Button { guide.input = input } label: {
            VStack(spacing: 3) {
                Group {
                    switch input {
                    case .hands: Image(systemName: "hand.raised.fill")
                    case .sense: HStack(spacing: 2) { Image(systemName: "l.joystick.fill"); Image(systemName: "r.joystick.fill") }
                    case .gamepad: Image(systemName: "gamecontroller.fill")
                    }
                }
                .symbolRenderingMode(.hierarchical)
                .font(.system(size: 20, weight: .medium))
                .frame(height: 24)
                .accessibilityHidden(true)
                Text(input.rawValue).font(.tbHeader(13, bold: true, relativeTo: .headline))
                Text(connected ? "Connected" : input == .hands ? "Full, Progressive" : "Not connected")
                    .font(.tbBody(11, weight: .medium, relativeTo: .caption2))
                    .foregroundStyle(.white.opacity(connected ? 1 : 0.8))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                    .padding(.horizontal, 4)
            }
            .padding(.vertical, 8)
            .frame(width: 104)
        }
        .buttonStyle(TrevorbiltTileButtonStyle(selected: guide.input == input))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(guide.input == input ? .isSelected : [])
    }

    private static let handsArt = ControllerArt(named: "hands-pair", bundle: .main)
    /// SHAR_TEST_HANDS=kit: the kit's hands, as another port would show them (each tinted a random
    /// skin tone), instead of SHAR's yellow ones. Simulator only.
    private static let kitHands = TestHooks.value("SHAR_TEST_HANDS") == "kit"

    @ViewBuilder private var page: some View {
        let window = guide.windowView && guide.input != .hands
        let items = items(guide.input, guide.context, window: window)
        switch guide.input {
        case .hands:
            // The drawing and, beside it, what every number on it does, all in view at once.
            HStack(alignment: .center, spacing: 14) {
                ControllerDiagram(art: Self.kitHands ? .hands : Self.handsArt, items: items, markerSize: 20)
                    .frame(minWidth: 0, maxWidth: .infinity)
                ControlsLegend(items: items)
                    .frame(width: 250)
            }
            .randomHandTones()
        case .gamepad:
            // (A gamepad's Attack, which no button does in Full and Progressive, is in the footnote.)
            ControllerCallouts(rig: padRig, controls: Self.gamepadControls.map { glyph($0, items: items, on: .gamepad, rig: padRig) })
        case .sense:
            ControllerCallouts(rig: .sensePair, controls: Self.senseControls.map { glyph($0, items: items, on: .sense, rig: .sensePair) })
                // What no button does (a swing to attack), in the room under the hands, so the page
                // is as tall on foot as driving and the note under it stays put.
                .overlay(alignment: .bottom) {
                    unplaced(items, on: Set(Self.senseControls)).padding(.bottom, 6).dynamicTypeSize(...DynamicTypeSize.xxLarge)
                }
                // Whether visionOS has its own model of the controllers: logged, for the headset.
                .task(id: guide.controllerChanges) { await loadSenseModels() }
        }
        footnote
    }

    private static let gamepadControls = ["leftTrigger", "leftShoulder", "rightShoulder", "rightTrigger", "dpad", "leftStick",
                                          "view", "menu", "y", "x", "b", "a", "rightStick"]
    private static let senseControls = ["leftTrigger", "leftShoulder", "leftStick", "y", "x", "view",
                                        "rightTrigger", "rightShoulder", "rightStick", "b", "a", "menu"]

    /// What no button on the map does (a swing of a hand), as a line under it.
    @ViewBuilder private func unplaced(_ items: [ControlItem], on controls: Set<String>) -> some View {
        let rest = items.filter { $0.anchor.map { !controls.contains($0) } ?? true }
        if !rest.isEmpty {
            HStack(spacing: 14) {
                ForEach(rest) { item in
                    HStack(spacing: 6) {
                        Image(systemName: item.anchor == "swing" ? "hand.wave.fill" : "info.circle")
                            .symbolRenderingMode(.hierarchical)
                            .accessibilityHidden(true)
                        Text("\(Text(item.action).bold()): \(item.how)")
                    }
                    .font(.tbBody(12, relativeTo: .caption))
                }
            }
        }
    }

    /// The gamepad drawing: the connected pad's kind (a DualSense or DualShock, or any other pad
    /// as the Xbox kind), or the DualSense kind with none connected.
    private var padRig: ControllerRig {
        _ = guide.controllerChanges
        // Headless Simulator runs: SHAR_TEST_PAD=none (or xbox) draws as if no pad (an Xbox-kind
        // pad) were connected, with the neutral symbols; the Simulator always has its own pad.
        if let test = TestHooks.value("SHAR_TEST_PAD") { return test == "xbox" ? .xbox : .dualSense }
        guard let pad = GCController.controllers().first(where: {
            $0.productCategory != GCProductCategorySpatialController && $0.extendedGamepad != nil
        })?.extendedGamepad else { return .dualSense }
        return pad is GCDualSenseGamepad || pad is GCDualShockGamepad ? .dualSense : .xbox
    }

    /// A control as the drawing shows it: the connected controller's own symbol for it (or the
    /// drawing's family's), what it does here, and its name in that family.
    private func glyph(_ control: String, items: [ControlItem], on input: Input, rig: ControllerRig) -> GlyphControl {
        var actions = items.filter { $0.anchor == control }.map(\.action)
        actions += items.compactMap { $0.also[control] }
        let connected = TestHooks.value("SHAR_TEST_PAD") == nil ? ControllerGlyph(anchor: control)?.symbol(on: input) : nil
        let symbol = connected ?? GlyphControl.neutralSymbol(control, for: rig)
        return GlyphControl(control, symbol: symbol, actions: actions, name: Self.controlName(control, rig: rig))
    }

    /// A control's name as its controller's family says it.
    private static func controlName(_ control: String, rig: ControllerRig) -> String {
        switch (rig, control) {
        case (_, "leftStick"): "Left stick"
        case (_, "rightStick"): "Right stick"
        case (_, "dpad"): "D-pad"
        case (.xbox, "a"): "A"
        case (.xbox, "b"): "B"
        case (.xbox, "x"): "X"
        case (.xbox, "y"): "Y"
        case (.xbox, "leftShoulder"): "LB"
        case (.xbox, "rightShoulder"): "RB"
        case (.xbox, "leftTrigger"): "LT"
        case (.xbox, "rightTrigger"): "RT"
        case (.xbox, "menu"): "Menu"
        case (.xbox, "view"): "View"
        case (_, "a"): "Cross"
        case (_, "b"): "Circle"
        case (_, "x"): "Square"
        case (_, "y"): "Triangle"
        case (.sensePair, "leftShoulder"): "L1 (grip)"
        case (.sensePair, "rightShoulder"): "R1 (grip)"
        case (.sensePair, "leftTrigger"): "L2 (trigger)"
        case (.sensePair, "rightTrigger"): "R2 (trigger)"
        case (_, "leftShoulder"): "L1"
        case (_, "rightShoulder"): "R1"
        case (_, "leftTrigger"): "L2"
        case (_, "rightTrigger"): "R2"
        case (_, "menu"): "Options"
        case (_, "view"): "Create"
        default: control
        }
    }

    /// Asks visionOS whether it has its own model of each connected Sense controller (ARKit's
    /// Accessory, at run time), and logs the answer. Not shown yet: the drawing explains the
    /// buttons; the headset's log says whether a model is there to use later.
    private func loadSenseModels() async {
        // Headless Simulator runs: every neutral symbol the drawings use must exist.
        if TestHooks.value("SHAR_TEST_TAB") != nil {
            let missing = GlyphControl.missingNeutralSymbols()
            NSLog("%@", "[SHARVR] controls symbols: \(missing.isEmpty ? "all present" : "missing \(missing.joined(separator: ", "))")")
        }
        // Headless Simulator runs: SHAR_TEST_ACCESSORY_PROBE=1 also asks for every other controller
        // (the Simulator has no Sense controllers), to see whether the request works from a window.
        if TestHooks.value("SHAR_TEST_ACCESSORY_PROBE") == "1" {
            for controller in GCController.controllers() where controller.productCategory != GCProductCategorySpatialController {
                do {
                    let accessory = try await Accessory(device: controller)
                    NSLog("%@", "[SHARVR] accessory probe: \(controller.vendorName ?? "?"): \(accessory.name), usdz \(accessory.usdzFile?.lastPathComponent ?? "none")")
                } catch {
                    NSLog("%@", "[SHARVR] accessory probe: \(controller.vendorName ?? "?"): \(error)")
                }
            }
        }
        let spatial = GCController.controllers().filter { $0.productCategory == GCProductCategorySpatialController }
        guard !spatial.isEmpty else {
            NSLog("%@", "[SHARVR] sense model: fallback (no Sense controller connected)")
            return
        }
        for controller in spatial {
            do {
                let accessory = try await Accessory(device: controller)
                guard !Task.isCancelled else { return }
                if let url = accessory.usdzFile {
                    NSLog("%@", "[SHARVR] sense model: system USDZ found for \(accessory.name) (\(accessory.inherentChirality)): \(url.path)")
                } else {
                    NSLog("%@", "[SHARVR] sense model: fallback (\(accessory.name) has no USDZ)")
                }
            } catch {
                guard !Task.isCancelled else { return }
                NSLog("%@", "[SHARVR] sense model: fallback (\(controller.vendorName ?? "a Sense controller"): \(error))")
            }
        }
    }

    // MARK: SHAR's controls

    private func items(_ input: Input, _ context: Context, window: Bool) -> [ControlItem] {
        func button(_ number: Int, _ action: String, _ how: String, _ anchor: String?, also: [String: String] = [:]) -> ControlItem {
            ControlItem(number, action, how, anchor: anchor, also: also)
        }
        // On the Sense controllers, the left one's Create button pauses too.
        func pause(_ number: Int) -> ControlItem {
            button(number, "Pause", input == .sense ? "Options, or Create on the left controller" : "Options / Menu", "menu",
                   also: input == .sense ? ["view": "Pause"] : [:])
        }
        func hand(_ number: Int, _ action: String, _ how: String, _ anchor: String, _ pose: String) -> ControlItem {
            Self.kitHands ? ControlItem(number, action, how, anchor: anchor, pose: .hand(HandPose(rawValue: pose)!))
                : ControlItem(number, action, how, anchor: anchor, image: Image(pose))
        }
        switch (input, context, window) {
        case (.hands, .onFoot, _):
            return [hand(1, "Walk", "Pinch and hold your left thumb and middle finger, then move your hand like a joystick. All the way to run.",
                         "leftMiddle", "hand-pinch-middle-left-move"),
                    hand(2, "Turn", "Pinch and hold your right thumb and little finger, then move your hand sideways. Or just turn your body.",
                         "rightLittle", "hand-pinch-little-right-turn"),
                    hand(3, "Act", "Pinch your right thumb and middle finger: talk, go through doors, get into a car.",
                         "rightMiddle", "hand-pinch-middle-right"),
                    hand(4, "Jump", "Pinch your right thumb and ring finger.", "rightRing", "hand-pinch-ring-right"),
                    hand(5, "Attack", "Swing your hand at it.", "rightPalm", "hand-swing-right"),
                    hand(6, "Pause", "Pinch your left thumb and little finger.", "leftLittle", "hand-pinch-little-left")]
        case (.hands, .driving, _):
            return [hand(1, "Steer", "Pinch and hold your left thumb and middle finger, then move your hand left and right.",
                         "leftMiddle", "hand-pinch-middle-left-steer"),
                    hand(2, "Gas", "Pinch and hold your right thumb and index finger.", "rightIndex", "hand-pinch-index-right"),
                    hand(3, "Brake and reverse", "Pinch and hold your left thumb and index finger.", "leftIndex", "hand-pinch-index-left"),
                    hand(4, "Handbrake", "Make a fist with your right hand, or pinch your right thumb and ring finger.",
                         "rightPalm", "hand-fist-right"),
                    hand(5, "Horn", "Tap your left thumb and middle finger together.", "leftMiddle", "hand-pinch-middle-left"),
                    hand(6, "Get out", "Pinch your left thumb and ring finger, or your right thumb and middle finger.",
                         "leftRing", "hand-pinch-ring-left")]
        case (_, .onFoot, false):
            return [button(1, "Move", "Left stick (click and hold to run)", "leftStick", also: ["leftStick": "Run (hold click)"]),
                    button(2, "Turn", "Right stick", "rightStick"),
                    button(3, "Act", "A / Cross or Y / Triangle: talk, go through doors, get into a car", "a", also: ["y": "Act"]),
                    button(4, "Jump", "B / Circle", "b"),
                    input == .sense ? button(5, "Attack", "Swing a Sense controller", "swing")
                                    : button(5, "Attack", "Swing a Sense controller (a gamepad can't; see below)", nil),
                    pause(6)]
        case (_, .driving, false):
            return [button(1, "Steer", "Left stick", "leftStick"),
                    button(2, "Gas", "Right trigger", "rightTrigger"),
                    button(3, "Brake and reverse", "Left trigger", "leftTrigger"),
                    button(4, "Handbrake", "B / Circle, or R1 / RB (the right grip)", "b", also: ["rightShoulder": "Handbrake"]),
                    button(5, "Horn", "X / Square, or click the left stick", "x", also: ["leftStick": "Horn (click)"]),
                    button(6, "Get out", "Y / Triangle or A / Cross", "y", also: ["a": "Get out"]),
                    pause(7)]
        case (_, .onFoot, true):
            return [button(1, "Move", "Left stick", "leftStick"),
                    button(2, "Camera", "Right stick", "rightStick"),
                    button(3, "Jump", "A / Cross", "a"),
                    button(4, "Sprint", "B / Circle", "b"),
                    button(5, "Attack", "X / Square", "x"),
                    button(6, "Act", "Y / Triangle: talk, go through doors, get into a car", "y"),
                    pause(7)]
        case (_, .driving, true):
            return [button(1, "Steer", "Left stick", "leftStick"),
                    button(2, "Gas", "Right trigger, or A / Cross", "rightTrigger", also: ["a": "Gas"]),
                    button(3, "Brake and reverse", "Left trigger, or B / Circle", "leftTrigger", also: ["b": "Brake, reverse"]),
                    button(4, "Handbrake", "R1 / RB (the right grip)", "rightShoulder"),
                    button(5, "Horn", "X / Square", "x"),
                    button(6, "Get out", "Y / Triangle", "y"),
                    pause(7)]
        }
    }

    private var footnote: some View {
        let window = guide.windowView && guide.input != .hands
        let text: String = switch (guide.input, guide.context, window) {
        case (.hands, .onFoot, _):
            "Hands play in Full and Progressive, when no controller is connected."
        case (.hands, .driving, _):
            "Rather steer with the wheel? Set Vehicle Control to VR Wheel in the game's VR menu, then put your hands on the wheel's rim and turn it. Your hands hold it without a fist, so the pinches for gas and brake still work."
        case (.sense, .onFoot, false):
            "In Full and Progressive. Act talks, opens doors and gets you into a car; the game's tutorials name the buttons on whatever you're holding."
        case (.sense, .driving, false):
            "You can also drive with the wheel: set Vehicle Control to VR Wheel in the game's VR menu, then hold the wheel with the grips and turn it."
        case (.gamepad, .onFoot, false):
            "In Full and Progressive. Act talks, opens doors and gets you into a car. A gamepad has no hand to swing: to attack with \(padRig == .xbox ? "X" : "Square"), set the VR menu's Mode to Original, the original game's buttons (the Window view's)."
        case (.gamepad, .driving, false):
            // VR Wheel steers only from the wheel's angle (HumanVehicleController::GetSteering), which
            // only hands or Sense controllers on its rim turn.
            "In Full and Progressive. Keep Vehicle Control on Stick in the game's VR menu: the VR Wheel turns only with hands or Sense controllers on its rim."
        case (.sense, _, true):
            "The Window view plays like the original game (Act: talk, doors, cars), and your Sense controllers act as one gamepad. Look at the window to give it your controller."
        case (.gamepad, _, true):
            "The Window view plays like the original game (Act: talk, doors, cars), and it needs a controller: visionOS gives apps no hand tracking outside Full and Progressive. Look at the window to give it your controller."
        }
        // Top-aligned, so the chips stay put when the note under a tap is a line longer.
        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: "info.circle.fill")
                .symbolRenderingMode(.hierarchical)
                .font(.system(size: 16))
                .foregroundStyle(.white.opacity(0.8))
                .accessibilityHidden(true)
            Text(text)
                .font(.tbBody(12, relativeTo: .caption))
                .foregroundStyle(.white.opacity(0.8))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            // Which View's buttons these are, the other a tap away. (Hands play only in Full and
            // Progressive.)
            if guide.input != .hands {
                HStack(spacing: 6) {
                    TrevorbiltChip("Full, Progressive", selected: !window) { guide.windowView = false }
                    TrevorbiltChip("Window", selected: window) { guide.windowView = true }
                }
                .fixedSize()
                // As the callouts: larger would leave the note no room.
                .dynamicTypeSize(...DynamicTypeSize.xxLarge)
            }
        }
        .padding(10)
        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

// What the guide shows (the launcher opens it on what's connected, for the View it will play), and
// which controllers are connected.
@Observable
final class ControlsGuide {
    static let shared = ControlsGuide()
    var input = ControlsView.Input.hands
    var context = ControlsView.Context.onFoot
    /// The Window view's buttons (the original game's) rather than Full and Progressive's.
    var windowView = false
    /// Counts controllers connecting and disconnecting; reading it redraws with the new symbols.
    private(set) var controllerChanges = 0

    var senseConnected: Bool {
        _ = controllerChanges
        return GCController.controllers().contains { $0.productCategory == GCProductCategorySpatialController }
    }

    var gamepadConnected: Bool {
        _ = controllerChanges
        return GCController.controllers().contains { $0.productCategory != GCProductCategorySpatialController && $0.extendedGamepad != nil }
    }

    private init() {
        for name in [Notification.Name.GCControllerDidConnect, .GCControllerDidDisconnect] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.controllerChanges += 1
            }
        }
    }
}

/// A button, as the connected controller draws it (GCControllerElement.sfSymbolsName). Sense
/// controllers name each half's elements alike, so X and Y are the left half's A and B.
enum ControllerGlyph {
    case a, b, x, y, menu, view, dpad, leftTrigger, rightTrigger, leftShoulder, rightShoulder, leftStick, rightStick

    /// The control a guide's map names.
    init?(anchor: String) {
        switch anchor {
        case "a": self = .a
        case "b": self = .b
        case "x": self = .x
        case "y": self = .y
        case "menu": self = .menu
        case "view": self = .view
        case "dpad": self = .dpad
        case "leftTrigger": self = .leftTrigger
        case "rightTrigger": self = .rightTrigger
        case "leftShoulder": self = .leftShoulder
        case "rightShoulder": self = .rightShoulder
        case "leftStick": self = .leftStick
        case "rightStick": self = .rightStick
        default: return nil
        }
    }

    /// The symbol on the connected controller of that kind, or nil with none connected.
    func symbol(on input: ControlsView.Input) -> String? {
        _ = ControlsGuide.shared.controllerChanges
        let controllers = GCController.controllers()
        switch input {
        case .hands:
            return nil
        case .sense:
            let spatial = controllers.filter { $0.productCategory == GCProductCategorySpatialController }
            let left = spatial.first { $0.vendorName?.hasSuffix("(L)") == true }
            let right = spatial.first { $0.vendorName?.hasSuffix("(R)") == true }
            func button(_ half: GCController?, _ names: String...) -> String? {
                names.lazy.compactMap { half?.physicalInputProfile.buttons[$0]?.sfSymbolsName }.first
            }
            func stick(_ half: GCController?) -> String? {
                half?.physicalInputProfile.dpads[__GCInputDirectionPadName.thumbstick.rawValue]?.sfSymbolsName
            }
            switch self {
            case .a: return button(right, GCInputButtonA)
            case .b: return button(right, GCInputButtonB)
            case .x: return button(left, GCInputButtonA)
            case .y: return button(left, GCInputButtonB)
            case .menu: return button(right, GCInputButtonMenu)
            case .view: return button(left, GCInputButtonShare, GCInputButtonOptions, GCInputButtonMenu)
            case .leftTrigger: return button(left, __GCInputButtonName.trigger.rawValue)
            case .rightTrigger: return button(right, __GCInputButtonName.trigger.rawValue)
            case .leftShoulder: return button(left, "Grip")
            case .rightShoulder: return button(right, "Grip")
            case .leftStick: return stick(left)
            case .rightStick: return stick(right)
            case .dpad: return nil
            }
        case .gamepad:
            guard let pad = controllers.first(where: {
                $0.productCategory != GCProductCategorySpatialController && $0.extendedGamepad != nil
            })?.extendedGamepad else { return nil }
            switch self {
            case .a: return pad.buttonA.sfSymbolsName
            case .b: return pad.buttonB.sfSymbolsName
            case .x: return pad.buttonX.sfSymbolsName
            case .y: return pad.buttonY.sfSymbolsName
            case .menu: return pad.buttonMenu.sfSymbolsName
            case .view: return pad.buttonOptions?.sfSymbolsName
            case .dpad: return pad.dpad.sfSymbolsName
            case .leftTrigger: return pad.leftTrigger.sfSymbolsName
            case .rightTrigger: return pad.rightTrigger.sfSymbolsName
            case .leftShoulder: return pad.leftShoulder.sfSymbolsName
            case .rightShoulder: return pad.rightShoulder.sfSymbolsName
            case .leftStick: return pad.leftThumbstick.sfSymbolsName
            case .rightStick: return pad.rightThumbstick.sfSymbolsName
            }
        }
    }
}

#Preview {
    ControlsView()
}
