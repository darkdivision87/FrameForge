import SwiftUI

struct RecordingPanel: View {
    @EnvironmentObject var store: Store
    var body: some View {
        VStack(alignment:.leading,spacing:14) {
            Text("RECORDING SOURCES").font(.caption.bold()).foregroundColor(.secondary)
            VStack(alignment:.leading,spacing:12) {
                Group {
                    Picker("Display",selection:Binding(get:{ store.displayID },set:{ store.changeDisplay($0) })) {
                        Text("Select display").tag(UInt32(0))
                        ForEach(store.displayOptions) { display in Text(display.name).tag(display.id) }
                    }
                    Button("Refresh Sources") { Task { await store.refreshDisplays() } }
                    Picker("",selection:$store.regionMode) {
                        Text("Entire display").tag(false); Text("Selected region").tag(true)
                    }.pickerStyle(.segmented).accessibilityLabel("Recording area")
                    if store.regionMode {
                        HStack { Button(store.region == nil ? "Select Region…" : "Reselect…") { Task { await store.chooseRegion() } }; Spacer() }
                        Text(store.regionLabel).font(.caption).foregroundColor(.mint)
                    }
                    Picker("Capture size",selection:$store.maximumCaptureDimension) {
                        Text("1080p · lower load").tag(1920); Text("4K · sharper zoom").tag(3840)
                    }
                    Text("4K preserves detail for zooms in a 1080p export. 1080p uses fewer resources. Small regions retain their native size.").font(.caption2).foregroundColor(.secondary)
                    Picker("Frame rate",selection:$store.captureFPS) { Text("30 fps").tag(30); Text("60 fps").tag(60) }
                }
                Group {
                    Divider()
                    Text("AUDIO INPUT").font(.caption2.bold()).foregroundColor(.secondary)
                    Picker("Microphone",selection:$store.microphoneID) {
                        Text("Off").tag("off"); Text("System default input").tag("default")
                        ForEach(store.microphones) { device in Text(device.name).tag(device.id) }
                    }
                    Toggle("Record system / output audio",isOn:$store.systemAudio)
                    if store.systemAudio {
                        Picker("Audio source",selection:$store.audioApplicationID) {
                            Text("All applications").tag(Int32(0))
                            ForEach(store.audioApplications) { app in Text(app.name).tag(app.id) }
                        }
                    }
                    Text("Microphone and output audio are saved separately, with individual volume controls in the editor. Output audio follows the selected applications, across output devices.").font(.caption2).foregroundColor(.secondary)
                    Toggle("Show cursor",isOn:$store.showCursor)
                    Toggle("Track mouse for editing",isOn:$store.trackMouse)
                    Toggle("Copy recording to clipboard",isOn:$store.copyRecordingToClipboard)
                    Text("After stopping, paste the video into apps that accept file attachments. The original stays in Movies/FrameForge.").font(.caption2).foregroundColor(.secondary)
                }
            }.disabled(store.busy || store.recording)
            if store.microphoneID != "off" {
                VStack(alignment:.leading,spacing:6) {
                    Text("Mic input · \(Int(store.microphoneGain*100))%") .font(.caption)
                    Slider(value:Binding(get:{ store.microphoneGain },set:{ store.setMicrophoneGain($0) }),in:0...1)
                    ProgressView(value:min(1,max(0,(store.microphoneLevelDB+60)/60))).tint(store.microphoneOverload ? .red : .mint)
                    Text(store.microphoneOverload ? "Input clipping: reduce the device's gain" : store.recording ? String(format:"Input peak %.0f dB",store.microphoneLevelDB) : "Level meter appears while recording") .font(.caption2).foregroundColor(store.microphoneOverload ? .red : .secondary)
                }
            }
            Button {
                Task { if store.recording { await store.stopRecording() } else { await store.startRecording() } }
            } label: {
                Label(store.recording ? "Stop Recording" : "Start Recording",systemImage:store.recording ? "stop.circle.fill" : "record.circle").frame(maxWidth:.infinity)
            }.tint(store.recording ? .red : .mint).buttonStyle(.borderedProminent).disabled(store.busy)
            Text("\(store.recordingShortcutHint). Recordings save to Movies/FrameForge.").font(.caption).foregroundColor(.secondary)
        }
    }
}
