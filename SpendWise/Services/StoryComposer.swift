// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sajal Maity

import AVFoundation

/// Combines a (silent) video file with a narration audio file into a final shareable .mp4.
/// Used by both the offline exporter and the live recorder.
enum StoryComposer {
    enum ComposerError: Error { case noVideoTrack, failed }

    static func mux(video: URL, audio: URL?) async throws -> URL {
        let comp = AVMutableComposition()
        let vAsset = AVURLAsset(url: video)
        guard let vTrack = try await vAsset.loadTracks(withMediaType: .video).first,
              let compV = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
        else { throw ComposerError.noVideoTrack }
        let vDuration = try await vAsset.load(.duration)
        try compV.insertTimeRange(CMTimeRange(start: .zero, duration: vDuration), of: vTrack, at: .zero)
        compV.preferredTransform = try await vTrack.load(.preferredTransform)

        if let audio {
            let aAsset = AVURLAsset(url: audio)
            if let aTrack = try await aAsset.loadTracks(withMediaType: .audio).first,
               let compA = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
                let aDuration = try await aAsset.load(.duration)
                let use = min(aDuration, vDuration)
                try? compA.insertTimeRange(CMTimeRange(start: .zero, duration: use), of: aTrack, at: .zero)
            }
        }

        let outURL = StoryTemp.url("SpendingStory.mp4")
        guard let export = AVAssetExportSession(asset: comp, presetName: AVAssetExportPresetHighestQuality) else {
            throw ComposerError.failed
        }
        export.outputURL = outURL
        export.outputFileType = .mp4
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            export.exportAsynchronously { cont.resume() }
        }
        if export.status == .failed { throw export.error ?? ComposerError.failed }
        return outURL
    }
}
