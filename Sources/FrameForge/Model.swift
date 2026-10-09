import Foundation

struct Clip: Identifiable, Codable, Equatable {
    var id = UUID()
    var path: String
    var name: String
    var sourceDuration: Double
    var start: Double = 0
    var end: Double
    var speed: Double = 1
    var volume: Double = 1
    var audioNames: [String]?
    var audioVolumes: [Double]?
    var cursorSamples: [CursorSample]?
    var mouseStyle: String?
    var mouseZoom: Double?
    var duration: Double { (end - start) / speed }
    func validated() throws {
        guard sourceDuration.isFinite, start.isFinite, end.isFinite, speed.isFinite,
              start >= 0, end > start, end <= sourceDuration + 0.01,
              speed >= 0.25, speed <= 4, volume.isFinite, volume >= 0, volume <= 2 else {
            throw ForgeError.message("Invalid clip range, speed, or volume.")
        }
        guard (audioVolumes ?? []).allSatisfy({ $0.isFinite && $0 >= 0 && $0 <= 2 }) else { throw ForgeError.message("Invalid audio source volume.") }
        guard ["off","follow","clicks"].contains(mouseStyle ?? "off"), (mouseZoom ?? 1.6).isFinite, (mouseZoom ?? 1.6) >= 1, (mouseZoom ?? 1.6) <= 2.5 else { throw ForgeError.message("Invalid mouse-follow settings.") }
    }
    func split(at offset: Double) throws -> (Clip, Clip) {
        try validated()
        let cut = start + offset * speed
        guard cut > start + 0.01, cut < end - 0.01 else { throw ForgeError.message("Place the playhead inside the selected clip.") }
        var left = self; left.end = cut
        var right = self; right.id = UUID(); right.start = cut
        return (left, right)
    }
}
struct Project: Codable, Equatable {
    var version = 1
    var clips: [Clip] = []
    var width: Int = 1920
    var height: Int = 1080
    var fps: Int = 30
    var duration: Double { clips.reduce(0) { $0 + $1.duration } }
    func validated() throws {
        guard version == 1, [1280,1920,3840].contains(width), [720,1080,2160].contains(height), [30,60].contains(fps) else { throw ForgeError.message("Unsupported project settings.") }
        for clip in clips { try clip.validated() }
    }
}
enum ForgeError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}
func timeLabel(_ seconds: Double) -> String {
    guard seconds.isFinite else { return "00:00.0" }
    return String(format: "%02d:%04.1f", Int(max(0,seconds)) / 60, max(0,seconds).truncatingRemainder(dividingBy: 60))
}
