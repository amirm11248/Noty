import AVFoundation
import Observation
import SwiftUI
import UIKit

@MainActor
@Observable
final class LectureAudioController: NSObject, AVAudioRecorderDelegate, AVAudioPlayerDelegate {
    private(set) var isRecording = false
    private(set) var isPreparingRecording = false
    private(set) var playingID: UUID?
    private(set) var recordingStartedAt: Date?
    private(set) var playbackDuration: Double = 0
    var error: String?
    @ObservationIgnored private var recorder: AVAudioRecorder?
    @ObservationIgnored private var player: AVAudioPlayer?
    @ObservationIgnored private var onRecorded: ((NotyAudioClip) -> Void)?
    @ObservationIgnored private var recordingPageID: UUID?
    @ObservationIgnored private var interruptedToken: NSObjectProtocol?
    @ObservationIgnored private var recordingTitle = ""
    @ObservationIgnored private var recordingRequestID: UUID?

    func startRecording(documentID: UUID, pageID: UUID?, store: NotyStore) async {
        guard !isRecording, !isPreparingRecording else { return }
        let requestID = UUID()
        recordingRequestID = requestID; isPreparingRecording = true
        defer { if recordingRequestID == requestID { recordingRequestID = nil; isPreparingRecording = false } }
        error = nil
        let allowed = await AVAudioApplication.requestRecordPermission()
        guard recordingRequestID == requestID, !Task.isCancelled,
              UIApplication.shared.applicationState == .active,
              store.documents.contains(where: { $0.id == documentID }) else { return }
        guard allowed else { error = "Allow microphone access in Settings to record a lecture."; return }
        do {
            stopPlayback()
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothHFP])
            try session.setActive(true)
            let directory = store.assetDirectoryURL(documentID: documentID)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent("lecture-\(UUID().uuidString).m4a")
            let recorder = try AVAudioRecorder(url: url, settings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44100, AVNumberOfChannelsKey: 1, AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue])
            recorder.delegate = self
            guard recorder.prepareToRecord(), recorder.record() else { throw LectureAudioError.recordingFailed }
            self.recorder = recorder
            recordingPageID = pageID
            recordingTitle = "Lecture · \(Date.now.formatted(date: .abbreviated, time: .shortened))"
            onRecorded = { clip in store.addAudioClip(documentID: documentID, clip: clip) }
            recordingStartedAt = .now; isRecording = true
            observeInterruptions()
        } catch {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            self.error = "Recording couldn’t start. Check microphone access and available storage."
        }
    }
    func stopRecording() {
        recordingRequestID = nil; isPreparingRecording = false
        guard let recorder, isRecording else { return }
        let duration = recorder.currentTime
        let url = recorder.url
        recorder.stop()
        self.recorder = nil; isRecording = false; recordingStartedAt = nil
        if duration > 0.1, FileManager.default.fileExists(atPath: url.path) {
            onRecorded?(NotyAudioClip(title: recordingTitle, fileName: url.lastPathComponent, duration: duration, pageID: recordingPageID))
        } else { try? FileManager.default.removeItem(at: url) }
        onRecorded = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
    func play(clip: NotyAudioClip, documentID: UUID, store: NotyStore) {
        guard !isRecording else { return }
        if playingID == clip.id { stopPlayback(); return }
        do {
            stopPlayback()
            guard let url = store.audioURL(documentID: documentID, clip: clip) else { throw LectureAudioError.recordingFailed }
            try AVAudioSession.sharedInstance().setCategory(.playback)
            try AVAudioSession.sharedInstance().setActive(true)
            let player = try AVAudioPlayer(contentsOf: url)
            player.delegate = self; player.enableRate = true
            self.player = player; playbackDuration = player.duration
            guard player.play() else { throw LectureAudioError.recordingFailed }
            playingID = clip.id
            observeInterruptions()
        } catch { stopPlayback(); self.error = "This recording couldn’t be played. Try reconnecting your audio output." }
    }
    private func observeInterruptions() {
        guard interruptedToken == nil else { return }
        interruptedToken = NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] notification in
            guard let type = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  type == AVAudioSession.InterruptionType.began.rawValue else { return }
            Task { @MainActor in self?.stopRecording(); self?.stopPlayback() }
        }
    }
    var playbackTime: Double { player?.currentTime ?? 0 }
    func seek(to time: Double) { player?.currentTime = min(max(time, 0), playbackDuration) }
    func skip(_ seconds: Double) { seek(to: playbackTime + seconds) }
    func setRate(_ rate: Float) { player?.rate = rate }
    func stopPlayback() { player?.stop(); player = nil; playingID = nil; try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation) }
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) { Task { @MainActor [weak self] in self?.stopPlayback() } }
    nonisolated func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: (any Error)?) {
        Task { @MainActor [weak self] in self?.stopRecording(); self?.error = "Recording stopped. Any completed audio has been saved." }
    }
    deinit { if let interruptedToken { NotificationCenter.default.removeObserver(interruptedToken) } }
}
private enum LectureAudioError: Error { case recordingFailed }

