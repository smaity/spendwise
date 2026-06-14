// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sajal Maity

import SwiftUI
import Charts
#if os(macOS)
import AppKit
#endif

// MARK: - Entry card (shown on the Insights tab)

/// A tappable card that launches the narrated, animated Spending Story for a chosen period.
struct SpendingStoryCard: View {
    @EnvironmentObject var store: TransactionStore
    @State private var period: StoryPeriod = .thisMonth
    @State private var present = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Spending Story", systemImage: "play.rectangle.on.rectangle.fill")
                .font(.caption.bold())
                .foregroundStyle(Brand.ai)
            Text("A narrated, animated recap of your spending — hosted by a friendly character, created on your device.")
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Menu {
                    ForEach(StoryPeriod.allCases) { p in
                        Button(p.title) { period = p }
                    }
                } label: {
                    Label(period.title, systemImage: "calendar")
                        .font(.subheadline.bold())
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(.ultraThinMaterial, in: Capsule())
                }
                Spacer()
                Button { present = true } label: {
                    Label("Play", systemImage: "play.fill")
                        .font(.subheadline.bold())
                        .padding(.horizontal, 18).padding(.vertical, 9)
                        .background(Brand.ai, in: Capsule())
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(
            LinearGradient(colors: [Brand.ai.opacity(0.14), Brand.accent.opacity(0.10)],
                           startPoint: .topLeading, endPoint: .bottomTrailing),
            in: RoundedRectangle(cornerRadius: 16)
        )
        .fullScreenCover(isPresented: $present) {
            SpendingStoryPlayerView(period: period).environmentObject(store)
        }
    }
}

// MARK: - Full-screen player

struct SpendingStoryPlayerView: View {
    @EnvironmentObject var store: TransactionStore
    @Environment(\.dismiss) private var dismiss
    let period: StoryPeriod

    @StateObject private var player = StoryPlayer()
    @State private var storyboard: Storyboard?
    @State private var phase: Phase = .preparing
    @State private var export: ExportState = .idle
    @State private var shareURL: URL?
    @State private var isRecording = false
    @State private var recorder = StoryScreenRecorder()
    private let narrator = AIStoryNarrationService()

