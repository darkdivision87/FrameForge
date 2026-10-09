import AVFoundation

/// Makes the file that goes on the clipboard. Recordings keep microphone and system audio as
/// separate tracks for the editor, but Slack, browsers and most players only play the first
/// audio track. The share copy mixes every audio track into one AAC track and copies the video
/// samples unchanged (no re-encode), so it is fast and plays everywhere.
enum ShareCopy {
    static func url(for recording: URL) -> URL { recording.deletingPathExtension().appendingPathExtension("mp4") }

    static func make(from recording: URL) async throws -> URL {
        let asset = AVURLAsset(url: recording)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        guard let videoTrack = videoTracks.first else { throw ForgeError.message("The recording has no video to share.") }
        let destination = url(for: recording)
        try? FileManager.default.removeItem(at: destination)

        let reader = try AVAssetReader(asset: asset)
        let writer = try AVAssetWriter(outputURL: destination, fileType: .mp4)
        let videoOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: nil)
        guard reader.canAdd(videoOutput) else { throw ForgeError.message("Could not read the recording's video.") }
        reader.add(videoOutput)
        let formatHint = try await videoTrack.load(.formatDescriptions).first
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: formatHint)
        videoInput.transform = try await videoTrack.load(.preferredTransform)
        guard writer.canAdd(videoInput) else { throw ForgeError.message("Could not write the shareable video.") }
        writer.add(videoInput)

        var pairs: [(AVAssetReaderOutput, AVAssetWriterInput)] = [(videoOutput, videoInput)]
        if !audioTracks.isEmpty {
            let audioOutput = AVAssetReaderAudioMixOutput(audioTracks: audioTracks, audioSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48000, AVNumberOfChannelsKey: 2,
                AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false])
            guard reader.canAdd(audioOutput) else { throw ForgeError.message("Could not read the recording's audio.") }
            reader.add(audioOutput)
            let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48000, AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 192000])
            guard writer.canAdd(audioInput) else { throw ForgeError.message("Could not write the shareable audio.") }
            writer.add(audioInput)
            pairs.append((audioOutput, audioInput))
        }

        guard reader.startReading() else { throw reader.error ?? ForgeError.message("Could not read the recording.") }
        guard writer.startWriting() else { throw writer.error ?? ForgeError.message("Could not write the shareable video.") }
        writer.startSession(atSourceTime: .zero)
        await withTaskGroup(of: Void.self) { group in
            for (index, (output, input)) in pairs.enumerated() {
                group.addTask { await pump(output, into: input, queue: DispatchQueue(label: "app.frameforge.share.\(index)")) }
            }
        }
        if reader.status == .failed { writer.cancelWriting(); throw reader.error ?? ForgeError.message("Could not read the recording.") }
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? ForgeError.message("Could not finish the shareable video.") }
        return destination
    }

    /// Copies samples until the reader runs out, appending only as fast as the writer accepts them.
    private static func pump(_ output: AVAssetReaderOutput, into input: AVAssetWriterInput, queue: DispatchQueue) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            input.requestMediaDataWhenReady(on: queue) {
                while input.isReadyForMoreMediaData {
                    guard let sample = output.copyNextSampleBuffer(), input.append(sample) else {
                        input.markAsFinished(); continuation.resume(); return
                    }
                }
            }
        }
    }
}
