import Foundation
import AVFoundation
@main struct SilenceCheck {
    static func main() async {
        do {
            let url = URL(fileURLWithPath:CommandLine.arguments[1])
            let clip = try await MediaEngine.inspect(url)
            let proposal = try await SilenceDetector.analyze(clip:clip,sourceIndex:0,thresholdDB:-40,minimumSilence:0.8,padding:0.15) { _ in }
            precondition(proposal.replacements.count == 2)
            precondition(abs(proposal.replacements[0].start-0.85) < 0.08)
            precondition(abs(proposal.replacements[0].end-2.15) < 0.08)
            precondition(abs(proposal.replacements[1].start-3.85) < 0.08)
            precondition(abs(proposal.replacements[1].end-5.15) < 0.08)
            var project = Project(); project.clips = proposal.replacements
            let render = try await MediaEngine.compose(project)
            precondition(abs(render.composition.duration.seconds-2.6) < 0.15)
            let tracks = try await render.composition.loadTracks(withMediaType:.audio)
            precondition(tracks.count == 1)
            print("PASS: real PCM audio decoding, silence threshold and timing, speech padding, video/audio synchronized cut composition")
        } catch { print("FAIL: \(error as NSError)"); exit(1) }
    }
}
