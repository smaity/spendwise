// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sajal Maity

import SwiftUI

/// Deterministic 0…1 pseudo-random from an integer seed — lets particles/grain be a pure
/// function of frame, so the live view and the exported video render identical motion.
func storyHash01(_ n: Int) -> Double {
    let x = sin(Double(n) * 127.1 + 311.7) * 43758.5453
    return x - floor(x)
}

/// A moving "aurora" backdrop: a few large, soft, drifting color blobs over black, with a
/// vignette and a bottom scrim for caption legibility. Cinematic, on-device, deterministic.
struct CinematicBackground: View {
    var time: Double
    var tint: Color

    var body: some View {
        // Drawn with Canvas radial gradients (no `.blur`) so it renders fast both live and in
        // the ImageRenderer-based video export — a CPU Gaussian blur per frame would be far too
        // slow. The soft falloff of the gradients gives the same aurora glow.
        Canvas { ctx, size in
            let w = size.width, h = size.height
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.black))

            blob(&ctx, tint.opacity(0.55), r: w * 0.85,
                 x: 0.28 + 0.08 * sin(time * 0.23), y: 0.30 + 0.05 * cos(time * 0.19), w, h)
            blob(&ctx, Brand.ai.opacity(0.5), r: w * 0.95,
                 x: 0.80 + 0.07 * cos(time * 0.17), y: 0.72 + 0.06 * sin(time * 0.21), w, h)
            blob(&ctx, tint.opacity(0.4), r: w * 0.7,
                 x: 0.62 + 0.06 * sin(time * 0.13 + 1), y: 0.16 + 0.05 * cos(time * 0.15), w, h)

            // bottom scrim for caption legibility
            ctx.fill(Path(CGRect(x: 0, y: h * 0.5, width: w, height: h * 0.5)),
                     with: .linearGradient(Gradient(colors: [.clear, .black.opacity(0.65)]),
                                           startPoint: CGPoint(x: 0, y: h * 0.5),
                                           endPoint: CGPoint(x: 0, y: h)))
            // vignette
            ctx.fill(Path(CGRect(origin: .zero, size: size)),
                     with: .radialGradient(Gradient(colors: [.clear, .black.opacity(0.55)]),
                                           center: CGPoint(x: w / 2, y: h / 2),
                                           startRadius: w * 0.33, endRadius: w * 0.95))
        }
    }

    private func blob(_ ctx: inout GraphicsContext, _ color: Color, r: CGFloat,
                      x: Double, y: Double, _ w: CGFloat, _ h: CGFloat) {
        let center = CGPoint(x: x * w, y: y * h)
        let rect = CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2)
        ctx.fill(Path(ellipseIn: rect),
                 with: .radialGradient(Gradient(colors: [color, .clear]),
                                       center: center, startRadius: 0, endRadius: r))
    }
}

/// Soft drifting bokeh particles for depth. Rendered in a Canvas (ImageRenderer-safe).
struct ParticleField: View {
    var time: Double
    var count: Int = 26
    var color: Color = .white

    var body: some View {
        Canvas { ctx, size in
            for i in 0..<count {
                let seedX = storyHash01(i * 2 + 1)
                let seedS = storyHash01(i * 5 + 3)
                let speed = 0.015 + 0.05 * storyHash01(i * 7 + 2)
                let y = (storyHash01(i * 3 + 7) + time * speed).truncatingRemainder(dividingBy: 1.0)
                let x = seedX + 0.04 * sin(time * 0.5 + Double(i))
                let r = 1.5 + 4.5 * seedS
                let rect = CGRect(x: x * size.width - r, y: (1 - y) * size.height - r, width: r * 2, height: r * 2)
                ctx.opacity = 0.12 + 0.32 * seedS
                ctx.fill(Path(ellipseIn: rect), with: .color(color))
            }
        }
        .allowsHitTesting(false)
    }
}

/// Confetti burst for celebratory moments — falls and fades over `progress`.
struct ConfettiField: View {
    var time: Double
    var progress: Double
    var count: Int = 60

    private let colors: [Color] = [.pink, .yellow, .mint, Brand.accent, Brand.ai, .orange]

    var body: some View {
        Canvas { ctx, size in
            let fall = progress
            for i in 0..<count {
                let sx = storyHash01(i * 11 + 1)
                let drift = 0.06 * sin(time * 1.3 + Double(i))
                let y = (storyHash01(i * 9 + 4) + fall * (0.6 + storyHash01(i))).truncatingRemainder(dividingBy: 1.0)
                let x = sx + drift
                let s = 3 + 5 * storyHash01(i * 13 + 2)
                let rect = CGRect(x: x * size.width, y: y * size.height, width: s, height: s * 1.6)
                ctx.opacity = max(0, 0.9 - fall * 0.7)
                ctx.fill(Path(rect), with: .color(colors[i % colors.count]))
            }
        }
        .allowsHitTesting(false)
    }
}

/// Subtle film grain that changes each frame, for a cinematic texture.
struct FilmGrain: View {
    var time: Double
    var intensity: Double = 0.05

    var body: some View {
        Canvas { ctx, size in
            let frame = Int(time * 24)
            for i in 0..<240 {
                let sx = storyHash01(i * 13 + frame * 7)
                let sy = storyHash01(i * 29 + frame * 5)
                let sv = storyHash01(i * 17 + frame)
                ctx.opacity = intensity * sv
                ctx.fill(Path(ellipseIn: CGRect(x: sx * size.width, y: sy * size.height, width: 1.1, height: 1.1)),
                         with: .color(.white))
            }
        }
        .blendMode(.overlay)
        .allowsHitTesting(false)
    }
}