    private enum Phase { case preparing, ready, empty }
    private enum ExportState: Equatable { case idle, rendering, ready }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            switch phase {
            case .preparing: preparingView
            case .empty:     emptyView
            case .ready:     if let board = storyboard { playerView(board) }
            }
            topBar
        }
        .preferredColorScheme(.dark)
        .statusBarHidden(isRecording)                                   // clean capture
        .persistentSystemOverlays(isRecording ? .hidden : .automatic)   // hide home indicator
        .task(id: period) { await prepare() }
        .onDisappear { player.stop(); StoryTemp.purge() }   // wipe video artifacts on close
        .sheet(item: $shareURL) { url in ShareSheet(items: [url]) }
    }

    // MARK: Phases

    private var preparingView: some View {
        ZStack {
            LinearGradient(colors: [Brand.ai.opacity(0.85), .black], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
            VStack(spacing: 16) {
                StoryAvatar(mood: .happy, speaking: true).frame(width: 110, height: 110)
                ProgressView().tint(.white)
                Text("Crafting your \(period.title.lowercased()) story…")
                    .font(.headline).foregroundStyle(.white)
                Text("Writing the narration and animations on-device.")
                    .font(.caption).foregroundStyle(.white.opacity(0.7))
            }
        }
    }

    private var emptyView: some View {
        VStack(spacing: 12) {
            Image(systemName: "sparkles").font(.largeTitle).foregroundStyle(.white)
            Text("No spending to recap").font(.headline).foregroundStyle(.white)
            Text("There are no transactions for \(period.title.lowercased()) yet.")
                .font(.subheadline).foregroundStyle(.white.opacity(0.75))
                .multilineTextAlignment(.center)
            Button("Close") { dismiss() }
                .font(.subheadline.bold()).foregroundStyle(.white)
                .padding(.horizontal, 20).padding(.vertical, 10)
                .background(.white.opacity(0.15), in: Capsule())
        }
        .padding(40)
    }

    private func playerView(_ board: Storyboard) -> some View {
        ZStack {
            // The animated frame, redrawn continuously (drives count-ups, bars, lip-sync).
            TimelineView(.animation) { ctx in
                let t = ctx.date.timeIntervalSinceReferenceDate
                let elapsed = t - player.sceneStartedAt.timeIntervalSinceReferenceDate
                let p = min(1, max(0, elapsed / 1.15))
                StoryFrame(board: board, index: player.index, progress: p, time: t,
                           speaking: player.isSpeaking, bottomInset: 150)
            }
            .ignoresSafeArea()

            // Interactive chrome is hidden while recording so the captured video stays clean.
            if !isRecording {
                // Tap zones: left = previous, right = next.
                HStack(spacing: 0) {
                    Color.clear.contentShape(Rectangle()).onTapGesture { player.previous() }
                    Color.clear.contentShape(Rectangle()).onTapGesture { player.next() }
                }

                VStack {
                    progressBars.padding(.horizontal, 16).padding(.top, 8)
                    Spacer()
                    controls.padding(.bottom, 18)
                }
            }
        }
    }

    @ViewBuilder private var topBar: some View {
        if !isRecording {
            VStack {
                HStack(spacing: 12) {
                    Spacer()
                    if phase == .ready {
                        Button { Task { await share() } } label: {
                            Group {
                                if export == .rendering {
                                    ProgressView().tint(.white)
                                } else {
                                    Image(systemName: "square.and.arrow.up")
                                }
                            }
                            .font(.headline).foregroundStyle(.white.opacity(0.9))
                            .frame(width: 40, height: 40)
                            .background(.white.opacity(0.15), in: Circle())
                        }
                        .disabled(export == .rendering)
                    }
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.headline).foregroundStyle(.white.opacity(0.9))
                            .frame(width: 40, height: 40)
                            .background(.white.opacity(0.15), in: Circle())
                    }
                }
                Spacer()
            }
            .padding()
        }
    }

    private var progressBars: some View {
        HStack(spacing: 4) {
            ForEach(0..<player.count, id: \.self) { i in
                Capsule()
                    .fill(.white.opacity(i <= player.index ? 0.95 : 0.3))
                    .frame(height: 3)
            }
        }
    }

    private var controls: some View {
        HStack(spacing: 28) {
            Button { player.previous() } label: {
                Image(systemName: "backward.fill").font(.title3)
            }
            .disabled(player.index == 0).opacity(player.index == 0 ? 0.4 : 1)

            Button { player.togglePlay() } label: {
                Image(systemName: player.isFinished ? "arrow.counterclockwise"
                      : (player.isPlaying ? "pause.fill" : "play.fill"))
                    .font(.title)
                    .frame(width: 64, height: 64)
                    .background(.white.opacity(0.18), in: Circle())
            }

            Button { player.next() } label: {
                Image(systemName: "forward.fill").font(.title3)
            }
            .disabled(player.index >= player.count - 1)
            .opacity(player.index >= player.count - 1 ? 0.4 : 1)

            Button { player.toggleMute() } label: {
                Image(systemName: player.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.title3)
            }
        }
        .foregroundStyle(.white)
    }

    // MARK: Build & export

    @MainActor private func prepare() async {
        phase = .preparing
        let data = StoryDataBuilder.build(period: period, expenses: store.visibleExpenses)
        guard !data.isEmpty else { phase = .empty; return }
        let (narration, isAI) = await narrator.narrate(data)
        let board = Storyboard.make(data: data, narration: narration, isAI: isAI)
        storyboard = board
        player.load(board)
        phase = .ready
        player.play()

        #if DEBUG
        if ProcessInfo.processInfo.environment["STORY_EXPORT"] != nil {
            player.pause()
            do {
                let url = try await StoryVideoExporter().export(board)
                let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
                NSLog("SPENDWISE_EXPORT_OK path=\(url.path) bytes=\(size)")
            } catch {
                NSLog("SPENDWISE_EXPORT_FAIL \(error)")
            }
        }
        #endif
    }

    /// Produces the shareable video. On a real device this records the live, GPU-rendered
    /// playback with ReplayKit (fast, hardware-encoded, pixel-perfect). In the Simulator (where
    /// ReplayKit is unavailable) it falls back to the offline frame renderer.
    @MainActor private func share() async {
        guard export != .rendering else { return }
        if StoryScreenRecorder.isAvailable {
            await record()
        } else {
            await exportVideo()
        }
    }

    /// Records the live, GPU-rendered playback to video, then muxes in a cleanly-synthesized
    /// narration track. We don't rely on ReplayKit to capture the speech audio (it doesn't,
    /// reliably) — the audio is generated separately and combined, so the output always has sound.
    @MainActor private func record() async {
        guard let board = storyboard, export != .rendering else { return }
        export = .rendering
        do {
            // 1. Clean narration audio + the spoken length of each scene (drives the timeline).
            let audio = await StoryAudioSynthesizer().synthesize(board, gap: 0.4)
            player.load(board, sceneDurations: audio.spokenDurations)

            // 2. Record the GPU-rendered playback (video only). Speech also plays live so the
            //    user hears it during the recording.
            try await recorder.start()
            isRecording = true
            player.isMuted = false
            try? await Task.sleep(for: .milliseconds(250))
            player.restart()
            while !player.isFinished { try? await Task.sleep(for: .milliseconds(100)) }
            try? await Task.sleep(for: .milliseconds(400))
            let videoURL = try await recorder.stop()
            isRecording = false

            // 3. Combine the recorded video with the narration track.
            let finalURL = try await StoryComposer.mux(video: videoURL, audio: audio.url)
            StoryTemp.remove(videoURL)
            StoryTemp.remove(audio.url)
            player.load(board)   // restore normal playback timing
            export = .ready
            shareURL = finalURL
        } catch {
            NSLog("SPENDWISE: live recording failed — \(error.localizedDescription); falling back to offline render")
            isRecording = false
            export = .idle
            await exportVideo()
        }
    }

    @MainActor private func exportVideo() async {
        guard let board = storyboard, export != .rendering else { return }
        player.pause()
        export = .rendering
        do {
            let url = try await StoryVideoExporter().export(board)
            export = .ready
            shareURL = url
        } catch {
            NSLog("SPENDWISE: story export failed — \(error.localizedDescription)")
            export = .idle
        }
    }
}

