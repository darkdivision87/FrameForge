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
    @Published var systemAudio = true
    @Published var audioApplicationID: Int32 = 0
    @Published var audioApplications: [AudioApplication] = []
    @Published var microphones: [MicrophoneDevice] = []
    @Published var microphoneID = UserDefaults.standard.string(forKey:"microphoneSelection") ?? "auto" {
        didSet { UserDefaults.standard.set(microphoneID,forKey:"microphoneSelection") }
    }
    private var preferredUSBMicrophone = UserDefaults.standard.string(forKey:"preferredUSBMicrophone")
    private var deviceObservers: [NSObjectProtocol] = []
    private let recordingVisibility = CaptureWindowVisibility()
    @Published var rangeIn: Double?
    @Published var rangeOut: Double?
    @Published var region: CGRect?
    @Published var regionMode = false
    @Published var maximumCaptureDimension = 3840
    @Published var recordingSeconds = 0.0
    private let regionSelector = RegionSelector()
    private var recordingTimer: Timer?
    private var recordingBegan: Date?
    private var previewObserver: NSKeyValueObservation?
    @Published var showCursor = true
    @Published var trackMouse = false
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
        for name in [AVCaptureDevice.wasConnectedNotification, AVCaptureDevice.wasDisconnectedNotification] {
            deviceObservers.append(NotificationCenter.default.addObserver(forName:name,object:nil,queue:.main) { [weak self] _ in
                Task { @MainActor in guard let self = self, !self.recording else { return }; self.refreshLocalDevices() }
            })
        }
        observer = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.1, preferredTimescale: 600), queue: .main) { [weak self] time in
            Task { @MainActor in self?.playhead = time.seconds.isFinite ? time.seconds : 0 }
        }
        hotKey = GlobalHotKey { [weak self] in
            Task { @MainActor in
                guard let self = self, !self.busy else { return }
                if self.recording { await self.stopRecording() } else { await self.startRecording(selectRegion:true) }
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
    var recordingShortcutHint: String { hotKey?.isRegistered == true ? "select region & record / stop ⇧⌘S" : "stop from the menu bar (global shortcut unavailable)" }
    func report(_ error: Error) {
        let nsError = error as NSError
        if nsError.domain == SCStreamErrorDomain && nsError.code == -3801 {
            self.error = "macOS has not allowed screen capture for this build. Enable FrameForge in System Settings → Privacy & Security → Screen & System Audio Recording (Screen Recording on older macOS), then quit and reopen FrameForge. If the previous build is listed, add this updated app using the + button."
        } else { self.error = error.localizedDescription }
        status = "Action failed"
    }
    func refreshLocalDevices() {
        displayOptions = NSScreen.screens.compactMap { screen in
            guard let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value else { return nil }
            return DisplayOption(id:id,name:screen.localizedName)
        }
        microphones = Recorder.microphoneOptions()
        if microphoneID != "auto", microphoneID != "off", microphoneID != "default", !microphones.contains(where: { $0.id == microphoneID }) { microphoneID = "auto" }
        if !displayOptions.contains(where: { $0.id == displayID }) { changeDisplay(displayOptions.first?.id ?? 0) }
    }
    deinit { deviceObservers.forEach { NotificationCenter.default.removeObserver($0) } }
    var resolvedMicrophoneID: String? {
        if microphoneID == "off" { return nil }
        if microphoneID == "auto" { return MicrophoneDevice.automaticID(in:microphones,preferred:preferredUSBMicrophone) }
        return microphoneID
    }
    var automaticMicrophoneLabel: String {
        let id = MicrophoneDevice.automaticID(in:microphones,preferred:preferredUSBMicrophone)
        return id.flatMap { id in microphones.first { $0.id == id }?.name } ?? "no USB microphone"
    }
    var canRemoveRange: Bool {
        guard let lower = rangeIn, let upper = rangeOut else { return false }
        return lower.isFinite && upper.isFinite && lower >= 0 && upper > lower && upper <= project.duration
    }
    func markIn() { rangeIn = min(project.duration,max(0,playhead)) }
    func markOut() { rangeOut = min(project.duration,max(0,playhead)) }
    func clearRange() { rangeIn = nil; rangeOut = nil }
    func removeRange() {
        guard canRemoveRange, !busy, !recording, let lower = rangeIn, let upper = rangeOut else { return }
        do {
            let edited = try project.removingRange(from:lower,to:upper)
            player.pause(); playhead = lower
            mutate { $0 = edited }
            status = "Removed \(timeLabel(upper-lower)) · gap closed · Undo restores the cut"
        } catch { report(error) }
    }
    func mutate(_ operation: (inout Project) -> Void) {
        let old = project; operation(&project)
        if old != project { clearRange(); history.append(old); if history.count > 100 { history.removeFirst() }; future = []; rebuild() }
    }
    func undo() { guard let value = history.popLast() else { return }; future.append(project); project = value; rebuild() }
    func redo() { guard let value = future.popLast() else { return }; history.append(project); project = value; rebuild() }
    func update(_ changed: Clip) { mutate { p in if let i = p.clips.firstIndex(where: { $0.id == changed.id }) { p.clips[i] = changed } } }
    func rebuild() {
        clearRange()
        playhead = min(playhead,project.duration)
        if !project.clips.contains(where: { $0.id == selected }) { selected = project.clips.first?.id }
        revision += 1; let token = revision; let snapshot = project; let previewTime = playhead
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
                let time = min(previewTime, snapshot.duration)
                player.replaceCurrentItem(with: item); seek(time); status = "\(snapshot.clips.count) clips · \(timeLabel(snapshot.duration))"
            } catch { if !Task.isCancelled, token == revision { report(error) } }
        }
    }
    func seek(_ time: Double) {
        playhead = min(project.duration,max(0,time))
        player.seek(to: CMTime(seconds: playhead, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }
    func split() {
        var start = 0.0
        guard let index = project.clips.indices.first(where: { index in
            let end = start + project.clips[index].duration
            if playhead >= start && playhead < end { return true }
            start = end; return false
        }) else { return }
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
        NSScreen.screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id }?.localizedName ?? "Display \(id)"
    }
    var regionLabel: String {
        guard let region = region else { return "No region selected" }
        let size = CGDisplayBounds(displayID).size
        return "\(Int(region.width*size.width)) × \(Int(region.height*size.height)) points"
    }
    func changeDisplay(_ id: UInt32) { if displayID != id { displayID = id; region = nil } }
    @discardableResult func chooseRegion() async -> Bool {
        guard !busy, !recording else { return false }
        refreshLocalDevices()
        guard displayID != 0 else { return false }
        busy = true; defer { busy = false }
        do {
            guard let selected = try await regionSelector.select(displayID:displayID) else { return false }
            region = selected; regionMode = true; status = "Region selected · \(regionLabel)"
            return true
        } catch { report(error); return false }
    }
    func refreshDisplays() async {
        guard !recording else { return }
        refreshLocalDevices()
        do {
            let sources = try await Recorder.sources()
            displays = sources.displays; microphones = sources.microphones; audioApplications = sources.applications
            if !displays.contains(where: { $0.displayID == displayID }) { changeDisplay(displays.first?.displayID ?? 0) }
            if microphoneID != "auto", microphoneID != "off", microphoneID != "default", !microphones.contains(where: { $0.id == microphoneID }) { microphoneID = "off" }
            if audioApplicationID != 0, !audioApplications.contains(where: { $0.id == audioApplicationID }) { audioApplicationID = 0 }
            status = "Recording sources refreshed"
        } catch { report(error) }
    }
    func startRecording(selectRegion: Bool = false) async {
        guard !busy, !recording else { return }
        if selectRegion || (regionMode && region == nil) { guard await chooseRegion() else { return } }
        refreshLocalDevices()
        let inputID = resolvedMicrophoneID
        if let inputID = inputID, microphones.contains(where: { $0.id == inputID && $0.isUSB }) {
            preferredUSBMicrophone = inputID
            UserDefaults.standard.set(inputID,forKey:"preferredUSBMicrophone")
        }
        player.pause()
        busy = true
        recordingVisibility.hide()
        defer { busy = false; if !recording { recordingVisibility.restore() } }
        await Task.yield()
        do {
            if displays.isEmpty {
                let sources = try await Recorder.sources(); displays = sources.displays; audioApplications = sources.applications
            }
            guard let display = displays.first(where: { $0.displayID == displayID }) else { throw ForgeError.message("Choose a display after granting Screen Recording access.") }
            let directory = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0].appendingPathComponent("FrameForge")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent("Recording-\(UUID().uuidString.prefix(8)).mov")
            try await recorder.start(display: display, region: regionMode ? region : nil, maximumDimension: maximumCaptureDimension, url: url, fps: captureFPS, systemAudio: systemAudio, audioApplication: audioApplicationID == 0 ? nil : audioApplicationID, microphoneID: inputID, microphoneGain: microphoneGain, trackMouse: trackMouse, cursor: showCursor)
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
        defer { busy = false; recordingVisibility.restore(); refreshLocalDevices() }
        do { try await recorder.stop(); if let url = recordingURL { let value = try await MediaEngine.inspect(url); playhead = project.duration; mutate { $0.clips.append(value) }; selected = value.id; status = "Recording saved · \(recorder.summary)"
                if copyRecordingToClipboard {
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    if pasteboard.writeObjects([url as NSURL]) { status = "Recording copied to clipboard · paste to attach the video" }
                    else { status = "Recording saved; clipboard copy failed · \(url.lastPathComponent)" }
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
