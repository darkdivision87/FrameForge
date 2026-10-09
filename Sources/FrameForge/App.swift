import SwiftUI
import AVKit

@main struct FrameForgeApp: App {
    @StateObject private var store = Store()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    var body: some Scene {
        WindowGroup {
            Editor().environmentObject(store).onAppear { delegate.store = store }.frame(minWidth: 1080, minHeight: 720).preferredColorScheme(.dark)
        }.commands {
            CommandGroup(replacing: .newItem) {
                Button("Open Project…", action: { store.open() }).keyboardShortcut("o")
                Button("Save Project…", action: { store.save() }).keyboardShortcut("s")
                Button("Import Video…", action: { store.importMedia() }).keyboardShortcut("i")
            }
            CommandGroup(replacing: .undoRedo) {
                Button("Undo", action: { store.undo() }).keyboardShortcut("z").disabled(!store.canUndo)
                Button("Redo", action: { store.redo() }).keyboardShortcut("z", modifiers: [.command,.shift]).disabled(!store.canRedo)
            }
            CommandMenu("Recording") {
                Button(store.recording ? "Stop Recording" : "Start Recording") { Task { if store.recording { await store.stopRecording() } else { await store.startRecording() } } }.keyboardShortcut("r", modifiers: [.option,.shift]).disabled(store.busy)
            }
        }
        MenuBarExtra(store.recording ? timeLabel(store.recordingSeconds) : "FrameForge", systemImage:store.recording ? "record.circle.fill" : "record.circle") {
            Text(store.recording ? "Recording · \(timeLabel(store.recordingSeconds))" : "FrameForge ready")
            Button(store.recording ? "Stop Recording" : "Start Recording") {
                Task { if store.recording { await store.stopRecording() } else { await store.startRecording() } }
            }.disabled(store.busy)
        }
    }
}
struct Editor: View {
    @EnvironmentObject var store: Store
    @State private var hevc = false
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                Image(systemName: "square.stack.3d.up.fill").foregroundColor(.mint).font(.title2)
                VStack(alignment: .leading) { Text("FRAMEFORGE").font(.headline); Text("Capture. Cut. Create.").font(.caption).foregroundColor(.secondary) }
                Spacer()
                Button(action: { store.importMedia() }) { Label("Import", systemImage: "plus") }.disabled(store.busy)
                Button(action: { store.open() }) { Image(systemName: "folder") }.help("Open project")
                Button(action: { store.save() }) { Image(systemName: "square.and.arrow.down") }.help("Save project")
                Menu("Export") { Button("H.264 MP4") { store.export(hevc: false) }; Button("HEVC MP4") { store.export(hevc: true) } }.frame(width:120).disabled(store.project.clips.isEmpty || store.busy)
            }.padding(20).background(Color(white: 0.12))
            HSplitView {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        RecordingPanel()
                        Divider()
                        Text("CANVAS").font(.caption.bold()).foregroundColor(.secondary)
                        Picker("Resolution", selection: Binding(get: { store.project.width }, set: { width in store.mutate { $0.width = width; $0.height = width == 1280 ? 720 : width == 3840 ? 2160 : 1080 } })) {
                            Text("720p").tag(1280); Text("1080p").tag(1920); Text("4K").tag(3840)
                        }.disabled(store.busy)
                        Picker("Export frame rate", selection: Binding(get: { store.project.fps }, set: { fps in store.mutate { $0.fps = fps } })) { Text("30 fps").tag(30); Text("60 fps").tag(60) }.disabled(store.busy)
                        Text("DEVELOPMENT BUILD · 0.4").font(.caption2).foregroundColor(.secondary)
                    }.padding(18)
                }.frame(minWidth: 250, maxWidth: 290)
                VStack(spacing: 12) {
                    ZStack {
                        Color.black
                        if store.project.clips.isEmpty {
                            VStack(spacing: 16) { Image(systemName: "video.badge.plus").font(.system(size: 44)).foregroundColor(.mint); Text("Your next story starts here").font(.title2); Text("Record a display or import a video to begin.").foregroundColor(.secondary); Button("Import Video", action: { store.importMedia() }) }
                        } else { NativePreview(player: store.player) }
                    }.aspectRatio(16/9, contentMode: .fit).cornerRadius(12)
                    HStack {
                        Button { if store.player.rate == 0 { store.player.play() } else { store.player.pause() } } label: { Image(systemName: "playpause.fill") }.disabled(store.project.clips.isEmpty)
                        Slider(value: Binding(get: { min(store.playhead, max(0.01,store.project.duration)) }, set: { store.playhead = $0; store.seek($0) }), in: 0...max(0.01,store.project.duration)).disabled(store.project.clips.isEmpty)
                        Text("\(timeLabel(store.playhead)) / \(timeLabel(store.project.duration))").font(.system(.caption, design: .monospaced))
                    }
                    HStack {
                        Text("TIMELINE").font(.caption.bold()).foregroundColor(.secondary)
                        Spacer()
                        Button("Split", action: { store.split() }).keyboardShortcut("b", modifiers: .command)
                        Button { store.move(-1) } label: { Image(systemName: "arrow.left") }.help("Move earlier")
                        Button { store.move(1) } label: { Image(systemName: "arrow.right") }.help("Move later")
                        Button("Duplicate", action: { store.duplicate() })
                        Button { store.remove() } label: { Image(systemName: "trash") }
                    }.disabled(store.clip == nil || store.busy)
                    ScrollView(.horizontal) {
                        HStack(spacing: 6) {
                            ForEach(store.project.clips) { clip in
                                Button {
                                    store.selected = clip.id
                                    let index = store.project.clips.firstIndex(where: { $0.id == clip.id }) ?? 0
                                    store.seek(store.project.clips.prefix(index).reduce(0) { $0+$1.duration })
                                } label: {
                                    VStack(alignment: .leading, spacing: 10) {
                                        Label(clip.name, systemImage: "film").lineLimit(1).font(.caption.bold())
                                        Spacer()
                                        Text("\(timeLabel(clip.duration)) · \(clip.speed, specifier: "%.2g")×").font(.caption.monospaced())
                                    }.padding(12).frame(width: max(130,min(320,clip.duration*12)), height: 82).background(store.selected == clip.id ? Color.mint.opacity(0.3) : Color.blue.opacity(0.22)).cornerRadius(8).overlay(RoundedRectangle(cornerRadius: 8).stroke(store.selected == clip.id ? Color.mint : Color.clear, lineWidth: 2))
                                }.buttonStyle(.plain)
                            }
                        }.padding(3)
                    }.frame(height: 100)
                    Text("Clips play left to right. Select a clip to edit; move the playhead inside it to split.").font(.caption).foregroundColor(.secondary)
                    Spacer(minLength: 0)
                }.padding(20).frame(minWidth: 540)
                ScrollView { Inspector() }.frame(minWidth: 230, maxWidth: 270)
            }
            Divider()
            HStack {
                Circle().fill(store.recording ? Color.red : Color.mint).frame(width: 7,height: 7)
                Text(store.status).font(.caption)
                Spacer()
                if store.recording { Text(timeLabel(store.recordingSeconds)).font(.system(.body,design:.monospaced)).foregroundColor(.red) }
                if store.exporting { ProgressView(value: store.progress).frame(width: 140); Button("Cancel", action: { store.cancelExport() }) }
                else if store.busy { ProgressView().controlSize(.small) }
            }.padding(12)
        }.sheet(item:$store.silenceProposal) { proposal in SilenceReview(proposal:proposal).environmentObject(store) }.alert("FrameForge", isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) { Button("OK") { store.error = nil } } message: { Text(store.error ?? "") }
    }
}
struct Inspector: View {
    @EnvironmentObject var store: Store
    @State private var start = 0.0
    @State private var end = 0.0
    @State private var speed = 1.0
    @State private var volume = 1.0
    @State private var name = ""
    @State private var audioVolumes: [Double] = []
    func load() { if let clip = store.clip { start = clip.start; end = clip.end; speed = clip.speed; volume = clip.volume; name = clip.name; audioVolumes = clip.audioVolumes ?? Array(repeating:1,count:clip.audioNames?.count ?? 0) } }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("CLIP INSPECTOR").font(.caption.bold()).foregroundColor(.secondary)
            if let clip = store.clip {
                Group {
                TextField("Clip name", text: $name)
                Text("SOURCE RANGE").font(.caption2.bold()).foregroundColor(.secondary)
                HStack { Text("In"); TextField("Seconds", value: $start, format: .number).textFieldStyle(.roundedBorder); Text("s") }
                HStack { Text("Out"); TextField("Seconds", value: $end, format: .number).textFieldStyle(.roundedBorder); Text("s") }
                Text("Source: \(timeLabel(clip.sourceDuration))").font(.caption).foregroundColor(.secondary)
                Picker("Speed", selection: $speed) { ForEach([0.25,0.5,1,1.5,2,4], id: \.self) { value in Text("\(value, specifier: "%.2g")×").tag(value) } }
                }
                Group {
                Text("Volume · \(Int(volume*100))%")
                Slider(value: $volume, in: 0...2)
                ForEach(audioVolumes.indices,id: \.self) { index in
                    VStack(alignment:.leading) {
                        Text("\(clip.audioNames.flatMap { index < $0.count ? $0[index] : nil } ?? "Audio \(index+1)") · \(Int(audioVolumes[index]*100))%") .font(.caption)
                        Slider(value:Binding(get:{ audioVolumes[index] },set:{ audioVolumes[index] = $0 }),in:0...2)
                    }
                }
                Button("Apply Changes") {
                    var changed = clip; changed.name = name; changed.start = start; changed.end = end; changed.speed = speed; changed.volume = volume; changed.audioVolumes = audioVolumes
                    do { try changed.validated(); store.update(changed) } catch { store.report(error) }
                }.buttonStyle(.borderedProminent).tint(.mint).disabled(store.busy)
                }
                SmartEditingPanel(clip:clip)
                Text("Edits preserve the original video. Speed changes also change audio playback speed.").font(.caption).foregroundColor(.secondary)
            } else { Text("Select a timeline clip to adjust its range, speed, and audio.").foregroundColor(.secondary) }
            Spacer()
        }.padding(18).onAppear(perform: load).onChange(of: store.clip) { _ in load() }
    }
}
