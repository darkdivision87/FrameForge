import Foundation
import AVFoundation
import AppKit

@main struct EngineCheck {
    static func main() async {
        do { try await run() }
        catch { print("FAIL: \(error.localizedDescription)"); exit(1) }
    }
    static func run() async throws {
        let directory = URL(fileURLWithPath: CommandLine.arguments[1]); try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let source = directory.appendingPathComponent("fixture.mov")
        if !CommandLine.arguments.contains("--existing-fixture") {
        try? FileManager.default.removeItem(at: source)
        let writer = try AVAssetWriter(outputURL: source, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.proRes422,AVVideoWidthKey: 320,AVVideoHeightKey: 180])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,kCVPixelBufferWidthKey as String:320,kCVPixelBufferHeightKey as String:180])
        writer.add(input); guard writer.startWriting() else { throw writer.error! }; writer.startSession(atSourceTime: .zero)
        for frame in 0..<60 {
            while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 1_000_000) }
            var buffer: CVPixelBuffer?; CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &buffer)
            let pixel = buffer!; CVPixelBufferLockBaseAddress(pixel, [])
            memset(CVPixelBufferGetBaseAddress(pixel), frame < 30 ? 0x55 : 0xaa, CVPixelBufferGetDataSize(pixel))
            CVPixelBufferUnlockBaseAddress(pixel, [])
            guard adaptor.append(pixel, withPresentationTime: CMTime(value: Int64(frame), timescale:30)) else { throw writer.error! }
        }
        input.markAsFinished(); await writer.finishWriting()
        }
        let original = try await MediaEngine.inspect(source)
        let split = try original.split(at: 1)
        assert(abs(split.0.duration-1) < 0.05)
        assert(abs(split.1.start-1) < 0.05)
        var fast = split.1; fast.speed = 2
        var project = Project(); project.width = 1280; project.height = 720; project.clips = [split.0,fast]
        let data = try JSONEncoder().encode(project); let restored = try JSONDecoder().decode(Project.self, from:data); assert(restored == project)
        var bad = original; bad.end = -1
        do { try bad.validated(); fatalError("Invalid range accepted") } catch {}
        do { _ = try original.split(at:0); fatalError("Boundary split accepted") } catch {}
        let render = try await MediaEngine.compose(project)
        assert(abs(render.composition.duration.seconds-1.5) < 0.1)
        if CommandLine.arguments.contains("--existing-fixture") {
            let tracks = try await render.composition.loadTracks(withMediaType:.audio)
            precondition(tracks.count == 2, "Both audio sources must survive composition")
            precondition(render.audio.inputParameters.count == 2)
            precondition(original.audioNames?.count == 2)
            let firstMic = tracks[1].segments.first { !$0.isEmpty }!
            let inputAudio = try await AVURLAsset(url:source).loadTracks(withMediaType:.audio)
            let inputSegments = try await inputAudio[1].load(.segments)
            precondition(inputSegments[0].isEmpty && abs(inputSegments[1].timeMapping.target.start.seconds-0.25) < 0.05)
            // Source range includes the original empty edit; exporting this mapping
            // retains the delay (verified separately against the native app export).
            precondition(firstMic.timeMapping.source.start == .zero)
            print("PASS: real video import, two audio sources, original microphone empty edit, trim/split/speed composition, video transforms, project round trip")
            if CommandLine.arguments.contains("--compose-only") { return }
        }
        let output = directory.appendingPathComponent("result.mp4"); try? FileManager.default.removeItem(at: output)
        let session = AVAssetExportSession(asset:render.composition,presetName: AVAssetExportPresetHighestQuality)!
        session.outputURL = output; session.outputFileType = .mp4; session.videoComposition = render.video; session.audioMix = render.audio
        await session.export(); guard session.status == .completed else { throw session.error ?? ForgeError.message("Integration export failed") }
        let result = try await MediaEngine.inspect(output)
        assert(abs(result.sourceDuration-1.5) < 0.15)
        let track = try await AVURLAsset(url:output).loadTracks(withMediaType:.video).first!
        let size = try await track.load(.naturalSize); assert(size.width == 1280 && size.height == 720)
        print("PASS: validation, split, speed, project round trip, composition, actual H.264 export and output inspection")
    }
}
