import AVFoundation

struct MicrophoneLevel { let peakDB: Double; let clipped: Int }
final class MicrophoneProcessor {
    private var limiterGain: Float = 1
    static let settings: [String:Any] = [AVFormatIDKey:kAudioFormatLinearPCM, AVSampleRateKey:48000, AVNumberOfChannelsKey:1, AVLinearPCMBitDepthKey:32, AVLinearPCMIsFloatKey:true, AVLinearPCMIsBigEndianKey:false, AVLinearPCMIsNonInterleaved:false]
    func reset() { limiterGain = 1 }
    func process(_ sample: CMSampleBuffer, timestamp: CMTime, gain: Float) throws -> (CMSampleBuffer,MicrophoneLevel) {
        guard let format = sample.formatDescription,
              let pointer = CMAudioFormatDescriptionGetStreamBasicDescription(format) else { throw ForgeError.message("Microphone audio format is unavailable.") }
        let asbd = pointer.pointee
        guard asbd.mFormatID == kAudioFormatLinearPCM, asbd.mChannelsPerFrame == 1,
              asbd.mSampleRate == 48000, asbd.mBitsPerChannel == 32, asbd.mBytesPerFrame == 4,
              asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              asbd.mFormatFlags & kAudioFormatFlagIsBigEndian == 0,
              let block = sample.dataBuffer else { throw ForgeError.message("Microphone did not supply the requested 48 kHz mono Float32 format. Choose another input device.") }
        let count = CMSampleBufferGetNumSamples(sample)
        guard count > 0, CMBlockBufferGetDataLength(block) >= count*4 else { throw ForgeError.message("Incomplete microphone audio buffer.") }
        var values = [Float](repeating:0,count:count)
        let copied = values.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block,atOffset:0,dataLength:count*4,destination:$0.baseAddress!) }
        guard copied == noErr else { throw ForgeError.message("Could not read microphone audio.") }
        let level = processValues(&values,gain:gain)
        var outputBlock: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator:kCFAllocatorDefault,memoryBlock:nil,blockLength:count*4,blockAllocator:kCFAllocatorDefault,customBlockSource:nil,offsetToData:0,dataLength:count*4,flags:0,blockBufferOut:&outputBlock) == noErr, let outputBlock = outputBlock else { throw ForgeError.message("Could not allocate microphone buffer.") }
        let replaced = values.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with:$0.baseAddress!,blockBuffer:outputBlock,offsetIntoDestination:0,dataLength:count*4) }
        guard replaced == noErr else { throw ForgeError.message("Could not write microphone samples.") }
        var output: CMSampleBuffer?
        // Duration is derived from the actual PCM sample rate, rather than copied
        // timing entries from a device clock or a compressed input packet.
        guard CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator:kCFAllocatorDefault,dataBuffer:outputBlock,formatDescription:format,sampleCount:count,presentationTimeStamp:timestamp,packetDescriptions:nil,sampleBufferOut:&output) == noErr, let output = output else { throw ForgeError.message("Could not timestamp microphone audio.") }
        return (output,level)
    }
    func processValues(_ values: inout [Float],gain: Float) -> MicrophoneLevel {
        let appliedGain = min(1,max(0,gain))
        var peak: Float = 0; var clipped = 0
        for value in values where value.isFinite { peak = max(peak,abs(value*appliedGain)); if abs(value) >= 0.999 { clipped += 1 } }
        // Never amplify quiet input. A fast reduction and slow release leave
        // headroom for summing audio sources and protect against float overshoot.
        let required: Float = peak > 0.79 ? 0.79/peak : 1
        limiterGain = min(required,limiterGain + Float(values.count)/48000*0.3)
        for i in values.indices { values[i] = values[i].isFinite ? values[i]*appliedGain*limiterGain : 0 }
        return MicrophoneLevel(peakDB:20*log10(max(0.000001,Double(peak))),clipped:clipped)
    }
}
