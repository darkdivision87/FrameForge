import ScreenCaptureKit
import AVFoundation
import AppKit
import VideoToolbox

struct DisplayOption: Identifiable { let id: UInt32; let name: String }
struct MicrophoneDevice: Identifiable { let id: String; let name: String }
struct AudioApplication: Identifiable { let id: Int32; let name: String }
struct CaptureSources { let displays: [SCDisplay]; let microphones: [MicrophoneDevice]; let applications: [AudioApplication] }

final class Recorder: NSObject, SCStreamOutput, SCStreamDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    // Every writer operation and all sample state live on this queue.
    private let queue = DispatchQueue(label: "app.frameforge.capture", qos: .userInitiated)
    private let sessionQueue = DispatchQueue(label: "app.frameforge.microphone", qos: .userInitiated)
    private var stream: SCStream?
    private var applicationStream: SCStream?
    private var microphoneSession: AVCaptureSession?
    private var microphoneClock: CMClock?
    private var microphoneProcessor = MicrophoneProcessor()
    private var microphoneGain: Float = 0.5
    private var microphonePeakDB = -120.0
    private var microphoneClipped = 0
    private var meterTime = 0.0
    private var microphoneName: String?
    private var cursorTimer: DispatchSourceTimer?
    private var cursorSamples: [CursorSample] = []
    private var captureRect = CGRect.zero
    private var capturedAudioNames: [String] = []
    private var microphoneObserver: NSObjectProtocol?
    private var writer: AVAssetWriter?
    private var video: AVAssetWriterInput?
    private var audio: AVAssetWriterInput?
    private var microphone: AVAssetWriterInput?
    private var started = false
    private var accepting = false
    private var failure: Error?
    private var firstVideoTime = CMTime.invalid
    private var lastVideoTime = CMTime.invalid
    private var lastFrame: CMSampleBuffer?
    private var frames = 0
    private var audioDrops = 0
    private var frameDuration = CMTime(value:1,timescale:30)
    private(set) var droppedFrames = 0
    private(set) var summary = ""
    var onMicrophoneLevel: ((MicrophoneLevel) -> Void)?
    func setMicrophoneGain(_ gain: Double) { queue.async { self.microphoneGain = Float(max(0,min(1,gain))) } }
    var onFailure: ((Error) -> Void)?

    static func microphoneDevices() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(deviceTypes:[.builtInMicrophone,.externalUnknown],mediaType:.audio,position:.unspecified).devices
    }
    static func sources() async throws -> CaptureSources {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        return CaptureSources(displays:content.displays,
            microphones:microphoneDevices().map { MicrophoneDevice(id:$0.uniqueID,name:$0.localizedName) },
            applications:content.applications.filter { $0.processID != ProcessInfo.processInfo.processIdentifier }.map { AudioApplication(id:$0.processID,name:$0.applicationName) }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending })
    }
    private func audioInput(name: String, channels: Int) -> AVAssetWriterInput {
        let input = AVAssetWriterInput(mediaType:.audio, outputSettings:[AVFormatIDKey:kAudioFormatMPEG4AAC,AVSampleRateKey:48000,AVNumberOfChannelsKey:channels,AVEncoderBitRateKey:channels == 1 ? 96000 : 192000])
        input.expectsMediaDataInRealTime = true
        let title = AVMutableMetadataItem(); title.identifier = .commonIdentifierTitle; title.value = name as NSString
        input.metadata = [title]
        return input
    }
    func start(display: SCDisplay, region: CGRect?, maximumDimension: Int, url: URL, fps: Int, systemAudio: Bool, audioApplication: Int32?, microphoneID: String?, microphoneGain: Double, trackMouse: Bool, cursor: Bool) async throws {
        if microphoneID != nil {
            let allowed = await AVCaptureDevice.requestAccess(for:.audio)
            guard allowed else { throw ForgeError.message("Microphone access is disabled. Enable FrameForge in System Settings → Privacy & Security → Microphone, or choose Microphone Off.") }
        }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly:true)
        guard let currentDisplay = content.displays.first(where: { $0.displayID == display.displayID }) else { throw ForgeError.message("Display disconnected. Refresh sources.") }
        let excluded = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        let filter = SCContentFilter(display:currentDisplay,excludingApplications:excluded,exceptingWindows:[])
        let bounds = CGDisplayBounds(currentDisplay.displayID)
        let source = try CaptureGeometry.sourceRect(region, logicalSize:bounds.size)
        let mode = CGDisplayCopyDisplayMode(currentDisplay.displayID)
        let scale = mode.map { CGFloat($0.pixelWidth)/bounds.width } ?? 1
        let output = CaptureGeometry.outputSize(source:source.size,scale:scale,maximumDimension:maximumDimension)
        let config = SCStreamConfiguration()
        config.sourceRect = source
        config.width = Int(output.width); config.height = Int(output.height)
        // Avoid RGB-to-YUV conversion and large RGB surfaces during live capture.
        config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        config.minimumFrameInterval = CMTime(value:1,timescale:Int32(fps)); config.queueDepth = 5; config.showsCursor = cursor
        config.capturesAudio = systemAudio && audioApplication == nil; config.excludesCurrentProcessAudio = true
        config.sampleRate = 48000; config.channelCount = 2
        let writer = try AVAssetWriter(outputURL:url,fileType:.mov)
        let video = AVAssetWriterInput(mediaType:.video,outputSettings:[AVVideoCodecKey:AVVideoCodecType.h264,AVVideoWidthKey:config.width,AVVideoHeightKey:config.height,AVVideoEncoderSpecificationKey:[kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder as String:true],AVVideoCompressionPropertiesKey:[AVVideoAllowFrameReorderingKey:false,AVVideoAverageBitRateKey:max(4_000_000,min(60_000_000,config.width*config.height*6)),AVVideoExpectedSourceFrameRateKey:fps] as [String:Any]])
        video.expectsMediaDataInRealTime = true
        guard writer.canAdd(video) else { throw ForgeError.message("Video encoder unavailable. Choose 1080p or 4K recording resolution.") }; writer.add(video)
        let audio = systemAudio ? audioInput(name:"System Audio",channels:2) : nil
        let microphone: AVAssetWriterInput?
        if microphoneID != nil {
            let input = AVAssetWriterInput(mediaType:.audio,outputSettings:MicrophoneProcessor.settings)
            input.expectsMediaDataInRealTime = true
            let title = AVMutableMetadataItem(); title.identifier = .commonIdentifierTitle; title.value = "Microphone" as NSString
            input.metadata = [title]; microphone = input
        } else { microphone = nil }
        for input in [audio,microphone].compactMap({ $0 }) {
            guard writer.canAdd(input) else { throw ForgeError.message("Audio encoder unavailable.") }; writer.add(input)
        }
        let stream = SCStream(filter:filter,configuration:config,delegate:self)
        try stream.addStreamOutput(self,type:.screen,sampleHandlerQueue:queue)
        if config.capturesAudio { try stream.addStreamOutput(self,type:.audio,sampleHandlerQueue:queue) }
        var appStream: SCStream?
        if systemAudio, let pid = audioApplication {
            guard let app = content.applications.first(where: { $0.processID == pid }) else { throw ForgeError.message("Selected audio application has quit. Refresh sources or select all system audio.") }
            // Separate audio-only stream: selecting an app does not crop the recorded display.
            let audioFilter = SCContentFilter(display:currentDisplay,including:[app],exceptingWindows:[])
            let audioConfig = SCStreamConfiguration()
            audioConfig.width = 16; audioConfig.height = 16; audioConfig.queueDepth = 3
            audioConfig.capturesAudio = true; audioConfig.excludesCurrentProcessAudio = true
            audioConfig.sampleRate = 48000; audioConfig.channelCount = 2
            appStream = SCStream(filter:audioFilter,configuration:audioConfig,delegate:self)
            try appStream?.addStreamOutput(self,type:.audio,sampleHandlerQueue:queue)
        }
        self.stream = stream; self.applicationStream = appStream
        do {
            if let id = microphoneID { try await configureMicrophone(id:id) }
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void,Error>) in
                queue.async {
                    self.writer = writer; self.video = video; self.audio = audio; self.microphone = microphone
                    self.started = false; self.failure = nil; self.lastFrame = nil; self.frames = 0
                    self.microphoneGain = Float(min(1,max(0,microphoneGain))); self.microphoneProcessor.reset()
                    self.microphonePeakDB = -120; self.microphoneClipped = 0; self.meterTime = 0
                    self.cursorSamples = []; self.captureRect = CGRect(x:bounds.minX+source.minX,y:bounds.minY+source.minY,width:source.width,height:source.height)
                    self.capturedAudioNames = (audio != nil ? ["System Audio"] : []) + (microphone != nil ? ["Microphone"] : []); self.droppedFrames = 0; self.audioDrops = 0
                    self.firstVideoTime = .invalid; self.lastVideoTime = .invalid; self.frameDuration = CMTime(value:1,timescale:Int32(fps))
                    guard writer.startWriting() else { continuation.resume(throwing:writer.error ?? ForgeError.message("Encoder could not start. Try 1080p recording resolution.")); return }
                    self.accepting = true; continuation.resume()
                }
            }
            try await stream.startCapture()
            try await appStream?.startCapture()
            if let session = microphoneSession {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void,Never>) in
                    sessionQueue.async { session.startRunning(); self.queue.sync { self.microphoneClock = session.synchronizationClock }; continuation.resume() }
                }
            }
            if microphoneSession != nil, microphoneClock == nil { throw ForgeError.message("Microphone synchronization clock unavailable. Choose another input.") }
            try await withCheckedThrowingContinuation { (continuation:CheckedContinuation<Void,Error>) in
                queue.async { if let error = self.failure { continuation.resume(throwing:error) } else { continuation.resume() } }
            }
            if trackMouse {
                queue.async {
                    let timer = DispatchSource.makeTimerSource(queue:self.queue)
                    timer.schedule(deadline:.now(),repeating:.milliseconds(50),leeway:.milliseconds(10))
                    timer.setEventHandler { [weak self] in
                        guard let self = self, self.accepting, self.started,
                              let event = CGEvent(source:nil), self.cursorSamples.count < 500000 else { return }
                        let time = (CMClockGetTime(CMClockGetHostTimeClock())-self.firstVideoTime).seconds
                        let point = event.location; let rect = self.captureRect
                        self.cursorSamples.append(CursorSample(time:max(0,time),x:(point.x-rect.minX)/rect.width,y:(point.y-rect.minY)/rect.height,pressed:CGEventSource.buttonState(.combinedSessionState,button:.left),inside:rect.contains(point)))
                    }
                    self.cursorTimer = timer; timer.resume()
                }
            }
            let generation = writer
            queue.asyncAfter(deadline:.now()+8) { [weak self] in
                guard let self = self, self.writer === generation, self.accepting, !self.started else { return }
                self.fail(ForgeError.message("No video frames received. Check Screen Recording access and restart FrameForge if access was just granted."))
            }
        } catch {
            try? await stream.stopCapture(); try? await appStream?.stopCapture()
            await stopMicrophone()
            await withCheckedContinuation { (continuation:CheckedContinuation<Void,Never>) in
                queue.async { self.accepting = false; self.cursorTimer?.cancel(); self.cursorTimer = nil; writer.cancelWriting(); self.writer = nil; self.video = nil; self.audio = nil; self.microphone = nil; continuation.resume() }
            }
            self.stream = nil; applicationStream = nil
            throw error
        }
    }
    private func configureMicrophone(id: String) async throws {
        try await withCheckedThrowingContinuation { (continuation:CheckedContinuation<Void,Error>) in
            sessionQueue.async {
                do {
                    let device: AVCaptureDevice?
                    if id == "default" { device = AVCaptureDevice.default(for:.audio) }
                    else { device = Self.microphoneDevices().first { $0.uniqueID == id } }
                    guard let device = device else { throw ForgeError.message("Microphone disconnected. Refresh sources and choose another input.") }
                    let session = AVCaptureSession(); session.beginConfiguration()
                    let input = try AVCaptureDeviceInput(device:device)
                    guard session.canAddInput(input) else { throw ForgeError.message("Cannot use this microphone.") }
                    session.addInput(input)
                    let output = AVCaptureAudioDataOutput()
                    output.audioSettings = MicrophoneProcessor.settings
                    self.microphoneName = device.localizedName
                    guard session.canAddOutput(output) else { throw ForgeError.message("Cannot read microphone audio.") }
                    session.addOutput(output); output.setSampleBufferDelegate(self,queue:self.queue)
                    session.commitConfiguration()
                    self.queue.sync { self.microphoneClock = session.synchronizationClock }
                    self.microphoneSession = session
                    self.microphoneObserver = NotificationCenter.default.addObserver(forName:.AVCaptureSessionRuntimeError,object:session,queue:nil) { [weak self] note in
                        let error = note.userInfo?[AVCaptureSessionErrorKey] as? Error ?? ForgeError.message("Microphone capture failed.")
                        self?.queue.async { [weak self] in self?.fail(error) }
                    }
                    continuation.resume()
                } catch { continuation.resume(throwing:error) }
            }
        }
    }
    private func stopMicrophone() async {
        await withCheckedContinuation { (continuation:CheckedContinuation<Void,Never>) in
            sessionQueue.async {
                self.microphoneSession?.stopRunning(); self.microphoneSession = nil
                if let observer = self.microphoneObserver { NotificationCenter.default.removeObserver(observer); self.microphoneObserver = nil }
                continuation.resume()
            }
        }
    }
    private func fail(_ error: Error) {
        guard failure == nil else { return }
        failure = error; accepting = false
        DispatchQueue.main.async { [weak self] in self?.onFailure?(error) }
    }
    func stream(_ stream: SCStream,didOutputSampleBuffer sample: CMSampleBuffer,of type: SCStreamOutputType) {
        guard accepting, sample.isValid, CMSampleBufferDataIsReady(sample), let writer = writer else { return }
        if type == .screen {
            guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sample,createIfNecessary:false) as? [[SCStreamFrameInfo:Any]], let raw = attachments.first?[.status] as? Int, let status = SCFrameStatus(rawValue:raw) else { return }
            let timestamp = sample.presentationTimeStamp
            guard timestamp.isNumeric else { return }
            let frame: CMSampleBuffer
            if status == .complete { frame = sample; lastFrame = sample }
            else { return }
            if !started { writer.startSession(atSourceTime:timestamp); firstVideoTime = timestamp; started = true }
            if video?.isReadyForMoreMediaData == true {
                if video?.append(frame) == false { fail(writer.error ?? ForgeError.message("Video encoding failed. Try 1080p capture resolution.")) }
                else { frames += 1; lastVideoTime = timestamp }
            } else { droppedFrames += 1 }
        } else if type == .audio { appendAudio(sample,to:audio) }
    }
    private func repeatedFrame(_ sample: CMSampleBuffer,at timestamp: CMTime) -> CMSampleBuffer? {
        var timing = CMSampleTimingInfo(duration:frameDuration,presentationTimeStamp:timestamp,decodeTimeStamp:.invalid)
        var copy: CMSampleBuffer?
        guard CMSampleBufferCreateCopyWithNewTiming(allocator:kCFAllocatorDefault,sampleBuffer:sample,sampleTimingEntryCount:1,sampleTimingArray:&timing,sampleBufferOut:&copy) == noErr else { return nil }
        return copy
    }
    private func appendAudio(_ sample: CMSampleBuffer,to input: AVAssetWriterInput?) {
        guard accepting, started, sample.isValid, sample.presentationTimeStamp >= firstVideoTime, let input = input else { return }
        guard input.isReadyForMoreMediaData else { audioDrops += 1; return }
        if !input.append(sample) { fail(writer?.error ?? ForgeError.message("Audio encoding failed.")) }
    }
    func captureOutput(_ output: AVCaptureOutput,didOutput sample: CMSampleBuffer,from connection: AVCaptureConnection) {
        guard accepting, started, let clock = microphoneClock else { return }
        let timestamp = CMSyncConvertTime(sample.presentationTimeStamp,from:clock,to:CMClockGetHostTimeClock())
        guard timestamp.isNumeric else { fail(ForgeError.message("Microphone timestamp conversion failed.")); return }
        do {
            let (converted,level) = try microphoneProcessor.process(sample,timestamp:timestamp,gain:microphoneGain)
            microphonePeakDB = max(microphonePeakDB,level.peakDB); microphoneClipped += level.clipped
            let now = CMClockGetTime(CMClockGetHostTimeClock()).seconds
            if now-meterTime > 0.2 {
                meterTime = now
                DispatchQueue.main.async { [weak self] in self?.onMicrophoneLevel?(level) }
            }
            appendAudio(converted,to:microphone)
        } catch { fail(error) }
    }
    func stream(_ stream: SCStream,didStopWithError error: Error) { queue.async { self.fail(error) } }
    func stop() async throws {
        let stoppedAt = CMClockGetTime(CMClockGetHostTimeClock())
        var stopError: Error?
        do { try await stream?.stopCapture() } catch { stopError = error }
        do { try await applicationStream?.stopCapture() } catch { stopError = stopError ?? error }
        stream = nil; applicationStream = nil
        await stopMicrophone()
        let state: (AVAssetWriter?,Bool,Error?) = await withCheckedContinuation { continuation in
            queue.async {
                self.accepting = false; self.cursorTimer?.cancel(); self.cursorTimer = nil
                if self.started, self.writer?.status == .writing {
                    // An unchanged desktop must retain its full wall-clock duration.
                    // Skip encoding idle duplicates; close the final static span at stop.
                    let finalTime = stoppedAt - self.frameDuration
                    if finalTime > self.lastVideoTime, let previous = self.lastFrame,
                       let finalFrame = self.repeatedFrame(previous,at:finalTime), let video = self.video, video.isReadyForMoreMediaData {
                        if video.append(finalFrame) { self.lastVideoTime = finalTime; self.frames += 1 }
                        else { self.failure = self.failure ?? self.writer?.error }
                    }
                    self.writer?.endSession(atSourceTime:CMTimeMaximum(stoppedAt,self.lastVideoTime+self.frameDuration))
                    self.video?.markAsFinished(); self.audio?.markAsFinished(); self.microphone?.markAsFinished()
                }
                self.summary = "\(self.frames) frames · \(self.droppedFrames) video drops · \(self.audioDrops) audio drops"
                continuation.resume(returning:(self.writer,self.started,self.failure))
            }
        }
        guard let writer = state.0 else { throw ForgeError.message("Recording is not active.") }
        if !state.1 { writer.cancelWriting() }
        else if writer.status == .writing { await writer.finishWriting() }
        await withCheckedContinuation { (continuation:CheckedContinuation<Void,Never>) in
            queue.async { self.writer = nil; self.video = nil; self.audio = nil; self.microphone = nil; self.microphoneClock = nil; self.lastFrame = nil; continuation.resume() }
        }
        if let error = state.2 ?? writer.error ?? stopError { throw error }
        guard state.1, writer.status == .completed else { throw ForgeError.message("No recording was finalized. Check Screen Recording access.") }
        let metadata = CaptureMetadata(audioNames:capturedAudioNames,cursor:cursorSamples,microphoneDevice:microphoneName,microphonePeakDB:capturedAudioNames.contains("Microphone") ? microphonePeakDB : nil,clippedMicrophoneSamples:capturedAudioNames.contains("Microphone") ? microphoneClipped : nil)
        let data = try JSONEncoder().encode(metadata)
        try data.write(to:CaptureMetadata.url(for:writer.outputURL),options:.atomic)
        if microphoneClipped > 0 { summary += " · microphone input clipped: lower the device input gain" }
    }
}
