import AppKit
import SwiftUI

/// Liquid Glass overlay that drops in under the menu bar: a living orb that follows your voice, the live
/// transcript, and a chip for each action as it completes.
///
/// It never takes focus (typing keeps going to the app you're dictating into), and it only renders while
/// visible: the orb animates at ≤30 fps and the panel is ordered out when hidden, so it costs nothing idle.
@MainActor
final class HUD {
    private let model = HUDModel()
    private let panel: NSPanel
    private var hideWork: DispatchWorkItem?
    private static let size = NSSize(width: 720, height: 340)

    var onVisibilityChange: (Bool) -> Void = { _ in }

    init() {
        panel = NSPanel(contentRect: NSRect(origin: .zero, size: Self.size),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        let host = NSHostingView(rootView: HUDView(model: model))
        host.sizingOptions = []
        panel.contentView = host
    }

    func show() {
        hideWork?.cancel()
        model.final = ""; model.volatile = ""; model.answer = nil; model.hint = nil
        model.chips = []
        model.phase = .listening
        model.level = 0
        if let screen = NSScreen.main {
            let top = screen.visibleFrame.maxY
            panel.setFrameOrigin(NSPoint(x: screen.frame.midX - Self.size.width / 2, y: top - Self.size.height - 4))
        }
        panel.orderFrontRegardless()
        onVisibilityChange(true)
        // Next runloop turn so SwiftUI sees the change and runs the entrance transition.
        DispatchQueue.main.async { self.model.visible = true }
    }

    func text(final: String, volatile: String) {
        if model.final != final { model.final = final }
        if model.volatile != volatile { model.volatile = volatile }
    }

    func level(_ v: Float) {
        model.level = model.level * 0.55 + CGFloat(v) * 0.45
    }

    func thinking() { model.phase = .thinking }

    func did(_ action: Action, _ outcome: Executor.Outcome) {
        switch action {
        case .type, .backspace, .beginDictation, .stopListening: return    // dictation shows up in the app itself
        default: break
        }
        var icon: NSImage?
        if case .openApp(let app) = action { icon = NSWorkspace.shared.icon(forFile: app.url.path) }
        var failed = false
        switch outcome {
        case .failed(let text): failed = true; message(text, hint: nil)
        case .info(let text): message(text, hint: nil)
        case .asking(let q): message(q, hint: "Say “yes” or “no”")
        case .done: break
        }
        if !panel.isVisible { show() }
        model.chips.append(Chip(text: action.description, symbol: failed ? "exclamationmark.triangle.fill" : action.symbol, icon: icon, failed: failed))
        if model.chips.count > 4 { model.chips.removeFirst() }
        if case .asking = outcome { hideWork?.cancel() } else if !model.listening { hide() }
    }

    func note(_ s: String) {
        model.chips.append(Chip(text: s, symbol: "questionmark.bubble", icon: nil, failed: true))
    }

    /// Whether the mic is taking a command right now (the HUD stays up while it is).
    func setListening(_ on: Bool) { model.listening = on }

    /// A spoken answer or result: show it and keep the HUD up long enough to read.
    func answer(_ text: String) {
        if !panel.isVisible { show() }
        message(text, hint: nil)
        model.phase = .done
        hide()
    }

    private func message(_ text: String, hint: String?) {
        model.answer = text
        model.hint = hint
        if hint == nil { model.phase = .done }
    }

    func hide(after seconds: Double = 0.9) {
        hideWork?.cancel()
        if model.phase != .thinking && !model.chips.isEmpty { model.phase = .done }
        let w = DispatchWorkItem { [weak self] in
            guard let self else { return }
            model.visible = false
            onVisibilityChange(false)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                if !self.model.visible { self.panel.orderOut(nil) }
            }
        }
        hideWork = w
        let reading = model.answer.map { max(3.5, min(14, Double($0.count) / 15)) } ?? 0
        DispatchQueue.main.asyncAfter(deadline: .now() + max(seconds, reading), execute: w)
    }
}

extension HUD {
    /// Renders the HUD with sample content to a PNG (for checking the design without a screen).
    static func renderSample(to path: String, dark: Bool) {
        let m = HUDModel()
        m.visible = true
        m.final = "Open YouTube and play a random"
        m.volatile = "LTT video"
        m.level = 0.6
        m.answer = "Playing “Building the Rarest PC”."
        m.chips = [Chip(text: "Open YouTube", symbol: "safari", icon: nil),
                   Chip(text: "Play random LTT video on YouTube", symbol: "music.note", icon: nil)]
        let view = HUDView(model: m, preview: true)
            .background(dark ? Color(white: 0.16) : Color(white: 0.9))
            .environment(\.colorScheme, dark ? .dark : .light)
        let r = ImageRenderer(content: view)
        r.scale = 2
        if let img = r.nsImage, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) {
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        }
    }
}

struct Chip: Identifiable {
    let id = UUID()
    let text: String
    let symbol: String
    let icon: NSImage?
    var failed = false
}

