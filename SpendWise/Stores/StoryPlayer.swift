// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sajal Maity

import Foundation
import AVFoundation

/// Drives a Spending Story: speaks each scene's narration with the on-device speech
/// synthesizer and advances to the next scene when the line finishes. Works with audio
/// (spoken) or muted (timed) — and in the Simulator, where Apple Intelligence may be absent
/// but speech + animation still run.
@MainActor
final class StoryPlayer: NSObject, ObservableObject {
    @Published private(set) var scenes: [StoryScene] = []
    @Published private(set) var index = 0
    @Published private(set) var isPlaying = false
    @Published private(set) var isFinished = false
    @Published private(set) var isSpeaking = false      // drives the avatar's lip-sync
    @Published private(set) var sceneStartedAt = Date()  // for entrance-animation progress
    @Published private(set) var sceneDuration = 4.0      // dwell time of the current scene
    @Published var isMuted = false

    var current: StoryScene? { scenes.indices.contains(index) ? scenes[index] : nil }
    var count: Int { scenes.count }
    var progress: Double { count <= 1 ? 1 : Double(index) / Double(count - 1) }

    private let synthesizer = AVSpeechSynthesizer()
    private var dwellTimer: Timer?
    private var capTimer: Timer?
    private var sceneToken = 0      // guards against stale timer/utterance callbacks
    private var dwellElapsed = false
    private var speechFinished = false
    private var fixedDurations: [Double]?   // when set, each scene shows for exactly this long

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    /// Loads a storyboard. Pass `sceneDurations` (the synthesized spoken length per scene) when
    /// recording, so the on-screen timeline matches the narration audio that gets muxed in.
    func load(_ storyboard: Storyboard, sceneDurations: [Double]? = nil) {
        stop()
        scenes = storyboard.scenes
        fixedDurations = sceneDurations
        index = 0
        isFinished = false
    }

    // MARK: Transport

    func play() {
        guard !scenes.isEmpty else { return }
        if isFinished { index = 0; isFinished = false }
        isPlaying = true
        activateAudioSession()
        startCurrentScene()
    }

    func pause() {
        isPlaying = false
        isSpeaking = false
        invalidateTimers()
        synthesizer.stopSpeaking(at: .immediate)
    }

    func togglePlay() { isPlaying ? pause() : play() }

    /// Plays from the very beginning — used when recording the story to video.
    func restart() {
        guard !scenes.isEmpty else { return }
        synthesizer.stopSpeaking(at: .immediate)
        index = 0
        isFinished = false
        isPlaying = true
        activateAudioSession()
        startCurrentScene()
    }

    func next() {
        guard index < scenes.count - 1 else { if isPlaying { finish() }; return }
        synthesizer.stopSpeaking(at: .immediate)
        index += 1
        isFinished = false
        if isPlaying { startCurrentScene() } else { sceneToken &+= 1 }
    }

    func previous() {
        synthesizer.stopSpeaking(at: .immediate)
        index = max(0, index - 1)
        isFinished = false
        if isPlaying { startCurrentScene() } else { sceneToken &+= 1 }
    }

    func toggleMute() {
        isMuted.toggle()
        if isPlaying {
            synthesizer.stopSpeaking(at: .immediate)
            startCurrentScene()
        }
    }

    func stop() {
        isPlaying = false
        isSpeaking = false
        invalidateTimers()
        synthesizer.stopSpeaking(at: .immediate)
        deactivateAudioSession()
    }

    // MARK: Scene engine
    //
    // A scene shows for at least its dwell time (so pacing is consistent everywhere — the
    // Simulator reports speech "finished" almost instantly since it doesn't render real-time
    // audio). We advance only once BOTH the dwell elapsed AND the narration finished. A cap
    // timer guards against a never-completing utterance.

    private func startCurrentScene() {
        invalidateTimers()
        guard isPlaying, let scene = current else { return }
        sceneToken &+= 1
        let token = sceneToken
        dwellElapsed = false
        speechFinished = isMuted   // nothing to wait for when muted
        isSpeaking = !isMuted
        sceneStartedAt = Date()

        if !isMuted {
            synthesizer.speak(StoryVoice.utterance(for: scene))
        }

        // When recording, hold each scene for its synthesized spoken length (+ the audio gap)
        // so the visuals line up with the narration track we mux in.
        let dwell = fixedDurations.map { $0[index] + 0.4 } ?? Self.estimatedDuration(scene.narration)
        sceneDuration = dwell
        dwellTimer = schedule(after: dwell, token: token) { [weak self] in
            self?.dwellElapsed = true
            self?.tryAdvance(token: token)
        }
        capTimer = schedule(after: dwell + 8, token: token) { [weak self] in
            self?.speechFinished = true; self?.dwellElapsed = true
            self?.tryAdvance(token: token)
        }
    }

    private func tryAdvance(token: Int) {
        guard isPlaying, token == sceneToken else { return }
        if dwellElapsed && speechFinished { advance() }
    }

    private func advance() {
        invalidateTimers()
        sceneToken &+= 1
        if index < scenes.count - 1 {
            index += 1
            startCurrentScene()
        } else {
            finish()
        }
    }

    private func finish() {
        isPlaying = false
        isSpeaking = false
        isFinished = true
        invalidateTimers()
        deactivateAudioSession()
    }

    private func schedule(after seconds: Double, token: Int, _ action: @escaping () -> Void) -> Timer {
        let timer = Timer(timeInterval: max(0.1, seconds), repeats: false) { _ in
            Task { @MainActor in action() }
        }
        RunLoop.main.add(timer, forMode: .common)
        return timer
    }

    private func invalidateTimers() {
        dwellTimer?.invalidate(); dwellTimer = nil
        capTimer?.invalidate(); capTimer = nil
    }

    /// Rough spoken length, used only as a fallback timer. ~2.6 words/second.
    private static func estimatedDuration(_ text: String) -> Double {
        let words = text.split { $0 == " " || $0 == "\n" }.count
        return max(2.5, Double(words) / 2.6)
    }

    private func activateAudioSession() {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        try? session.setActive(true)
        #endif
    }

    private func deactivateAudioSession() {
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        #endif
    }
}

extension StoryPlayer: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                       didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            guard self.isPlaying, !self.isMuted else { return }
            self.speechFinished = true
            self.isSpeaking = false
            self.tryAdvance(token: self.sceneToken)
        }
    }
    // didCancel (from stopSpeaking on pause/next/prev) is intentionally ignored.
}
