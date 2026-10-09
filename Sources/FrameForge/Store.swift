import SwiftUI
import AVKit
import ScreenCaptureKit
import UniformTypeIdentifiers

@MainActor final class Store: ObservableObject {
    @Published var project = Project()
    @Published var selected: UUID?
    @Published var player = AVPlayer()
    @Published var playhead: Double = 0
    @Published var status = "Ready to create"
    @Published var error: String?
    @Published var busy = false
    @Published var recording = false
    @Published var displays: [SCDisplay] = []
    @Published var displayID: UInt32 = CGMainDisplayID()
    @Published var displayOptions: [DisplayOption] = []
    // Remembered across launches: quick capture uses them without the editor open.
    @Published var systemAudio = UserDefaults.standard.object(forKey:"systemAudio") as? Bool ?? true {
        didSet { UserDefaults.standard.set(systemAudio,forKey:"systemAudio") }
    }
    @Published var audioApplicationID: Int32 = 0
    @Published var audioApplications: [AudioApplication] = []
    @Published var microphones: [MicrophoneDevice] = []
    @Published var microphoneID = UserDefaults.standard.string(forKey:"microphoneID") ?? "off" {
        didSet { UserDefaults.standard.set(microphoneID,forKey:"microphoneID") }
    }
    @Published var region: CGRect?
    @Published var regionMode = false
    @Published var maximumCaptureDimension = 3840
    @Published var recordingSeconds = 0.0
    private let regionSelector = RegionSelector()
    private var recordingTimer: Timer?
    private var recordingBegan: Date?
    private var previewObserver: NSKeyValueObservation?
    @Published var showCursor = true
    @Published var trackMouse = true
    @Published var microphoneGain = 0.5
    @Published var microphoneLevelDB = -120.0
    @Published var microphoneOverload = false
    @Published var silenceProposal: SilenceProposal?
    @Published var analysisProgress = 0.0
    @Published var copyRecordingToClipboard = UserDefaults.standard.object(forKey:"copyRecordingToClipboard") as? Bool ?? true {
        didSet { UserDefaults.standard.set(copyRecordingToClipboard,forKey:"copyRecordingToClipboard") }
    }
    @Published var captureFPS = 30
    @Published var progress: Float = 0
    @Published var exporting = false
    private var history: [Project] = []
    private var future: [Project] = []
    private var recorder = Recorder()
    private var recordingURL: URL?
    private var observer: Any?
    private var exportSession: AVAssetExportSession?
    private var previewTask: Task<Void, Never>?
    private var revision = 0
    private var hotKey: GlobalHotKey?
    init() {
        refreshLocalDevices()
        observer = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.1, preferredTimescale: 600), queue: .main) { [weak self] time in
            Task { @MainActor in self?.playhead = time.seconds.isFinite ? time.seconds : 0 }
        }
        hotKey = GlobalHotKey { [weak self] in
            Task { @MainActor in
                guard let self = self, !self.busy else { return }
                await self.toggleQuickCapture()
            }
        }
        recorder.onMicrophoneLevel = { [weak self] level in
            Task { @MainActor in self?.microphoneLevelDB = level.peakDB; self?.microphoneOverload = level.clipped > 0 }
        }
        recorder.onFailure = { [weak self] error in Task { @MainActor in
            self?.error = error.localizedDescription
            if self?.recording == true { await self?.stopRecording() }
        } }
    }
    var clip: Clip? { project.clips.first { $0.id == selected } }
    var canUndo: Bool { !history.isEmpty }
    var canRedo: Bool { !future.isEmpty }
    var recordingShortcutHint: String { hotKey?.isRegistered == true ? "⌥⇧R picks a screen or region, press again to stop" : "stop from the menu bar (global shortcut unavailable)" }
    func report(_ error: Error) {
        let nsError = error as NSError
        if nsError.domain == SCStreamErrorDomain && nsError.code == -3801 { reportScreenCaptureDenied(); return }
        self.error = error.localizedDescription
        status = "Action failed"
    }
    /// Registers this build with macOS (first call shows the system prompt) and opens the exact
    /// Settings pane, so the person only has to flip the switch and relaunch.
    func reportScreenCaptureDenied() {
        if !CGRequestScreenCaptureAccess(), let url = URL(string:"x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") { NSWorkspace.shared.open(url) }
        error = "Turn on FrameForge in System Settings → Privacy & Security → Screen & System Audio Recording (now open), then quit and reopen FrameForge. If an older FrameForge is listed, remove it."
        status = "Screen recording permission needed"
    }
    func refreshLocalDevices() {
        displayOptions = NSScreen.screens.compactMap { screen in screen.displayID.map { DisplayOption(id:$0,name:screen.localizedName) } }
        microphones = Recorder.microphoneDevices().map { MicrophoneDevice(id:$0.uniqueID,name:$0.localizedName) }
        if microphoneID != "off", microphoneID != "default", !microphones.contains(where: { $0.id == microphoneID }) { microphoneID = "off"; status = "Saved microphone not connected · microphone off" }
        if !displayOptions.contains(where: { $0.id == displayID }) { changeDisplay(displayOptions.first?.id ?? 0) }
    }
    func mutate(_ operation: (inout Project) -> Void) {
        let old = project; operation(&project)
        if old != project { history.append(old); if history.count > 100 { history.removeFirst() }; future = []; rebuild() }
    }
    func undo() { guard let value = history.popLast() else { return }; future.append(project); project = value; rebuild() }
    func redo() { guard let value = future.popLast() else { return }; history.append(project); project = value; rebuild() }
    func update(_ changed: Clip) { mutate { p in if let i = p.clips.firstIndex(where: { $0.id == changed.id }) { p.clips[i] = changed } } }
    func rebuild() {
        if !project.clips.contains(where: { $0.id == selected }) { selected = project.clips.first?.id }
        revision += 1; let token = revision; let snapshot = project
        previewTask?.cancel(); player.pause()
        if snapshot.clips.isEmpty { player.replaceCurrentItem(with: nil); playhead = 0; return }
        status = "Preparing preview…"
        previewTask = Task {
            do {
                let render = try await MediaEngine.compose(snapshot)
                guard !Task.isCancelled, token == revision else { return }
                let item = AVPlayerItem(asset: render.composition); item.videoComposition = render.video; item.audioMix = render.audio
                previewObserver = item.observe(\.status, options: [.new]) { [weak self] observed, _ in
                    guard observed.status == .failed else { return }
                    let message = observed.error?.localizedDescription ?? "Preview could not load this video."
                    Task { @MainActor [weak self] in self?.error = message }
                }
                let time = min(playhead, snapshot.duration)
                player.replaceCurrentItem(with: item); seek(time); status = "\(snapshot.clips.count) clips · \(timeLabel(snapshot.duration))"
            } catch { if !Task.isCancelled, token == revision { report(error) } }
        }
    }
    func seek(_ time: Double) { player.seek(to: CMTime(seconds: max(0,time), preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) }
    func split() {
        guard let index = project.clips.firstIndex(where: { $0.id == selected }) else { return }
        let start = project.clips.prefix(index).reduce(0) { $0+$1.duration }
        do { let pair = try project.clips[index].split(at: playhead-start); mutate { $0.clips.replaceSubrange(index...index, with: [pair.0,pair.1]) }; selected = pair.1.id } catch { report(error) }
    }
    func remove() { guard let id = selected else { return }; mutate { $0.clips.removeAll { $0.id == id } }; selected = project.clips.first?.id }
    func duplicate() { guard var value = clip, let i = project.clips.firstIndex(where: { $0.id == value.id }) else { return }; value.id = UUID(); mutate { $0.clips.insert(value, at: i+1) }; selected = value.id }
    func move(_ delta: Int) { guard let i = project.clips.firstIndex(where: { $0.id == selected }), project.clips.indices.contains(i+delta) else { return }; mutate { $0.clips.swapAt(i,i+delta) } }
    func importMedia() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.movie]; panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        let urls = panel.urls; busy = true
        Task { defer { busy = false }; do {
            var clips: [Clip] = []
            for url in urls { clips.append(try await MediaEngine.inspect(url)) }
            mutate { $0.clips.append(contentsOf: clips) }; selected = clips.last?.id
        } catch { report(error) } }
    }
    func save() {
        let panel = NSSavePanel(); panel.nameFieldStringValue = "Untitled.frameforge"; panel.allowedContentTypes = [UTType(filenameExtension: "frameforge") ?? .json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try project.validated(); let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted,.sortedKeys]; try encoder.encode(project).write(to: url, options: .atomic); status = "Project saved — source media stays in its original location" } catch { report(error) }
    }
    func open() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [UTType(filenameExtension: "frameforge") ?? .json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { let value = try JSONDecoder().decode(Project.self, from: Data(contentsOf: url)); try value.validated(); mutate { $0 = value }; selected = value.clips.first?.id } catch { report(error) }
    }
    func displayName(_ id: UInt32) -> String {
        NSScreen.screens.first { $0.displayID == id }?.localizedName ?? "Display \(id)"
    }
    var regionLabel: String {
        guard let region = region else { return "No region selected" }
        let size = CGDisplayBounds(displayID).size
        return "\(Int(region.width*size.width)) × \(Int(region.height*size.height)) points"
    }
    func changeDisplay(_ id: UInt32) { if displayID != id { displayID = id; region = nil } }
    func chooseRegion() async {
        guard !busy, !recording else { return }
        refreshLocalDevices()
        guard displayID != 0 else { return }
        busy = true; defer { busy = false }
        do { if let selected = try await regionSelector.select(displayIDs:[displayID],allowsFullScreen:false)?.region { region = selected; regionMode = true; status = "Region selected · \(regionLabel)" } } catch { report(error) }
    }
    /// Shortcut and menu-bar flow: while idle, pick a region or a whole screen on any display and
    /// start recording it; while recording, stop (and copy the movie when that setting is on).
    func toggleQuickCapture() async {
        if recording { await stopRecording(); return }
        guard !busy else { return }
        // Check before the picker so nobody frames a region only to be refused afterwards.
        error = nil
        guard CGPreflightScreenCaptureAccess() else { reportScreenCaptureDenied(); return }
        refreshLocalDevices()
        busy = true
        let target: CaptureTarget?
        do { target = try await regionSelector.select(displayIDs:displayOptions.map(\.id),allowsFullScreen:true) } catch { busy = false; report(error); return }
        busy = false
        guard let target = target else { return }
        displayID = target.displayID; region = target.region; regionMode = target.region != nil
        // Never brings the app forward: failures show as a warning in the menu bar instead.
        await startRecording()
    }
    func refreshDisplays() async {
        guard !recording else { return }
        refreshLocalDevices()
        do {
            let sources = try await Recorder.sources()
            displays = sources.displays; microphones = sources.microphones; audioApplications = sources.applications
            if !displays.contains(where: { $0.displayID == displayID }) { changeDisplay(displays.first?.displayID ?? 0) }
            if microphoneID != "off", microphoneID != "default", !microphones.contains(where: { $0.id == microphoneID }) { microphoneID = "off" }
            if audioApplicationID != 0, !audioApplications.contains(where: { $0.id == audioApplicationID }) { audioApplicationID = 0 }
            status = "Recording sources refreshed"
        } catch { report(error) }
    }
    func startRecording() async {
        guard !busy, !recording else { return }
        if regionMode && region == nil { await chooseRegion(); guard region != nil else { return } }
        player.pause()
        busy = true; defer { busy = false }
        do {
            if !displays.contains(where: { $0.displayID == displayID }) {
                let sources = try await Recorder.sources(); displays = sources.displays; audioApplications = sources.applications
            }
            guard let display = displays.first(where: { $0.displayID == displayID }) else { throw ForgeError.message("Choose a display after granting Screen Recording access.") }
            let directory = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0].appendingPathComponent("FrameForge")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent("Recording-\(UUID().uuidString.prefix(8)).mov")
            try await recorder.start(display: display, region: regionMode ? region : nil, maximumDimension: maximumCaptureDimension, url: url, fps: captureFPS, systemAudio: systemAudio, audioApplication: audioApplicationID == 0 ? nil : audioApplicationID, microphoneID: microphoneID == "off" ? nil : microphoneID, microphoneGain: microphoneGain, trackMouse: trackMouse, cursor: showCursor)
            microphoneLevelDB = -120; microphoneOverload = false
            recordingURL = url; recording = true; status = "Recording · \(recordingShortcutHint)"
            recordingSeconds = 0; recordingBegan = Date()
            recordingTimer = Timer.scheduledTimer(withTimeInterval:0.25, repeats:true) { [weak self] _ in
                guard let owner = self else { return }
                Task { @MainActor in owner.recordingSeconds = owner.recordingBegan.map { Date().timeIntervalSince($0) } ?? 0 }
            }
        } catch { report(error) }
    }
    func stopRecording() async {
        guard recording else { return }; busy = true; recording = false
        recordingTimer?.invalidate(); recordingTimer = nil; recordingBegan = nil
        defer { busy = false }
        do { try await recorder.stop(); if let url = recordingURL { let value = try await MediaEngine.inspect(url); mutate { $0.clips.append(value) }; selected = value.id; status = "Recording saved · \(recorder.summary)"
                if copyRecordingToClipboard {
                    status = "Preparing video for the clipboard…"
                    let shared = try await ShareCopy.make(from:url)
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    if pasteboard.writeObjects([shared as NSURL]) { status = "Recording copied to clipboard · paste to attach the video" }
                    else { status = "Recording saved; clipboard copy failed · \(shared.lastPathComponent)" }
                } } } catch { report(error) }
        recordingURL = nil
    }
    func export(hevc: Bool) {
        let panel = NSSavePanel(); panel.nameFieldStringValue = "FrameForge.mp4"; panel.allowedContentTypes = [.mpeg4Movie]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let snapshot = project; busy = true; exporting = true; progress = 0
        Task {
            defer { busy = false; exporting = false; exportSession = nil }
            var timer: Timer?
            defer { timer?.invalidate() }
            do {
                let render = try await MediaEngine.compose(snapshot)
                guard let session = AVAssetExportSession(asset: render.composition, presetName: hevc ? AVAssetExportPresetHEVCHighestQuality : AVAssetExportPresetHighestQuality) else { throw ForgeError.message("Selected encoder unavailable.") }
                exportSession = session
                // Encode to a sibling temp file, preserving an existing destination on failure.
                let temporary = url.deletingLastPathComponent().appendingPathComponent(".frameforge-\(UUID().uuidString).mp4")
                defer { try? FileManager.default.removeItem(at: temporary) }
                session.outputURL = temporary; session.outputFileType = .mp4; session.shouldOptimizeForNetworkUse = true
                session.videoComposition = render.video; session.audioMix = render.audio
                status = "Exporting…"
                timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
                    guard let owner = self else { return }
                    Task { @MainActor in owner.progress = session.progress }
                }
                await session.export()
                if session.status == .cancelled { status = "Export cancelled"; return }
                guard session.status == .completed else { throw session.error ?? ForgeError.message("Export failed.") }
                if FileManager.default.fileExists(atPath: url.path) { _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary) }
                else { try FileManager.default.moveItem(at: temporary, to: url) }
                progress = 1; status = "Export complete"; NSWorkspace.shared.activateFileViewerSelecting([url])
            } catch { report(error) }
        }
    }
    func setMicrophoneGain(_ gain: Double) { microphoneGain = min(1,max(0,gain)); recorder.setMicrophoneGain(microphoneGain) }
    func analyzeSilence(sourceIndex: Int,thresholdDB: Double,minimumSilence: Double) {
        guard !busy, !recording, let clip = clip else { return }
        busy = true; analysisProgress = 0; player.pause(); status = "Analyzing silence…"
        Task {
            defer { busy = false }
            do {
                let proposal = try await SilenceDetector.analyze(clip:clip,sourceIndex:sourceIndex,thresholdDB:thresholdDB,minimumSilence:minimumSilence,padding:0.15) { [weak self] fraction in
                    guard let owner = self else { return }
                    Task { @MainActor in owner.analysisProgress = fraction }
                }
                silenceProposal = proposal; status = "Review proposed silence cuts"
            } catch { report(error) }
        }
    }
    func applySilence(_ proposal: SilenceProposal) {
        guard let index = project.clips.firstIndex(where:{ $0.id == proposal.original.id }), project.clips[index] == proposal.original else { report(ForgeError.message("The clip changed after analysis. Analyze it again.")); return }
        mutate { $0.clips.replaceSubrange(index...index,with:proposal.replacements) }
        selected = proposal.replacements.first?.id; silenceProposal = nil
    }
    func cancelExport() { exportSession?.cancelExport() }
}