// MARK: - StoryFrame: one fully-composed, deterministic frame
//
// Everything is a pure function of `progress` (0→1 entrance) and `time` (for the avatar's
// lip-sync/idle motion). The live player drives these from a TimelineView; the video exporter
// drives them per rendered frame — so on-screen and exported video look identical.

struct StoryFrame: View {
    let board: Storyboard
    let index: Int
    let progress: Double
    let time: Double
    let speaking: Bool
    var bottomInset: CGFloat = 24

    private var scene: StoryScene { board.scenes[min(index, board.scenes.count - 1)] }
    private var data: StoryData { board.data }

    private var mood: AvatarMood { avatarMood(for: scene, data: data) }

    var body: some View {
        let ent = eased(progress)
        // Continuous "camera": a slow drifting Ken-Burns move + push-in, always in motion so
        // the frame never feels like a still image. Plus a per-scene slide-in entrance.
        let kenScale = 1.035 + 0.025 * sin(time * 0.22)
        let kenX = 7 * sin(time * 0.16)
        let kenY = 5 * cos(time * 0.13)

        return ZStack {
            CinematicBackground(time: time, tint: sceneTint)
                .scaleEffect(1.14)
                .offset(x: -kenX * 1.6, y: -kenY * 1.6)   // parallax: background drifts opposite
            ParticleField(time: time)

            VStack(spacing: 16) {
                header
                Spacer(minLength: 8)
                StoryAvatar(mood: mood, speaking: speaking, renderTime: time)
                    .frame(width: 132, height: 132)
                SceneVisual(scene: scene, data: data, p: progress, time: time)
                    .frame(maxWidth: .infinity)
                Spacer(minLength: 8)
                Color.clear.frame(height: bottomInset)
            }
            .padding(.horizontal, 26)
            .padding(.top, 54)
            .padding(.bottom, 16)
            .scaleEffect(kenScale)
            .offset(x: kenX + (1 - ent) * 48, y: kenY)
            .opacity(min(1, progress * 1.8))

            if mood == .celebrate {
                ConfettiField(time: time, progress: progress)
            }
            FilmGrain(time: time, intensity: 0.05)
        }
        .clipped()
    }

    private var header: some View {
        VStack(spacing: 4) {
            Text(board.title)
                .font(.headline).foregroundStyle(.white)
                .multilineTextAlignment(.center)
            Label(board.isAIGenerated ? "Narrated by Apple Intelligence" : "On-device narration",
                  systemImage: board.isAIGenerated ? "sparkles" : "iphone")
                .font(.caption2).foregroundStyle(.white.opacity(0.7))
        }
    }

    private var sceneTint: Color {
        switch scene.kind {
        case .title:      return Brand.ai
        case .total:      return Brand.accent
        case .categories: return .indigo
        case .trend:      return .teal
        case .transfers:  return .pink
        case .closing:    return Brand.ai
        }
    }
}

// MARK: - Progress-driven scene visuals

private func eased(_ p: Double) -> Double { 1 - pow(1 - max(0, min(1, p)), 3) }

