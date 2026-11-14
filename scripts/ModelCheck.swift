import Foundation
import CoreGraphics
@main struct ModelCheck {
    static func main() throws {
        try SmartCheck.run()
        let clip = Clip(path: "/fixture.mov", name: "Fixture", sourceDuration: 10, start: 2, end: 8, speed: 2)
        try clip.validated(); precondition(clip.duration == 3)
        let (left,right) = try clip.split(at: 1)
        precondition(left.start == 2 && left.end == 4 && right.start == 4 && right.end == 8)
        precondition(left.duration + right.duration == clip.duration && left.id != right.id)
        for offset in [-1.0,0,3,4] {
            var rejected = false; do { _ = try clip.split(at:offset) } catch { rejected = true }; precondition(rejected)
        }
        var invalid = clip; invalid.speed = 0
        var rejected = false; do { try invalid.validated() } catch { rejected = true }; precondition(rejected)
        invalid = clip; invalid.end = .nan; rejected = false
        do { try invalid.validated() } catch { rejected = true }; precondition(rejected)
        var project = Project(); project.clips = [left,right]
        // A middle cut on a trimmed, sped-up clip preserves source timing and metadata.
        var editedProject = Project(); editedProject.clips = [clip]
        let middle = try editedProject.removingRange(from:0.5,to:1.5)
        precondition(middle.clips.count == 2 && middle.duration == 2)
        precondition(middle.clips[0].start == 2 && middle.clips[0].end == 3)
        precondition(middle.clips[1].start == 5 && middle.clips[1].end == 8)
        precondition(middle.clips[0].id != middle.clips[1].id)
        precondition(editedProject.clips == [clip]) // original remains untouched
        editedProject.clips = [clip,clip]
        let across = try editedProject.removingRange(from:2,to:4)
        precondition(across.clips.count == 2 && across.duration == 4)
        precondition(across.clips[0].end == 6 && across.clips[1].start == 4)
        let empty = try editedProject.removingRange(from:0,to:6)
        precondition(empty.clips.isEmpty)
        let head = try editedProject.removingRange(from:0,to:3)
        precondition(head.clips == [clip])
        let tail = try editedProject.removingRange(from:3,to:6)
        precondition(tail.clips == [clip])
        for (lower,upper) in [(Double.nan,1.0),(0,Double.infinity),(-1,1),(1,1),(2,1),(0,7)] {
            var rejected = false
            do { _ = try editedProject.removingRange(from:lower,to:upper) } catch { rejected = true }
            precondition(rejected)
        }
        let builtin = MicrophoneDevice(id:"builtin",name:"Built-in",isUSB:false)
        let usb = MicrophoneDevice(id:"usb",name:"USB mic",isUSB:true)
        let otherUSB = MicrophoneDevice(id:"other",name:"Other USB",isUSB:true)
        precondition(MicrophoneDevice.automaticID(in:[builtin],preferred:nil) == nil)
        precondition(MicrophoneDevice.automaticID(in:[builtin,usb],preferred:nil) == "usb")
        precondition(MicrophoneDevice.automaticID(in:[usb,otherUSB],preferred:"other") == "other")
        precondition(MicrophoneDevice.automaticID(in:[builtin,usb],preferred:"unplugged") == "usb")
        print("PASS: ripple cuts within/across clips, speed mapping, full/head/tail deletion, invalid ranges, USB-only microphone selection")
        let encoded = try JSONEncoder().encode(project); let decoded = try JSONDecoder().decode(Project.self, from: encoded)
        precondition(decoded == project); try decoded.validated()
        precondition(timeLabel(61.5) == "01:01.5")
        let unit = try CaptureGeometry.normalized(CGRect(x:100,y:50,width:400,height:200),in:CGSize(width:1000,height:500))
        precondition(unit == CGRect(x:0.1,y:0.1,width:0.4,height:0.4))
        let source = try CaptureGeometry.sourceRect(unit,logicalSize:CGSize(width:2000,height:1000))
        precondition(source == CGRect(x:200,y:100,width:800,height:400))
        let clipped = try CaptureGeometry.normalized(CGRect(x:-100,y:50,width:400,height:200),in:CGSize(width:1000,height:500))
        precondition(clipped.minX == 0 && clipped.width == 0.3)
        let retina = CaptureGeometry.outputSize(source:CGSize(width:3360,height:1890),scale:2,maximumDimension:1920)
        precondition(retina == CGSize(width:1920,height:1080))
        let tiny = CaptureGeometry.outputSize(source:CGSize(width:101,height:51),scale:2,maximumDimension:1920)
        precondition(tiny == CGSize(width:202,height:102))
        var badRegionRejected = false
        do { _ = try CaptureGeometry.normalized(CGRect(x:0,y:0,width:8,height:8),in:CGSize(width:1000,height:500)) } catch { badRegionRejected = true }
        precondition(badRegionRejected)
        let legacy = """
        {"version":1,"clips":[{"id":"\(clip.id.uuidString)","path":"/fixture.mov","name":"Fixture","sourceDuration":10,"start":2,"end":8,"speed":2,"volume":1}],"width":1920,"height":1080,"fps":30}
        """
        let old = try JSONDecoder().decode(Project.self,from:Data(legacy.utf8)); try old.validated()
        precondition(old.clips[0].audioVolumes == nil)
        var audioClip = clip; audioClip.audioVolumes = [1,0.5]; try audioClip.validated()
        audioClip.audioVolumes = [.nan]; rejected = false
        do { try audioClip.validated() } catch { rejected = true }; precondition(rejected)
        print("PASS: Retina geometry, clamped region, minimum area, downscaling, old project compatibility, per-source audio volume validation")
        print("PASS: trim ranges, speed duration, split boundaries, identity, nonfinite input rejection, project serialization, time formatting")
    }
}
