import AVFoundation
import CoreGraphics

enum SmartCheck {
    static func run() throws {
        let processor = MicrophoneProcessor()
        var quiet: [Float] = [0.1,-0.1,0.05]
        _ = processor.processValues(&quiet,gain:1)
        precondition(abs(quiet[0]-0.1) < 0.000001,"Quiet input must not be amplified")
        processor.reset()
        var loud: [Float] = [2,-2,0.4,.nan]
        let level = processor.processValues(&loud,gain:1)
        precondition(level.clipped == 2 && loud.allSatisfy({ $0.isFinite && abs($0) <= 0.79001 }))
        var asbd = AudioStreamBasicDescription(mSampleRate:48000,mFormatID:kAudioFormatLinearPCM,mFormatFlags:kAudioFormatFlagsNativeFloatPacked,mBytesPerPacket:4,mFramesPerPacket:1,mBytesPerFrame:4,mChannelsPerFrame:1,mBitsPerChannel:32,mReserved:0)
        var format: CMAudioFormatDescription?
        precondition(CMAudioFormatDescriptionCreate(allocator:kCFAllocatorDefault,asbd:&asbd,layoutSize:0,layout:nil,magicCookieSize:0,magicCookie:nil,extensions:nil,formatDescriptionOut:&format) == noErr)
        let values: [Float] = (0..<4800).map { Float(0.3*sin(Double($0)*2*Double.pi*440/48000)) }
        var block: CMBlockBuffer?
        precondition(CMBlockBufferCreateWithMemoryBlock(allocator:kCFAllocatorDefault,memoryBlock:nil,blockLength:values.count*4,blockAllocator:kCFAllocatorDefault,customBlockSource:nil,offsetToData:0,dataLength:values.count*4,flags:0,blockBufferOut:&block) == noErr)
        let replacement = values.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with:$0.baseAddress!,blockBuffer:block!,offsetIntoDestination:0,dataLength:values.count*4) }
        precondition(replacement == noErr)
        var sample: CMSampleBuffer?
        precondition(CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator:kCFAllocatorDefault,dataBuffer:block!,formatDescription:format!,sampleCount:values.count,presentationTimeStamp:CMTime(seconds:10,preferredTimescale:48000),packetDescriptions:nil,sampleBufferOut:&sample) == noErr)
        processor.reset()
        let (converted,_) = try processor.process(sample!,timestamp:CMTime(seconds:12,preferredTimescale:48000),gain:0.5)
        precondition(CMSampleBufferGetNumSamples(converted) == 4800)
        precondition(abs(converted.duration.seconds-0.1) < 0.000001 && converted.presentationTimeStamp.seconds == 12)
        var decoded = [Float](repeating:0,count:4800)
        let copied = decoded.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(converted.dataBuffer!,atOffset:0,dataLength:4800*4,destination:$0.baseAddress!) }
        precondition(copied == noErr)
        precondition(zip(values,decoded).allSatisfy { abs($0.0*0.5-$0.1) < 0.000001 },"PCM data and frequency must survive processing")
        var clip = Clip(path:"fixture.mov",name:"Fixture",sourceDuration:6,end:6)
        var samples: [CursorSample] = []
        for i in 0...120 {
            let time = Double(i)/20.0
            let x = Double(i)/120.0
            let pressed = i == 20 || i == 80
            samples.append(CursorSample(time:time,x:x,y:0.5,pressed:pressed,inside:true))
        }
        clip.cursorSamples = samples
        clip.mouseStyle = "clicks"; clip.mouseZoom = 1.6
        let poses = SmartFocus.poses(clip:clip)
        precondition(poses.first!.zoom == 1 && poses.last!.zoom == 1)
        precondition(poses.contains { $0.time > 1 && $0.time < 2 && $0.zoom > 1.4 })
        precondition(poses.allSatisfy { $0.zoom >= 1 && $0.zoom <= 1.60001 && $0.x >= 0 && $0.x <= 1 })
        let transform = SmartFocus.transform(base:.identity,pose:FocusPose(time:1,zoom:2,x:0,y:1),canvas:CGSize(width:1920,height:1080),content:CGRect(x:0,y:0,width:1920,height:1080))
        precondition(transform.tx == 0 && transform.ty == -1080)
        let ranges = SilencePlan.keptRanges(voice:[SpeechRange(start:1,end:2),SpeechRange(start:4,end:5)],start:0,end:6,minimumSilence:0.8,padding:0.15)
        precondition(ranges.count == 2 && abs(ranges[0].start-0.85) < 0.00001 && abs(ranges[1].end-5.15) < 0.00001)
        precondition(SilencePlan.keptRanges(voice:[],start:0,end:6,minimumSilence:0.8,padding:0.15).isEmpty)
        let merged = SilencePlan.keptRanges(voice:[SpeechRange(start:0,end:1),SpeechRange(start:1.2,end:3)],start:0,end:3,minimumSilence:0.8,padding:0.15)
        precondition(merged.count == 1 && merged[0].start == 0 && merged[0].end == 3)
        let edited = SilencePlan.clips(from:clip,ranges:ranges)
        precondition(edited.allSatisfy { $0.mouseStyle == clip.mouseStyle && $0.id != clip.id })
        print("PASS: PCM waveform preservation, gain, overload protection, timestamps/sample duration, smooth mouse focus, frame clamps, speech padding, all-silent protection, short-pause preservation")
    }
}