@MainActor @Observable
final class HUDModel {
    enum Phase { case listening, thinking, done }
    var visible = false
    var phase: Phase = .listening
    var final = ""
    var volatile = ""
    var answer: String?
    var hint: String?
    var listening = false
    var chips: [Chip] = []
    var level: CGFloat = 0
}

struct HUDView: View {
    let model: HUDModel
    /// Static rendering for design checks (the offscreen renderer can't draw glass or animations).
    var preview = false

    var body: some View {
        VStack {
            if model.visible {
                card
                    .transition(.asymmetric(
                        insertion: .scale(scale: 0.6, anchor: .top).combined(with: .opacity).combined(with: .offset(y: -18)),
                        removal: .scale(scale: 0.85, anchor: .top).combined(with: .opacity).combined(with: .offset(y: -10))))
            }
            Spacer(minLength: 0)
        }
        .frame(width: 720, height: 340, alignment: .top)
        .animation(.spring(response: 0.45, dampingFraction: 0.72), value: model.visible)
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 14) {
                Group {
                    if preview { Orb(level: model.level, phase: model.phase, still: true) }
                    else if model.phase == .done { Orb(level: 0, phase: .done) }
                    else { LiveOrb(level: model.level, thinking: model.phase == .thinking).transition(.scale.combined(with: .opacity)) }
                }
                    .frame(width: 42, height: 42)
                transcript
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let answer = model.answer {
                VStack(alignment: .leading, spacing: 4) {
                    Text(answer)
                        .font(.system(size: 14.5, weight: .regular, design: .rounded))
                        .foregroundStyle(.primary.opacity(0.92))
                        .lineLimit(6)
                        .fixedSize(horizontal: false, vertical: true)
                    if let hint = model.hint {
                        Label(hint, systemImage: "mic.fill")
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .foregroundStyle(.tint)
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
            if !model.chips.isEmpty {
                GlassEffectContainer(spacing: 8) {
                    HStack(spacing: 8) {
                        ForEach(model.chips) { chip in
                            ChipView(chip: chip, preview: preview)
                                .transition(.scale(scale: 0.5).combined(with: .opacity))
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .frame(width: 560, alignment: .leading)
        .modifier(Glass(preview: preview, shape: RoundedRectangle(cornerRadius: 30, style: .continuous)))
        .shadow(color: .black.opacity(0.18), radius: 22, y: 10)
        .padding(.top, 6)
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: model.chips.count)
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: model.answer)
    }

    private var transcript: some View {
        let heard = (model.final + " " + model.volatile).trimmingCharacters(in: .whitespaces)
        return Group {
            if heard.isEmpty {
                Text(model.phase == .thinking ? "Thinking…" : "Listening…")
                    .foregroundStyle(.secondary)
            } else {
                Text("\(Text(model.final).foregroundStyle(.primary)) \(Text(model.volatile).foregroundStyle(.secondary))")
            }
        }
        .font(.system(size: 18, weight: .semibold, design: .rounded))
        .lineLimit(2)
        .truncationMode(.head)
        .contentTransition(.interpolate)
        .animation(.smooth(duration: 0.18), value: heard)
    }
}

private struct Glass<S: Shape>: ViewModifier {
    let preview: Bool
    let shape: S
    var tint: Color? = nil
    func body(content: Content) -> some View {
        if preview {
            content.background(shape.fill(.background.secondary)).overlay(shape.stroke(.white.opacity(0.25)))
        } else {
            content.glassEffect(tint.map { .regular.tint($0) } ?? .regular, in: shape)
        }
    }
}

private struct ChipView: View {
    let chip: Chip
    var preview = false
    var body: some View {
        HStack(spacing: 6) {
            if let icon = chip.icon {
                Image(nsImage: icon).resizable().frame(width: 16, height: 16)
            } else {
                Image(systemName: chip.symbol).font(.system(size: 11, weight: .semibold))
            }
            Text(chip.text).font(.system(size: 12, weight: .medium, design: .rounded)).lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .modifier(Glass(preview: preview, shape: Capsule(), tint: (chip.failed ? Color.red : Color.accentColor).opacity(0.28)))
    }
}

/// Two counter-rotating aurora gradients that swell with your voice. Turns into a check when done.
private struct Orb: View {
    let level: CGFloat
    let phase: HUDModel.Phase
    var still = false

    private static let colors: [Color] = [
        Color(red: 0.25, green: 0.85, blue: 1.0), Color(red: 0.35, green: 0.35, blue: 1.0), Color(red: 0.78, green: 0.3, blue: 1.0),
        Color(red: 1.0, green: 0.35, blue: 0.62), Color(red: 1.0, green: 0.62, blue: 0.3), Color(red: 0.25, green: 0.85, blue: 1.0),
    ]

    var body: some View {
        ZStack {
            if phase == .done {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(.white, LinearGradient(colors: [.green, .mint], startPoint: .top, endPoint: .bottom))
                    .transition(.scale(scale: 0.3).combined(with: .opacity))
                    .symbolEffect(.bounce, value: phase == .done)
            } else {
                TimelineView(.animation(minimumInterval: 1.0 / 30, paused: still)) { ctx in
                    let t = still ? 1 : ctx.date.timeIntervalSinceReferenceDate * (phase == .thinking ? 2.4 : 1)
                    ZStack {
                        Circle()
                            .fill(AngularGradient(colors: Self.colors, center: .center, angle: .degrees(t * 80)))
                            .blur(radius: 7)
                            .scaleEffect(0.82 + level * 0.45)
                            .opacity(0.9)
                        Circle()
                            .fill(AngularGradient(colors: Self.colors.reversed(), center: .center, angle: .degrees(-t * 130)))
                            .scaleEffect(0.62 + level * 0.3)
                            .blur(radius: 2.5)
                        Circle()
                            .fill(RadialGradient(colors: [.white, .white.opacity(0)], center: .center, startRadius: 0, endRadius: 12))
                            .scaleEffect(0.7 + level * 0.8)
                    }
                    .compositingGroup()
                }
                .transition(.scale.combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.6), value: phase == .done)
        .animation(.easeOut(duration: 0.1), value: level)
    }
}

/// The orb while listening, drawn by Core Animation: the gradients spin inside the window server, so Vox
/// itself does no work per frame (the SwiftUI version redrew blurred gradients 30 times a second, ~5% CPU).
/// Only the voice level changes from here, at the mic's 10 updates a second.
private struct LiveOrb: NSViewRepresentable {
    let level: CGFloat
    let thinking: Bool

    func makeNSView(context: Context) -> OrbLayerView { OrbLayerView() }
    func updateNSView(_ v: OrbLayerView, context: Context) { v.update(level: level, thinking: thinking) }
}

final class OrbLayerView: NSView {
    private let outer = CAGradientLayer(), inner = CAGradientLayer(), core = CAGradientLayer()
    private var thinking: Bool?

    private static let colors: [CGColor] = [
        NSColor(red: 0.25, green: 0.85, blue: 1.0, alpha: 1), NSColor(red: 0.35, green: 0.35, blue: 1.0, alpha: 1),
        NSColor(red: 0.78, green: 0.3, blue: 1.0, alpha: 1), NSColor(red: 1.0, green: 0.35, blue: 0.62, alpha: 1),
        NSColor(red: 1.0, green: 0.62, blue: 0.3, alpha: 1), NSColor(red: 0.25, green: 0.85, blue: 1.0, alpha: 1),
    ].map(\.cgColor)

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        // Edge softness matches the old blurs: 7 pt on the outer ring, 2.5 pt on the inner one (42 pt orb).
        for (l, colors, solid) in [(outer, Self.colors, 0.6), (inner, Self.colors.reversed(), 0.85)] {
            l.type = .conic
            l.colors = colors
            l.startPoint = CGPoint(x: 0.5, y: 0.5)
            l.endPoint = CGPoint(x: 0.5, y: 0)
            l.mask = Self.softDisc(solidTo: solid)
            layer?.addSublayer(l)
        }
        outer.opacity = 0.9
        core.type = .radial
        core.colors = [NSColor.white.cgColor, NSColor.white.withAlphaComponent(0).cgColor]
        core.startPoint = CGPoint(x: 0.5, y: 0.5)
        core.endPoint = CGPoint(x: 0.79, y: 0.79)      // 12 pt glow on a 42 pt orb, as before
        layer?.addSublayer(core)
    }
    required init?(coder: NSCoder) { fatalError() }

    /// A disc that fades out at the rim, standing in for a blur (which would need an offscreen pass).
    /// (A radial gradient's end point sets its radius: (1, 1) reaches the edge of the inscribed circle.)
    private static func softDisc(solidTo: Double) -> CAGradientLayer {
        let m = CAGradientLayer()
        m.type = .radial
        m.colors = [NSColor.white.cgColor, NSColor.white.cgColor, NSColor.white.withAlphaComponent(0).cgColor]
        m.locations = [0, NSNumber(value: solidTo), 1]
        m.startPoint = CGPoint(x: 0.5, y: 0.5)
        m.endPoint = CGPoint(x: 1, y: 1)
        return m
    }

    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for l in [outer, inner, core] {
            l.bounds = bounds
            l.position = CGPoint(x: bounds.midX, y: bounds.midY)
            l.mask?.frame = bounds
        }
        CATransaction.commit()
    }

    func update(level: CGFloat, thinking: Bool) {
        if self.thinking != thinking {
            self.thinking = thinking
            // Same speeds as before: 80°/s and -130°/s, 2.4x faster while thinking.
            let k = thinking ? 2.4 : 1
            for (l, degreesPerSecond) in [(outer, 80.0), (inner, -130.0)] {
                let spin = CABasicAnimation(keyPath: "transform.rotation.z")
                spin.byValue = degreesPerSecond > 0 ? Double.pi * 2 : -Double.pi * 2
                spin.duration = 360 / abs(degreesPerSecond) / k
                spin.repeatCount = .infinity
                l.add(spin, forKey: "spin")
            }
        }
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.1)
        outer.setValue(0.82 + level * 0.45, forKeyPath: "transform.scale")
        inner.setValue(0.62 + level * 0.3, forKeyPath: "transform.scale")
        core.setValue(0.7 + level * 0.8, forKeyPath: "transform.scale")
        CATransaction.commit()
    }
}
