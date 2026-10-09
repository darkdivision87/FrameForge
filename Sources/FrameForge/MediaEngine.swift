import AVFoundation
import AppKit

struct Render {
    let composition: AVMutableComposition
    let video: AVMutableVideoComposition
    let audio: AVMutableAudioMix
}
enum MediaEngine {
    static func inspect(_ url: URL) async throws -> Clip {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard duration.isFinite, duration > 0, !tracks.isEmpty else { throw ForgeError.message("Choose a video file containing a video track.") }
        let audioTracks = try await asset.loadTracks(withMediaType:.audio)
        var names: [String] = []
        for (index, track) in audioTracks.enumerated() {
            let metadata = try await track.load(.commonMetadata)
            if let title = metadata.first(where: { $0.commonKey == .commonKeyTitle }), let value = try await title.load(.stringValue) { names.append(value) }
            else { names.append("Audio \(index+1)") }
        }
        let metadata: CaptureMetadata?
        if let data = try? Data(contentsOf:CaptureMetadata.url(for:url)) { metadata = try? JSONDecoder().decode(CaptureMetadata.self,from:data) }
        else { metadata = nil }
        if let recorded = metadata, recorded.version == 1, recorded.audioNames.count == names.count { names = recorded.audioNames }
        return Clip(path: url.path, name: url.deletingPathExtension().lastPathComponent, sourceDuration: duration, end: duration, audioNames:names, audioVolumes:Array(repeating:1,count:names.count),cursorSamples:metadata?.cursor,mouseStyle:metadata?.cursor.isEmpty == false ? "clicks" : "off",mouseZoom:1.6)
    }
    static func compose(_ project: Project) async throws -> Render {
        try project.validated()
        guard !project.clips.isEmpty else { throw ForgeError.message("Import or record a clip first.") }
        let composition = AVMutableComposition()
        guard let videoTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else { throw ForgeError.message("Could not create timeline tracks.") }
        var instructions: [AVMutableVideoCompositionInstruction] = []
        var audioTracks: [AVMutableCompositionTrack] = []
        var mixes: [AVMutableAudioMixInputParameters] = []
        var cursor = CMTime.zero
        let size = CGSize(width: project.width, height: project.height)
        for clip in project.clips {
            try Task.checkCancellation()
            guard FileManager.default.fileExists(atPath: clip.path) else { throw ForgeError.message("Missing media: \(clip.path). Restore the source file or re-import it.") }
            let asset = AVURLAsset(url: URL(fileURLWithPath: clip.path))
            guard let source = try await asset.loadTracks(withMediaType: .video).first else { throw ForgeError.message("No video in \(clip.name).") }
            let range = CMTimeRange(start: CMTime(seconds: clip.start, preferredTimescale: 600), duration: CMTime(seconds: clip.end-clip.start, preferredTimescale: 600))
            let outputDuration = CMTime(seconds: clip.duration, preferredTimescale: 600)
            try videoTrack.insertTimeRange(range, of: source, at: cursor)
            videoTrack.scaleTimeRange(CMTimeRange(start: cursor, duration: range.duration), toDuration: outputDuration)
            let sources = try await asset.loadTracks(withMediaType:.audio)
            for (index,audioSource) in sources.enumerated() {
                if index >= audioTracks.count {
                    guard let track = composition.addMutableTrack(withMediaType:.audio,preferredTrackID:kCMPersistentTrackID_Invalid) else { throw ForgeError.message("Cannot create audio lane.") }
                    audioTracks.append(track); mixes.append(AVMutableAudioMixInputParameters(track:track))
                }
                let track = audioTracks[index]
                let sourceRange = try await audioSource.load(.timeRange)
                let intersection = CMTimeRangeGetIntersection(range,otherRange:sourceRange)
                if intersection.duration > .zero {
                    let offset = CMTimeMultiplyByFloat64(intersection.start-range.start,multiplier:1/clip.speed)
                    let destination = cursor + offset
                    // Preserve initial silence and the offsets of independently captured sources.
                    if track.timeRange.end < destination {
                        track.insertEmptyTimeRange(CMTimeRange(start:track.timeRange.end,end:destination))
                    }
                    try track.insertTimeRange(intersection,of:audioSource,at:destination)
                    track.scaleTimeRange(CMTimeRange(start:destination,duration:intersection.duration),toDuration:CMTimeMultiplyByFloat64(intersection.duration,multiplier:1/clip.speed))
                }
                let sourceVolume = clip.audioVolumes.flatMap { index < $0.count ? $0[index] : nil } ?? 1
                mixes[index].setVolume(Float(clip.volume*sourceVolume),at:cursor)
            }
            let natural = try await source.load(.naturalSize)
            let preferred = try await source.load(.preferredTransform)
            let bounds = CGRect(origin: .zero, size: natural).applying(preferred)
            let scale = min(size.width / bounds.width, size.height / bounds.height)
            let transform = preferred.concatenating(CGAffineTransform(translationX: -bounds.minX, y: -bounds.minY)).concatenating(CGAffineTransform(scaleX: scale, y: scale)).concatenating(CGAffineTransform(translationX: (size.width-bounds.width*scale)/2, y: (size.height-bounds.height*scale)/2))
            let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: videoTrack)
            let poses = SmartFocus.poses(clip:clip)
            if poses.count > 1 {
                let contentRect = CGRect(x:(size.width-bounds.width*scale)/2,y:(size.height-bounds.height*scale)/2,width:bounds.width*scale,height:bounds.height*scale)
                for index in 0..<(poses.count-1) {
                    let from = SmartFocus.transform(base:transform,pose:poses[index],canvas:size,content:contentRect)
                    let to = SmartFocus.transform(base:transform,pose:poses[index+1],canvas:size,content:contentRect)
                    let time = cursor + CMTime(seconds:poses[index].time,preferredTimescale:60000)
                    let duration = CMTime(seconds:poses[index+1].time-poses[index].time,preferredTimescale:60000)
                    if duration > .zero { layer.setTransformRamp(fromStart:from,toEnd:to,timeRange:CMTimeRange(start:time,duration:duration)) }
                }
            } else { layer.setTransform(transform,at:cursor) }
            let instruction = AVMutableVideoCompositionInstruction()
            instruction.timeRange = CMTimeRange(start: cursor, duration: outputDuration)
            instruction.layerInstructions = [layer]
            instruction.backgroundColor = NSColor.black.cgColor
            instructions.append(instruction)
            cursor = cursor + outputDuration
        }
        let video = AVMutableVideoComposition()
        video.renderSize = size; video.frameDuration = CMTime(value: 1, timescale: Int32(project.fps)); video.instructions = instructions
        let audio = AVMutableAudioMix(); audio.inputParameters = mixes
        return Render(composition: composition, video: video, audio: audio)
    }
}
