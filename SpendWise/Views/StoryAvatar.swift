// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sajal Maity

import SwiftUI

/// The host's emotion for a scene.
enum AvatarMood {
    case neutral, happy, excited, concerned, celebrate

    /// Smile (+) to frown (−) curvature of the mouth.
    var mouthCurve: Double {
        switch self {
        case .neutral:   return 0.18
        case .happy:     return 0.55
        case .excited:   return 0.5
        case .concerned: return -0.45
        case .celebrate: return 0.65
        }
    }
    var browAngle: Double {            // radians; negative = worried
        switch self {
        case .concerned: return -0.5
        case .excited, .celebrate: return 0.18
        default: return 0
        }
    }
    var eyeOpen: Double { self == .excited || self == .celebrate ? 1.12 : 1.0 }
    var tint: Color {
        switch self {
        case .happy, .celebrate: return Brand.accent
        case .excited:           return .orange
        case .concerned:         return .pink
        case .neutral:           return Brand.ai
        }
    }
}

/// A friendly, stylized talking face that lip-syncs to the narration. Animation is a pure
/// function of `renderTime` when provided (so the video exporter can render exact frames),
/// otherwise it animates live via TimelineView.
struct StoryAvatar: View {
    var mood: AvatarMood
    var speaking: Bool
    var renderTime: Double? = nil

    var body: some View {
        if let t = renderTime {
            face(at: t)
        } else {
            TimelineView(.animation) { ctx in
                face(at: ctx.date.timeIntervalSinceReferenceDate)
            }
        }
    }

