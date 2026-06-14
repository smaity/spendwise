// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sajal Maity

import AVFoundation

/// Shared narration voice config — used both by the live player and the video exporter so the
/// spoken story sounds identical on screen and in the exported file.
enum StoryVoice {

    /// An utterance with per-scene prosody so the voice carries a bit of emotion instead of a
    /// flat read — warmer/slower for the intro and sign-off, brighter for the headline number.
    static func utterance(for scene: StoryScene) -> AVSpeechUtterance {
        let u = AVSpeechUtterance(string: scene.narration)
        u.voice = preferredVoice
        let base = AVSpeechUtteranceDefaultSpeechRate
        switch scene.kind {
        case .title:
            u.rate = base * 0.94; u.pitchMultiplier = 1.06   // warm welcome
        case .total:
            u.rate = base * 0.98; u.pitchMultiplier = 1.10   // a little excitement
        case .transfers, .categories, .trend:
            u.rate = base * 0.96; u.pitchMultiplier = 1.02
        case .closing:
            u.rate = base * 0.92; u.pitchMultiplier = 1.05   // encouraging sign-off
        }
        u.preUtteranceDelay = 0.05
        u.postUtteranceDelay = 0.25
        return u
    }

    /// The most natural installed voice: prefer Indian English, then UK/US English, and within a
    /// language prefer premium/enhanced (neural) voices over the compact default.
    static let preferredVoice: AVSpeechSynthesisVoice? = {
        let voices = AVSpeechSynthesisVoice.speechVoices()
        func rank(_ v: AVSpeechSynthesisVoice) -> Int {
            switch v.quality {
            case .premium:  return 3
            case .enhanced: return 2
            default:        return 1
            }
        }
        func best(_ prefix: String) -> AVSpeechSynthesisVoice? {
            voices.filter { $0.language.hasPrefix(prefix) }.max { rank($0) < rank($1) }
        }
        return best("en-IN") ?? best("en-GB") ?? best("en-US") ?? best("en")
            ?? AVSpeechSynthesisVoice(language: "en-US")
    }()
}