struct LectureAudioSheet: View {
    let documentID: UUID
    let pageID: UUID?
    let store: NotyStore
    let controller: LectureAudioController
    let onOpenPage: (UUID) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var rate: Float = 1
    @State private var deleteClip: NotyAudioClip?
    private var clips: [NotyAudioClip] { store.documents.first(where: { $0.id == documentID })?.audioClips ?? [] }
    var body: some View {
        NavigationStack {
            List {
                Section {
                    if controller.isRecording, let start = controller.recordingStartedAt {
                        TimelineView(.periodic(from: .now, by: 1)) { _ in
                            Label("Recording · \(start, style: .timer)", systemImage: "waveform").foregroundStyle(.red).font(.headline)
                        }
                        Button("Stop and save", systemImage: "stop.circle.fill") { controller.stopRecording() }
                        Text("Close this panel to keep writing while recording.").font(.caption).foregroundStyle(.secondary)
                    } else {
                        Button("Record lecture", systemImage: "mic.circle") { Task { await controller.startRecording(documentID: documentID, pageID: pageID, store: store) } }.disabled(controller.isPreparingRecording)
                        if controller.isPreparingRecording { ProgressView("Preparing microphone…") }
                    }
                    if let error = controller.error { Text(error).font(.caption).foregroundStyle(.red) }
                }
                Section("Recordings") {
                    if clips.isEmpty { Text("Save a lecture alongside your notes, then listen back at your own pace.").font(.subheadline).foregroundStyle(.secondary) }
                    ForEach(clips) { clip in
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Button { rate = 1; controller.play(clip: clip, documentID: documentID, store: store) } label: { Image(systemName: controller.playingID == clip.id ? "stop.circle.fill" : "play.circle.fill").font(.title) }.disabled(controller.isRecording || controller.isPreparingRecording).accessibilityLabel("Play or stop recording")
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(clip.title).font(.subheadline.weight(.medium))
                                    Text("\(Int(clip.duration) / 60)m \(Int(clip.duration) % 60)s").font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if let url = store.audioURL(documentID: documentID, clip: clip) { ShareLink(item: url) { Image(systemName: "square.and.arrow.up") }.accessibilityLabel("Share recording") }
                            }
                            if controller.playingID == clip.id {
                                TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                                    Slider(value: Binding(get: { controller.playbackTime }, set: { controller.seek(to: $0) }), in: 0...max(controller.playbackDuration, 1)).accessibilityLabel("Recording position")
                                }
                                HStack {
                                    Button("Back 15s", systemImage: "gobackward.15") { controller.skip(-15) }
                                    Picker("Speed", selection: $rate) { Text("1×").tag(Float(1)); Text("1.25×").tag(Float(1.25)); Text("1.5×").tag(Float(1.5)); Text("2×").tag(Float(2)) }
                                    Button("Forward 15s", systemImage: "goforward.15") { controller.skip(15) }
                                }.font(.caption).onChange(of: rate) { _, value in controller.setRate(value) }
                            }
                            if let pageID = clip.pageID, store.documents.first(where: { $0.id == documentID })?.pages.contains(where: { $0.id == pageID }) == true {
                                Button("Open lecture page", systemImage: "doc.text") { onOpenPage(pageID); dismiss() }.font(.caption)
                            }
                        }.padding(.vertical, 6).swipeActions { Button("Delete", role: .destructive) { deleteClip = clip } }
                    }
                }
            }.navigationTitle("Lecture audio").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
                .confirmationDialog("Delete this recording?", isPresented: Binding(get: { deleteClip != nil }, set: { if !$0 { deleteClip = nil } }), titleVisibility: .visible) {
                    Button("Delete recording", role: .destructive) { if let clip = deleteClip { if controller.playingID == clip.id { controller.stopPlayback() }; store.deleteAudioClip(documentID: documentID, clipID: clip.id) }; deleteClip = nil }
                }
        }
    }
}