    private func face(at t: Double) -> some View {
        // Mouth opens/closes quickly while speaking; settles to a gentle rest otherwise.
        let talk = 0.5 + 0.5 * sin(t * 13)
        let openness = speaking ? 0.22 + 0.72 * max(0, talk) : (mood == .neutral ? 0.04 : 0.14)
        // Occasional blink: a short dip every few seconds.
        let blinkPhase = (t.truncatingRemainder(dividingBy: 3.4)) / 3.4
        let blink = blinkPhase > 0.94 ? (1 - abs(blinkPhase - 0.97) / 0.03) : 0
        let eyeScaleY = max(0.10, mood.eyeOpen * (1 - blink))
        // Idle life: gentle breathing bob + a little head sway, faster when speaking.
        let bob = sin(t * (speaking ? 2.4 : 1.5))
        let sway = sin(t * 0.8)
        let pulse = speaking ? 1 + 0.05 * sin(t * 6) : 1
        let light = mood.tint

        return GeometryReader { geo in
            let s = min(geo.size.width, geo.size.height)
            let eyeW = s * 0.135, eyeH = s * 0.185
            ZStack {
                // Soft glow halo (radial gradient instead of blur — fast under ImageRenderer)
                Circle().fill(
                    RadialGradient(colors: [light.opacity(0.55), .clear],
                                   center: .center, startRadius: s * 0.32, endRadius: s * 0.78))
                    .frame(width: s * 1.6, height: s * 1.6)
                    .scaleEffect(pulse)
                // Pulsing rings while speaking
                if speaking {
                    Circle().stroke(light.opacity(0.30), lineWidth: 2)
                        .frame(width: s * 1.10, height: s * 1.10).scaleEffect(pulse)
                    Circle().stroke(light.opacity(0.15), lineWidth: 2)
                        .frame(width: s * 1.24, height: s * 1.24).scaleEffect(pulse)
                }

                // The character: a friendly gold rupee coin.
                ZStack {
                    // Gold coin body
                    Circle().fill(
                        RadialGradient(colors: [Self.goldLight, Self.gold, Self.goldDark],
                                       center: UnitPoint(x: 0.35, y: 0.3), startRadius: 1, endRadius: s * 0.92)
                    )
                    // Milled (ridged) coin edge
                    Circle().strokeBorder(Self.goldDark.opacity(0.85),
                                          style: StrokeStyle(lineWidth: s * 0.06, dash: [s * 0.05, s * 0.032]))
                    // Inner raised face
                    Circle().fill(
                        RadialGradient(colors: [Self.goldLight.opacity(0.95), Self.gold],
                                       center: UnitPoint(x: 0.4, y: 0.32), startRadius: 1, endRadius: s * 0.5))
                        .frame(width: s * 0.82, height: s * 0.82)
                    Circle().strokeBorder(Self.goldDark.opacity(0.45), lineWidth: s * 0.012)
                        .frame(width: s * 0.82, height: s * 0.82)
                    // Embossed rupee mark
                    Text("₹")
                        .font(.system(size: s * 0.58, weight: .heavy, design: .rounded))
                        .foregroundStyle(Self.goldDark.opacity(0.30))
                    // rim light
                    Circle().strokeBorder(
                        AngularGradient(colors: [.clear, .clear, .white.opacity(0.5), .clear],
                                        center: .center,
                                        startAngle: .degrees(0), endAngle: .degrees(360)),
                        lineWidth: s * 0.04)
                    // top-left specular highlight
                    Ellipse().fill(
                        RadialGradient(colors: [.white.opacity(0.45), .clear],
                                       center: .center, startRadius: 0, endRadius: s * 0.16))
                        .frame(width: s * 0.36, height: s * 0.24)
                        .offset(x: -s * 0.22, y: -s * 0.26)

                    eyes(s: s, eyeW: eyeW, eyeH: eyeH, scaleY: eyeScaleY, look: sway * 0.02)
                    if mood.browAngle != 0 {
                        HStack(spacing: s * 0.22) {
                            brow(width: eyeW * 1.25, angle: mood.browAngle)
                            brow(width: eyeW * 1.25, angle: -mood.browAngle)
                        }
                        .offset(y: -s * 0.30)
                    }
                    mouth(s: s, openness: openness)
                    if mood == .happy || mood == .celebrate || mood == .excited {
                        HStack(spacing: s * 0.46) {
                            ForEach(0..<2, id: \.self) { _ in
                                Circle().fill(
                                    RadialGradient(colors: [.pink.opacity(0.5), .clear],
                                                   center: .center, startRadius: 0, endRadius: s * 0.075))
                                    .frame(width: s * 0.16, height: s * 0.16)
                            }
                        }
                        .offset(y: s * 0.11)
                    }
                }
                .frame(width: s, height: s)
                .rotationEffect(.degrees(sway * 2))
                .offset(y: bob * s * 0.02)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }

    private func eyes(s: CGFloat, eyeW: CGFloat, eyeH: CGFloat, scaleY: Double, look: Double) -> some View {
        HStack(spacing: s * 0.22) {
            ForEach(0..<2, id: \.self) { _ in
                ZStack {
                    Capsule().fill(.white)
                        .frame(width: eyeW, height: eyeH)
                    // iris + pupil with a catchlight
                    Circle().fill(.black.opacity(0.85))
                        .frame(width: eyeW * 0.56, height: eyeW * 0.56)
                        .overlay(Circle().fill(.white).frame(width: eyeW * 0.18, height: eyeW * 0.18)
                            .offset(x: eyeW * 0.12, y: -eyeW * 0.12))
                        .offset(x: look * s)
                        .opacity(scaleY > 0.35 ? 1 : 0)
                }
                .frame(width: eyeW, height: eyeH)
                .scaleEffect(x: 1, y: scaleY, anchor: .center)
            }
        }
        .offset(y: -s * 0.13)
    }

    private func mouth(s: CGFloat, openness: Double) -> some View {
        ZStack {
            MouthShape(openness: openness, curve: mood.mouthCurve)
                .fill(.black.opacity(0.82))
            // tongue hint when wide open
            if openness > 0.45 {
                Ellipse().fill(.pink.opacity(0.7))
                    .frame(width: s * 0.12, height: s * 0.06 * openness)
                    .offset(y: s * 0.04)
            }
        }
        .frame(width: s * 0.34, height: s * 0.22)
        .offset(y: s * 0.18)
    }

    private func brow(width: CGFloat, angle: Double) -> some View {
        Capsule().fill(.white.opacity(0.9))
            .frame(width: width, height: width * 0.17)
            .rotationEffect(.radians(angle))
    }

    // Coin palette for the rupee mascot.
    private static let goldLight = Color(red: 1.00, green: 0.88, blue: 0.52)
    private static let gold      = Color(red: 0.96, green: 0.74, blue: 0.22)
    private static let goldDark  = Color(red: 0.70, green: 0.48, blue: 0.08)
}

/// A lip/mouth: a lens whose vertical opening is `openness` (0…1) and whose `curve` bends it
/// into a smile (+) or frown (−).
struct MouthShape: Shape {
    var openness: Double
    var curve: Double

    var animatableData: AnimatablePair<Double, Double> {
        get { AnimatablePair(openness, curve) }
        set { openness = newValue.first; curve = newValue.second }
    }

    func path(in r: CGRect) -> Path {
        var p = Path()
        let cornerY = r.midY - curve * r.height * 0.22
        let topCtrlY = r.midY - curve * r.height * 0.55
        let botCtrlY = r.midY + openness * r.height * 0.55 + curve * r.height * 0.08
        p.move(to: CGPoint(x: r.minX, y: cornerY))
        p.addQuadCurve(to: CGPoint(x: r.maxX, y: cornerY),
                       control: CGPoint(x: r.midX, y: topCtrlY))
        p.addQuadCurve(to: CGPoint(x: r.minX, y: cornerY),
                       control: CGPoint(x: r.midX, y: botCtrlY))
        p.closeSubpath()
        return p
    }
}

/// Picks the host's mood for a scene from its kind and the data (e.g. concerned when spending
/// rose sharply, celebratory when it fell).
func avatarMood(for scene: StoryScene, data: StoryData) -> AvatarMood {
    switch scene.kind {
    case .title:      return .happy
    case .total:
        if let d = data.deltaPercent { return d > 8 ? .concerned : (d < -5 ? .celebrate : .neutral) }
        return .neutral
    case .categories: return .neutral
    case .trend:      return .neutral
    case .transfers:  return .happy
    case .closing:
        if let d = data.deltaPercent, d < 0 { return .celebrate }
        return .happy
    }
}