/// Continuous gentle floating, driven by absolute time so the live view and exported video
/// move identically. Different phases keep a composition feeling alive.
private extension View {
    func floating(_ time: Double, amp: CGFloat = 6, speed: Double = 1, phase: Double = 0) -> some View {
        offset(y: amp * sin(time * speed + phase))
    }
}

/// A moving highlight sweeping across a filled bar/shape — adds life to otherwise static fills.
private struct Shimmer: View {
    let time: Double
    var speed: Double = 0.25
    var body: some View {
        GeometryReader { geo in
            let x = (time * speed).truncatingRemainder(dividingBy: 1)
            LinearGradient(colors: [.clear, .white.opacity(0.55), .clear],
                           startPoint: .leading, endPoint: .trailing)
                .frame(width: geo.size.width * 0.35)
                .offset(x: x * geo.size.width * 1.4 - geo.size.width * 0.2)
                .blendMode(.plusLighter)
        }
    }
}

private struct SceneVisual: View {
    let scene: StoryScene
    let data: StoryData
    let p: Double
    let time: Double

    var body: some View {
        switch scene.kind {
        case .title:      TitleScene(data: data, p: p, time: time)
        case .total:      TotalScene(data: data, p: p, time: time)
        case .categories: CategoriesScene(data: data, p: p, time: time)
        case .trend:      TrendScene(data: data, p: p, time: time)
        case .transfers:  TransfersScene(data: data, p: p, time: time)
        case .closing:    ClosingScene(data: data, p: p, time: time)
        }
    }
}

/// A rupee amount that grows from 0 to its value as `p` advances.
private struct StoryAmount: View {
    let value: Double
    let p: Double
    var size: CGFloat = 56
    var body: some View {
        Text("₹\(Int((value * eased(p)).rounded()).formatted())")
            .font(.system(size: size, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .monospacedDigit()
    }
}

private struct TitleScene: View {
    let data: StoryData; let p: Double; let time: Double
    var body: some View {
        VStack(spacing: 14) {
            Text(data.period.title)
                .font(.system(size: 40, weight: .heavy, design: .rounded))
                .foregroundStyle(.white)
                .scaleEffect(0.7 + 0.3 * eased(p))
                .floating(time, amp: 6, speed: 1.0)
            Text("\(data.txCount) transactions · \(data.dayCount) days")
                .font(.subheadline).foregroundStyle(.white.opacity(0.85))
                .opacity(eased(p))
                .floating(time, amp: 4, speed: 1.3, phase: 1.2)
        }
    }
}

private struct TotalScene: View {
    let data: StoryData; let p: Double; let time: Double
    var body: some View {
        VStack(spacing: 12) {
            Text("You spent").font(.headline).foregroundStyle(.white.opacity(0.85))
            ZStack {
                // Rotating glow ring behind the number — constant motion.
                Circle()
                    .stroke(AngularGradient(colors: [.clear, .white.opacity(0.5), .clear, .clear, .clear],
                                            center: .center, angle: .degrees(0)),
                            lineWidth: 8)
                    .frame(width: 230, height: 230)
                    .rotationEffect(.degrees(time * 26))
                    .opacity(0.7 * eased(p))
                StoryAmount(value: data.total, p: p, size: 60)
                    .scaleEffect(1 + 0.018 * sin(time * 2.2))
            }
            if let pct = data.deltaPercent {
                let up = pct >= 0
                Label("\(up ? "↑" : "↓") \(abs(Int(pct.rounded())))% vs last period",
                      systemImage: up ? "arrow.up.right" : "arrow.down.right")
                    .font(.subheadline.bold())
                    .padding(.horizontal, 14).padding(.vertical, 7)
                    .background((up ? Color.orange : Color.green).opacity(0.25), in: Capsule())
                    .foregroundStyle(up ? .orange : .green)
                    .opacity(p > 0.5 ? 1 : 0)
                    .floating(time, amp: 4, speed: 1.6, phase: 0.5)
            }
            Text("about ₹\(Int(data.perDay).formatted()) a day")
                .font(.caption).foregroundStyle(.white.opacity(0.7)).opacity(eased(p))
        }
    }
}

private struct CategoriesScene: View {
    let data: StoryData; let p: Double; let time: Double
    private var maxValue: Double { data.topCategories.map(\.total).max() ?? 1 }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Where it went").font(.title3.bold()).foregroundStyle(.white)
            ForEach(Array(data.topCategories.enumerated()), id: \.element.id) { i, slice in
                // Bars fill in sequence as p advances, then keep a live shimmer.
                let local = eased(min(1, max(0, p * 1.4 - Double(i) * 0.12)))
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Label(slice.name, systemImage: slice.icon)
                            .font(.subheadline.bold()).foregroundStyle(.white)
                        Spacer()
                        Text("₹\(Int(slice.total).formatted()) · \(Int(slice.percent))%")
                            .font(.caption.monospacedDigit()).foregroundStyle(.white.opacity(0.85))
                    }
                    GeometryReader { geo in
                        Capsule().fill(.white.opacity(0.18))
                            .overlay(alignment: .leading) {
                                Capsule()
                                    .fill(LinearGradient(colors: [.white, .white.opacity(0.7)],
                                                         startPoint: .leading, endPoint: .trailing))
                                    .frame(width: geo.size.width * CGFloat(slice.total / maxValue) * local)
                                    .overlay(Shimmer(time: time, speed: 0.22 + 0.05 * Double(i)).clipShape(Capsule()))
                            }
                    }
                    .frame(height: 11)
                }
                .floating(time, amp: 2, speed: 1.4, phase: Double(i) * 0.7)
            }
        }
    }
}

