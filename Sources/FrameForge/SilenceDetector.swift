import AVFoundation

struct SilenceProposal: Identifiable {
    let id = UUID()
    let original: Clip
    let replacements: [Clip]
    let sourceName: String
    var removedDuration: Double { original.duration-replacements.reduce(0) { $0+$1.duration } }
}
enum SilenceDetector {
    static func analyze(clip: Clip,sourceIndex: Int,thresholdDB: Double,minimumSilence: Double,padding: Double,progress: @escaping (Double) -> Void) async throws -> SilenceProposal {
        try clip.validated()
        let asset = AVURLAsset(url:URL(fileURLWithPath:clip.path))
        let tracks = try await asset.loadTracks(withMediaType:.audio)
        guard !tracks.isEmpty else { throw ForgeError.message("This clip has no audio to analyze.") }
        let automatic = clip.audioNames?.firstIndex(where: { $0.lowercased().contains("microphone") }) ?? 0
        let index = sourceIndex < 0 ? automatic : sourceIndex
        guard tracks.indices.contains(index) else { throw ForgeError.message("Selected audio source is unavailable.") }
        let reader = try AVAssetReader(asset:asset)
        let output = AVAssetReaderTrackOutput(track:tracks[index],outputSettings:MicrophoneProcessor.settings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw ForgeError.message("This audio source cannot be decoded.") }
        reader.add(output)
        reader.timeRange = CMTimeRange(start:CMTime(seconds:clip.start,preferredTimescale:60000),end:CMTime(seconds:clip.end,preferredTimescale:60000))
        guard reader.startReading() else { throw reader.error ?? ForgeError.message("Audio analysis could not start.") }
        defer { reader.cancelReading() }
        let threshold = pow(10,thresholdDB/20)
        var voice: [SpeechRange] = []
        var windowStart: Double?; var energy = 0.0; var count = 0; var previousEnd: Double?
        var lastProgress = -1.0
        func flush() {
            guard let start = windowStart, count > 0 else { return }
            if sqrt(energy/Double(count)) >= threshold { voice.append(SpeechRange(start:start,end:start+Double(count)/48000)) }
            windowStart = nil; energy = 0; count = 0
        }
        while let sample = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            guard let block = sample.dataBuffer else { continue }
            let bytes = CMBlockBufferGetDataLength(block)
            guard bytes % 4 == 0 else { throw ForgeError.message("Decoded audio did not match the requested Float32 format.") }
            var values = [Float](repeating:0,count:bytes/4)
            let copied = values.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block,atOffset:0,dataLength:bytes,destination:$0.baseAddress!) }
            guard copied == noErr else { throw ForgeError.message("Could not read decoded audio.") }
            let time = sample.presentationTimeStamp.seconds
            guard time.isFinite else { continue }
            if let end = previousEnd, abs(time-end) > 0.05 { flush() }
            for (i,value) in values.enumerated() {
                let t = time+Double(i)/48000
                guard t >= clip.start, t < clip.end else { continue }
                if windowStart == nil { windowStart = t }
                let finite = value.isFinite ? Double(value) : 0
                energy += finite*finite; count += 1
                if count == 960 { flush() }
            }
            previousEnd = time+Double(values.count)/48000
            let fraction = min(1,max(0,(time-clip.start)/(clip.end-clip.start)))
            if fraction-lastProgress >= 0.02 { progress(fraction); lastProgress = fraction }
        }
        flush()
        guard reader.status == .completed else { throw reader.error ?? ForgeError.message("Audio analysis was interrupted.") }
        let ranges = SilencePlan.keptRanges(voice:voice,start:clip.start,end:clip.end,minimumSilence:minimumSilence,padding:padding)
        guard !ranges.isEmpty else { throw ForgeError.message("No audio exceeded the threshold. Nothing was cut. Lower the threshold or choose a different source.") }
        let edited = SilencePlan.clips(from:clip,ranges:ranges)
        let sourceName = clip.audioNames.flatMap { index < $0.count ? $0[index] : nil } ?? "Audio \(index+1)"
        let proposal = SilenceProposal(original:clip,replacements:edited,sourceName:sourceName)
        guard proposal.removedDuration > 0.05 else { throw ForgeError.message("No pauses long enough to remove at these settings. Nothing was changed.") }
        progress(1)
        return proposal
    }
}
