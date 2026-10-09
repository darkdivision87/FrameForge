import Foundation
import CoreGraphics

struct CursorSample: Codable, Equatable {
    var time: Double
    var x: Double
    var y: Double
    var pressed: Bool
    var inside: Bool
}
struct CaptureMetadata: Codable {
    var version = 1
    var audioNames: [String]
    var cursor: [CursorSample]
    var microphoneDevice: String?
    var microphonePeakDB: Double?
    var clippedMicrophoneSamples: Int?
    static func url(for media: URL) -> URL { media.deletingPathExtension().appendingPathExtension("forgecapture.json") }
}
struct FocusPose { let time: Double; let zoom: Double; let x: Double; let y: Double }
enum SmartFocus {
    static func poses(clip: Clip) -> [FocusPose] {
        let samples = (clip.cursorSamples ?? []).filter { $0.time.isFinite && $0.x.isFinite && $0.y.isFinite }.sorted { $0.time < $1.time }
        let mode = clip.mouseStyle ?? "off"
        guard mode != "off", !samples.isEmpty else { return [] }
        let maximum = min(2.5,max(1,clip.mouseZoom ?? 1.6))
        let step = max(0.05,clip.duration/12000)
        var poses: [FocusPose] = []; var index = 0
        var x = 0.5; var y = 0.5; var zoom = 1.0
        var lastClick = -Double.infinity; var previousPressed = false
        // Include prior clicks for trimmed ranges while starting with a wide frame.
        let count = Int(ceil(clip.duration/step))
        for frame in 0...count {
            let t = min(clip.duration,Double(frame)*step)
            let sourceTime = clip.start + t*clip.speed
            while index+1 < samples.count && samples[index+1].time <= sourceTime {
                if samples[index].pressed && !previousPressed && samples[index].inside { lastClick = samples[index].time }
                previousPressed = samples[index].pressed; index += 1
            }
            let current = samples[index]
            if current.time <= sourceTime && current.pressed && !previousPressed && current.inside { lastClick = current.time }
            previousPressed = current.pressed
            let inside = current.inside && current.time <= sourceTime
            let active = inside && (mode == "follow" || sourceTime-lastClick < 2)
            let edge = min(1,min(t/0.4,(clip.duration-t)/0.4))
            let targetZoom = active ? maximum : 1
            let alpha = 1-exp(-step/0.22)
            zoom += (targetZoom-zoom)*alpha
            if inside { x += (min(1,max(0,current.x))-x)*alpha; y += (min(1,max(0,current.y))-y)*alpha }
            let envelope = max(0,min(1,edge)); let eased = envelope*envelope*(3-2*envelope)
            poses.append(FocusPose(time:t,zoom:1+(zoom-1)*eased,x:x,y:y))
        }
        return poses
    }
    static func transform(base: CGAffineTransform,pose: FocusPose,canvas: CGSize,content: CGRect) -> CGAffineTransform {
        let z = CGFloat(pose.zoom)
        let px = content.minX + CGFloat(pose.x)*content.width
        let py = content.minY + CGFloat(pose.y)*content.height
        let tx = max(canvas.width*(1-z),min(0,canvas.width/2-px*z))
        let ty = max(canvas.height*(1-z),min(0,canvas.height/2-py*z))
        return base.concatenating(CGAffineTransform(scaleX:z,y:z)).concatenating(CGAffineTransform(translationX:tx,y:ty))
    }
}
struct SpeechRange: Equatable { let start: Double; let end: Double }
enum SilencePlan {
    static func keptRanges(voice: [SpeechRange],start: Double,end: Double,minimumSilence: Double,padding: Double) -> [SpeechRange] {
        guard end > start, minimumSilence >= 0.1, padding >= 0 else { return [] }
        let valid = voice.map { SpeechRange(start:max(start,$0.start),end:min(end,$0.end)) }.filter { $0.end > $0.start }.sorted { $0.start < $1.start }
        guard !valid.isEmpty else { return [] }
        var speech: [SpeechRange] = []
        for range in valid {
            if let previous = speech.last, range.start-previous.end < minimumSilence {
                speech[speech.count-1] = SpeechRange(start:previous.start,end:max(previous.end,range.end))
            } else { speech.append(range) }
        }
        let preserveHead = speech[0].start-start < minimumSilence
        let preserveTail = end-speech.last!.end < minimumSilence
        var merged: [SpeechRange] = []
        for range in speech {
            let padded = SpeechRange(start:max(start,range.start-padding),end:min(end,range.end+padding))
            if let previous = merged.last, padded.start <= previous.end {
                merged[merged.count-1] = SpeechRange(start:previous.start,end:max(previous.end,padded.end))
            } else { merged.append(padded) }
        }
        if preserveHead { merged[0] = SpeechRange(start:start,end:merged[0].end) }
        if preserveTail { merged[merged.count-1] = SpeechRange(start:merged.last!.start,end:end) }
        return merged
    }
    static func clips(from clip: Clip,ranges: [SpeechRange]) -> [Clip] {
        ranges.map { range in var edited = clip; edited.id = UUID(); edited.start = range.start; edited.end = range.end; return edited }
    }
}