private struct TrendScene: View {
    let data: StoryData; let p: Double; let time: Double
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Your spending over time").font(.title3.bold()).foregroundStyle(.white)
            Chart(data.trend) { point in
                BarMark(x: .value("Period", point.label),
                        y: .value("Spent", point.total))
                    .foregroundStyle(.white.gradient)
                    .cornerRadius(6)
            }
            .chartYAxis { AxisMarks { _ in AxisValueLabel().foregroundStyle(.white.opacity(0.6)) } }
            .chartXAxis { AxisMarks { _ in AxisValueLabel().foregroundStyle(.white.opacity(0.85)) } }
            .frame(height: 200)
            .scaleEffect(y: max(0.02, eased(p)), anchor: .bottom)
            .overlay(Shimmer(time: time, speed: 0.18).opacity(eased(p)))   // a light sweeps across
            if let peak = data.peakTrend {
                Label("Peak: \(peak.label) · ₹\(Int(peak.total).formatted())", systemImage: "flame.fill")
                    .font(.caption).foregroundStyle(.white.opacity(0.85)).opacity(eased(p))
                    .floating(time, amp: 3, speed: 1.5)
            }
        }
    }
}

private struct TransfersScene: View {
    let data: StoryData; let p: Double; let time: Double
    var body: some View {
        VStack(spacing: 16) {
            Text("Money on the move").font(.title3.bold()).foregroundStyle(.white)
            HStack(spacing: 14) {
                if data.familySent > 0 {
                    tile("To family", data.familySent, "person.2.fill").floating(time, amp: 5, speed: 1.4)
                }
                if data.selfTransfers > 0 {
                    tile("Own accounts", data.selfTransfers, "arrow.left.arrow.right")
                        .floating(time, amp: 5, speed: 1.4, phase: .pi)
                }
            }
        }
    }
    private func tile(_ title: String, _ value: Double, _ icon: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon).font(.title2).foregroundStyle(.white)
                .scaleEffect(1 + 0.05 * sin(time * 2.4))
            StoryAmount(value: value, p: p, size: 28)
            Text(title).font(.caption).foregroundStyle(.white.opacity(0.85))
        }
        .frame(maxWidth: .infinity).padding(.vertical, 20)
        .background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 18))
    }
}

private struct ClosingScene: View {
    let data: StoryData; let p: Double; let time: Double
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 54)).foregroundStyle(.white)
                .scaleEffect((0.5 + 0.5 * eased(p)) * (1 + 0.04 * sin(time * 2.0)))
                .rotationEffect(.degrees(3 * sin(time * 1.2)))
            Text("That's your \(data.period.title.lowercased()) story")
                .font(.title3.bold()).foregroundStyle(.white)
                .multilineTextAlignment(.center).opacity(eased(p))
                .floating(time, amp: 4, speed: 1.1)
            Label("Created entirely on your iPhone", systemImage: "lock.fill")
                .font(.caption).foregroundStyle(.white.opacity(0.85)).opacity(eased(p))
        }
    }
}

// MARK: - Share sheet

/// Lets a file URL drive `.sheet(item:)`.
extension URL: Identifiable { public var id: String { absoluteString } }

#if os(iOS)
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
#elseif os(macOS)
/// macOS share: pops an NSSharingServicePicker from a hosting view.
struct ShareSheet: NSViewRepresentable {
    let items: [Any]
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            let picker = NSSharingServicePicker(items: items)
            picker.show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
        }
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}
#endif
