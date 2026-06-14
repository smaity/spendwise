// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sajal Maity

import SwiftUI
import AVFoundation
import CoreVideo

/// Renders a Spending Story into a shareable .mp4 — entirely on-device. It rasterizes the same
/// `StoryFrame` used on screen (so the video matches the live playback, character and all) and
/// muxes in the on-device speech-synthesized narration.
@MainActor
final class StoryVideoExporter {

    struct Config {
        var size = CGSize(width: 720, height: 1280)   // portrait, share-friendly
        var fps: Int32 = 24
        var gap = 0.4                                  // breathing room after each scene's speech
    }

    enum ExportError: Error { case render, writer, noAudioFormat }

    func export(_ board: Storyboard, config: Config = .init()) async throws -> URL {
        let t0 = Date()
        let audio = await StoryAudioSynthesizer().synthesize(board, gap: config.gap)
        let t1 = Date()
        let video = try await renderVideo(board, sceneDurations: audio.spokenDurations, config: config)
        let t2 = Date()
        let out = try await StoryComposer.mux(video: video, audio: audio.url)
        let t3 = Date()
        // The muxed result is all we keep — drop the intermediate audio + silent video now.
        StoryTemp.remove(audio.url)
        StoryTemp.remove(video)
        NSLog("SPENDWISE_EXPORT_TIMING audio=%.1fs video=%.1fs mux=%.1fs total=%.1fs",
              t1.timeIntervalSince(t0), t2.timeIntervalSince(t1),
              t3.timeIntervalSince(t2), t3.timeIntervalSince(t0))
        return out
    }

    // MARK: Video

    private func renderVideo(_ board: Storyboard, sceneDurations: [Double], config: Config) async throws -> URL {
        let url = Self.tempURL("story-video", "mp4")
        let w = Int(config.size.width), h = Int(config.size.height)
        guard let writer = try? AVAssetWriter(outputURL: url, fileType: .mp4) else { throw ExportError.writer }

        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: w, AVVideoHeightKey: h,
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: w,
            kCVPixelBufferHeightKey as String: h,
        ]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: attrs)
        guard writer.canAdd(input) else { throw ExportError.writer }
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        let fps = Double(config.fps)
        var accumulated = 0.0
        for (i, _) in board.scenes.enumerated() {
            let spoken = sceneDurations[i]
            let total = spoken + config.gap
            let animDur = min(1.15, max(0.5, total * 0.7))
            let frameCount = max(1, Int((total * fps).rounded()))
            for f in 0..<frameCount {
                let tInScene = Double(f) / fps
                let p = min(1, tInScene / animDur)
                let speaking = tInScene < spoken
                let absTime = accumulated + tInScene
                guard let cg = renderFrame(board: board, index: i, p: p, time: absTime,
                                           speaking: speaking, size: config.size) else { continue }
                guard let pb = Self.pixelBuffer(from: cg, size: config.size, pool: adaptor.pixelBufferPool) else { continue }
                while !input.isReadyForMoreMediaData { await Task.yield() }
                adaptor.append(pb, withPresentationTime: CMTime(seconds: absTime, preferredTimescale: 600))
            }
            accumulated += total
        }
        input.markAsFinished()
        await writer.finishWriting()
        return url
    }

    @MainActor
    private func renderFrame(board: Storyboard, index: Int, p: Double, time: Double,
                             speaking: Bool, size: CGSize) -> CGImage? {
        let frame = StoryFrame(board: board, index: index, progress: p, time: time,
                               speaking: speaking, bottomInset: 36)
            .frame(width: size.width, height: size.height)
            .environment(\.colorScheme, .dark)
        let renderer = ImageRenderer(content: frame)
        renderer.scale = 1
        renderer.isOpaque = true
        return renderer.cgImage
    }

    // MARK: Helpers

    private static func tempURL(_ name: String, _ ext: String) -> URL {
        StoryTemp.url("\(name).\(ext)")   // isolated folder; AVFoundation refuses to overwrite
    }

    private static func pixelBuffer(from image: CGImage, size: CGSize, pool: CVPixelBufferPool?) -> CVPixelBuffer? {
        let w = Int(size.width), h = Int(size.height)
        var pb: CVPixelBuffer?
        if let pool {
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb)
        }
        if pb == nil {
            let attrs: [String: Any] = [
                kCVPixelBufferCGImageCompatibilityKey as String: true,
                kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
            ]
            CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pb)
        }
        guard let buffer = pb else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let ctx = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer), width: w, height: h,
            bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return buffer
    }
}
