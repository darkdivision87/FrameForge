import SwiftUI
import AVKit

struct SmartEditingPanel: View {
    @EnvironmentObject var store: Store
    let clip: Clip
    @State private var threshold = -40.0
    @State private var minimumSilence = 0.8
    @State private var sourceIndex = -1
    @State private var detailZoom: Double?
    private var hasMouse: Bool { !(clip.cursorSamples ?? []).isEmpty }
    private func changeMouse(mode: String? = nil,zoom: Double? = nil) {
        var changed = clip
        if let mode = mode { changed.mouseStyle = mode }
        if let zoom = zoom { changed.mouseZoom = zoom }
        store.update(changed)
    }
    var body: some View {
        VStack(alignment:.leading,spacing:12) {
            Divider()
            Text("SMART EDITING").font(.caption.bold()).foregroundColor(.mint)
            Group {
                Picker("Mouse zoom",selection:Binding(get:{ clip.mouseStyle ?? "off" },set:{ changeMouse(mode:$0) })) {
                    Text("Off").tag("off"); Text("Follow mouse").tag("follow"); Text("Focus clicks").tag("clicks")
                }.disabled(!hasMouse || store.busy)
                if hasMouse {
                    Picker("Zoom amount",selection:Binding(get:{ clip.mouseZoom ?? 1.6 },set:{ changeMouse(zoom:$0) })) {
                        ForEach([1.25,1.6,2,2.5],id: \.self) { value in Text("\(value,specifier:"%.2g")×").tag(value) }
                    }.disabled(store.busy)
                    if let limit = detailZoom, (clip.mouseStyle ?? "off") != "off", (clip.mouseZoom ?? 1.6) > limit + 0.01 {
                        Text("This source supports about \(max(1,limit),specifier:"%.1f")× zoom at the current export size before enlarging pixels. Lower zoom or record at 4K for sharper detail.").font(.caption2).foregroundColor(.orange)
                    }
                    Text("Smooth pan/zoom is applied in both preview and export. Original recording stays unchanged.").font(.caption2).foregroundColor(.secondary)
                } else {
                    Text("Mouse-follow needs a new FrameForge recording with Track mouse for editing enabled.").font(.caption2).foregroundColor(.secondary)
                }
            }
            Group {
                Text("CUT SILENCE · OPTIONAL").font(.caption2.bold()).foregroundColor(.secondary)
                Picker("Analyze",selection:$sourceIndex) {
                    Text("Auto: microphone first").tag(-1)
                    ForEach(Array((clip.audioNames ?? []).enumerated()),id: \.offset) { index,name in Text(name).tag(index) }
                }
                Picker("Threshold",selection:$threshold) {
                    ForEach([-55.0,-50,-45,-40,-35,-30],id: \.self) { value in Text("\(Int(value)) dB").tag(value) }
                }
                Picker("Minimum pause",selection:$minimumSilence) {
                    ForEach([0.5,0.8,1.2,2],id: \.self) { value in Text("\(value,specifier:"%.1f") seconds").tag(value) }
                }
                Button("Analyze & Preview Cuts…") { store.analyzeSilence(sourceIndex:sourceIndex,thresholdDB:threshold,minimumSilence:minimumSilence) }.disabled(store.busy)
                Text("Keeps 150 ms around speech. Review the proposed cut before applying; Undo restores it.").font(.caption2).foregroundColor(.secondary)
            }
        }.task(id:"\(clip.path)-\(store.project.width)-\(store.project.height)") {
            detailZoom = nil
            do {
                let asset = AVURLAsset(url:URL(fileURLWithPath:clip.path))
                guard let track = try await asset.loadTracks(withMediaType:.video).first else { return }
                let natural = try await track.load(.naturalSize)
                let transform = try await track.load(.preferredTransform)
                let bounds = CGRect(origin:.zero,size:natural).applying(transform)
                let scale = min(CGFloat(store.project.width)/abs(bounds.width),CGFloat(store.project.height)/abs(bounds.height))
                if !Task.isCancelled, scale.isFinite, scale > 0 { detailZoom = Double(1/scale) }
            } catch { detailZoom = nil }
        }
    }
}
struct SilenceReview: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    let proposal: SilenceProposal
    @State private var player = AVPlayer()
    @State private var previewError: String?
    var body: some View {
        VStack(alignment:.leading,spacing:16) {
            Text("Review silence cuts").font(.title2.bold())
            Text("\(proposal.original.name) · \(proposal.sourceName)").foregroundColor(.secondary)
            NativePreview(player:player).frame(width:640,height:360).background(Color.black).cornerRadius(8)
            HStack { Button("Play / Pause") { if player.rate == 0 { player.seek(to:.zero); player.play() } else { player.pause() } }; Text("\(proposal.replacements.count) kept sections · removes \(timeLabel(proposal.removedDuration))") }
            if let previewError = previewError { Text(previewError).foregroundColor(.red) }
            ScrollView { VStack(alignment:.leading) { ForEach(proposal.replacements) { clip in Text("Keep \(timeLabel(clip.start)) – \(timeLabel(clip.end))").font(.caption.monospaced()) } } }.frame(maxHeight:100)
            Text("Video and every audio source are cut together. This preview shows the selected clip only; applying adds its kept sections to the timeline.").font(.caption).foregroundColor(.secondary)
            HStack { Spacer(); Button("Cancel") { dismiss() }; Button("Apply Cuts") { store.applySilence(proposal); dismiss() }.buttonStyle(.borderedProminent).tint(.mint) }
        }.padding(24).task {
            do {
                var project = store.project; project.clips = proposal.replacements
                let render = try await MediaEngine.compose(project)
                let item = AVPlayerItem(asset:render.composition); item.videoComposition = render.video; item.audioMix = render.audio
                player.replaceCurrentItem(with:item)
            } catch { previewError = error.localizedDescription }
        }.onDisappear { player.pause(); player.replaceCurrentItem(with:nil) }
    }
}
