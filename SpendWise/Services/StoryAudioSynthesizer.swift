// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sajal Maity

import AVFoundation

/// Synthesizes a story's narration to a single audio file (on-device, via the speech
/// synthesizer's offline `write`), and reports each scene's spoken length. Shared by the
/// offline exporter and the live recorder so both produce a clean, reliable narration track —
/// independent of whether ReplayKit happens to capture app audio.
final class StoryAudioSynthesizer {

    struct Result { let url: URL?; let spokenDurations: [Double] }

    private var retainedSynths: [AVSpeechSynthesizer] = []

    /// Writes the whole narration to one `.caf` and returns each scene's spoken length. A short
    /// `gap` of silence is appended after each scene so the audio timeline matches the video.
    func synthesize(_ board: Storyboard, gap: Double) async -> Result {
        let url = StoryTemp.url("story-audio.caf")
        var file: AVAudioFile?
        var format: AVAudioFormat?
        var durations: [Double] = []

        for scene in board.scenes {
            let (buffers, frames, fmt) = await renderSceneAudio(scene)
            if let fmt, file == nil {
                format = fmt
                file = try? AVAudioFile(forWriting: url, settings: fmt.settings,
                                        commonFormat: fmt.commonFormat, interleaved: fmt.isInterleaved)
            }
            if let file {
                for b in buffers { try? file.write(from: b) }
                if let format, let silence = Self.silence(format: format, seconds: gap) {
                    try? file.write(from: silence)
                }
            }
            let sampleRate = fmt?.sampleRate ?? 22050
            let spoken = frames > 0 ? Double(frames) / sampleRate : Self.estimate(scene.narration)
            durations.append(spoken)
        }
        return Result(url: file == nil ? nil : url, spokenDurations: durations)
    }

    private func renderSceneAudio(_ scene: StoryScene) async -> (buffers: [AVAudioPCMBuffer], frames: AVAudioFrameCount, format: AVAudioFormat?) {
        await withCheckedContinuation { cont in
            let synth = AVSpeechSynthesizer()
            retainedSynths.append(synth)
            var buffers: [AVAudioPCMBuffer] = []
            var frames: AVAudioFrameCount = 0
            var format: AVAudioFormat?
            var resumed = false
            synth.write(StoryVoice.utterance(for: scene)) { buffer in
                guard let pcm = buffer as? AVAudioPCMBuffer else { return }
                if pcm.frameLength == 0 {
                    if !resumed { resumed = true; cont.resume(returning: (buffers, frames, format)) }
                    return
                }
                if format == nil { format = pcm.format }
                if let copy = Self.deepCopy(pcm) { buffers.append(copy); frames += pcm.frameLength }
            }
        }
    }

    static func estimate(_ text: String) -> Double {
        max(2.0, Double(text.split { $0 == " " || $0 == "\n" }.count) / 2.6)
    }

    private static func deepCopy(_ src: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: src.format, frameCapacity: src.frameLength) else { return nil }
        copy.frameLength = src.frameLength
        let channels = Int(src.format.channelCount)
        let count = Int(src.frameLength)
        if let s = src.floatChannelData, let d = copy.floatChannelData {
            for ch in 0..<channels { memcpy(d[ch], s[ch], count * MemoryLayout<Float>.size) }
        } else if let s = src.int16ChannelData, let d = copy.int16ChannelData {
            for ch in 0..<channels { memcpy(d[ch], s[ch], count * MemoryLayout<Int16>.size) }
        } else if let s = src.int32ChannelData, let d = copy.int32ChannelData {
            for ch in 0..<channels { memcpy(d[ch], s[ch], count * MemoryLayout<Int32>.size) }
        }
        return copy
    }

    private static func silence(format: AVAudioFormat, seconds: Double) -> AVAudioPCMBuffer? {
        let frames = AVAudioFrameCount(max(1, seconds * format.sampleRate))
        guard let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        buf.frameLength = frames
        let channels = Int(format.channelCount)
        if let d = buf.floatChannelData {
            for ch in 0..<channels { memset(d[ch], 0, Int(frames) * MemoryLayout<Float>.size) }
        } else if let d = buf.int16ChannelData {
            for ch in 0..<channels { memset(d[ch], 0, Int(frames) * MemoryLayout<Int16>.size) }
        } else if let d = buf.int32ChannelData {
            for ch in 0..<channels { memset(d[ch], 0, Int(frames) * MemoryLayout<Int32>.size) }
        }
        return buf
    }
}
