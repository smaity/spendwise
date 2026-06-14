// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sajal Maity

import Foundation
#if os(iOS)
import ReplayKit
import AVFoundation
import CoreMedia
#endif

#if os(iOS)

/// Captures the live, GPU-rendered Spending Story straight off the screen with ReplayKit and
/// the hardware H.264 encoder — the fastest, highest-fidelity way to produce the .mp4 on
/// device (it records exactly what's drawn, including app audio for the narration).
///
/// Note: ReplayKit in-app capture is unavailable in the Simulator — callers should check
/// `isAvailable` and fall back to the offline `StoryVideoExporter` there.
final class StoryScreenRecorder {

    static var isAvailable: Bool { RPScreenRecorder.shared().isAvailable }

    enum RecorderError: Error { case notStarted, failed }

    private let recorder = RPScreenRecorder.shared()
    private let queue = DispatchQueue(label: "com.spendwise.story.recorder")
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var started = false
    private var outputURL: URL?

    /// Records the screen VIDEO only. The narration is synthesized separately and muxed in
    /// afterward (see `StoryComposer`) — ReplayKit's app-audio capture is unreliable for
    /// speech-synthesized audio, so we never depend on it.
    func start() async throws {
        let url = StoryTemp.url("story-record.mp4")
        outputURL = url
        started = false

        recorder.isMicrophoneEnabled = false
        recorder.isCameraEnabled = false

        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        self.writer = writer

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            recorder.startCapture(handler: { [weak self] sample, type, error in
                guard error == nil else { return }
                self?.queue.async { self?.append(sample, type) }
            }, completionHandler: { error in
                if let error { cont.resume(throwing: error) } else { cont.resume() }
            })
        }
    }

    func stop() async throws -> URL {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            recorder.stopCapture { error in
                if let error { cont.resume(throwing: error) } else { cont.resume() }
            }
        }
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<URL, Error>) in
            queue.async { [weak self] in
                guard let self, let writer = self.writer, let url = self.outputURL, self.started else {
                    cont.resume(throwing: RecorderError.notStarted); return
                }
                self.videoInput?.markAsFinished()
                writer.finishWriting {
                    if writer.status == .completed { cont.resume(returning: url) }
                    else { cont.resume(throwing: writer.error ?? RecorderError.failed) }
                }
            }
        }
    }

    // Runs on the serial `queue`.
    private func append(_ sample: CMSampleBuffer, _ type: RPSampleBufferType) {
        guard let writer, CMSampleBufferDataIsReady(sample) else { return }
        switch type {
        case .video:
            if !started {
                guard let fmt = CMSampleBufferGetFormatDescription(sample) else { return }
                let dims = CMVideoFormatDescriptionGetDimensions(fmt)
                let settings: [String: Any] = [
                    AVVideoCodecKey: AVVideoCodecType.h264,
                    AVVideoWidthKey: Int(dims.width),
                    AVVideoHeightKey: Int(dims.height),
                ]
                let vIn = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
                vIn.expectsMediaDataInRealTime = true
                if writer.canAdd(vIn) { writer.add(vIn) }
                self.videoInput = vIn
                writer.startWriting()
                writer.startSession(atSourceTime: CMSampleBufferGetPresentationTimeStamp(sample))
                started = true
            }
            if let v = videoInput, v.isReadyForMoreMediaData { v.append(sample) }
        default:
            break   // audio is added later via mux; ignore ReplayKit audio/mic
        }
    }
}
#else
// macOS placeholder. Live screen capture on the Mac is implemented via ScreenCaptureKit in
// `StoryScreenRecorderMac` (milestone M4); until then the Story still exports offline through
// `StoryVideoExporter`, exactly as it does in the iOS Simulator where ReplayKit is unavailable.
final class StoryScreenRecorder {
    static var isAvailable: Bool { false }
    enum RecorderError: Error { case notStarted, failed, unavailable }
    func start() async throws { throw RecorderError.unavailable }
    func stop() async throws -> URL { throw RecorderError.unavailable }
}
#endif
