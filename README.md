# FrameForge 0.4

Native macOS 13+ recording and editing app. This development build implements the core workflow and the requested source controls. Full ScreenFlow parity and comparative performance superiority remain unfinished goals.

## Launch and record

Open `build/FrameForge.app`. This delivery is Apple Silicon; run `scripts/build.sh` to rebuild on an Intel Mac. The app is locally ad-hoc signed, not notarized for distribution.

1. Choose a named **Display**. Connected monitors and microphone devices are listed even before screen-capture permission is granted.
2. Select **Entire display** or **Selected region**, then **Select Region…**. Drag on the chosen display and release to accept; Escape cancels. Reselect changes the area. Changing display clears the old region. Coordinates account for monitor placement and Retina scaling.
3. Set **Capture size** and **Frame rate**. 1080p max and 4K max limit the long edge without upscaling small selections. This avoids asking H.264 to encode oversized desktop modes such as a 6720-pixel display.
4. Set **Microphone** to Off, System default input, or a particular hardware/virtual input device. USB and other external audio inputs can appear here.
5. Enable **Record system / output audio** independently. **All applications** captures computer sound; after **Refresh Sources**, a specific application can be chosen. This selects application audio, not a physical speaker/output device. Microphone and system audio can be enabled together or separately. All-application capture excludes FrameForge's own preview audio.
6. Click **Start Recording**. macOS may request Screen Recording and Microphone access. Stop with the app button, its menu-bar control, or the global ⌥⇧R shortcut (⌘⇧R remains an alias). The shortcut requires no Accessibility permission; if another app has reserved it, use the menu-bar control instead.
7. Recordings are saved in `~/Movies/FrameForge`. Successful recordings are appended to the timeline. The editor itself is excluded from display capture.

### Permissions

For macOS 26, enable this exact app in **System Settings → Privacy & Security → Screen & System Audio Recording**, and enable **Microphone** if recording narration. Older macOS may call the first setting **Screen Recording**. Quit and reopen FrameForge after changing access. If macOS only lists the previous development build, add the current `build/FrameForge.app` using the + button. Rebuilding an ad-hoc signed app can require granting access again. The app translates the raw TCC denial into these instructions.

## Edit and export

Import video with ⌘I. Select a timeline clip, change its In/Out range, speed, master volume or individual audio-source volumes, then **Apply Changes**. Use the playhead and **Split**, move earlier/later, duplicate or delete. Undo/redo uses ⌘Z / ⌘⇧Z.

Save a `.frameforge` project with ⌘S; open with ⌘O. Project files store edit decisions and media paths, so keep the original files in place. Existing 0.1 projects remain supported.

Export H.264 or HEVC MP4 at 720p, 1080p or 4K and 30/60 fps. Export audio mixes all source tracks with their individual volume settings. An existing destination is replaced only after encoding succeeds. Export progress and cancellation are available. Quitting during a recording attempts to finish the movie first; errors keep the app open.

## Changes in 0.4

Press **Option + Shift + R** anywhere while FrameForge is running to start recording with the selected sources; press again to stop. Command + Shift + R remains an alias. If the primary shortcut is unavailable, the app shows a menu-bar fallback hint. The first recording can require macOS permissions; selected-region mode opens the region picker if no region has been chosen.

**Copy recording to clipboard** is enabled by default and remembered across launches. After the movie finishes saving, its file URL is copied using the macOS file pasteboard representation. Paste into apps that accept video/file attachments, or into Finder. Receiving-app support varies; this does not paste playable video into plain text fields. The original movie remains in Movies/FrameForge, and mouse edits still require export to create an edited movie. Failed recordings leave the clipboard unchanged.

## Changes in 0.3.2

New recordings default to 4K capture to preserve source detail for mouse zooms on a 1080p canvas. The lower-load 1080p option remains available. The clip inspector warns when the chosen zoom requires enlarging source pixels at the current canvas size. Zoom transforms operate directly on the original source in one composition pass. Existing low-resolution media cannot regain discarded detail; 4K capture increases recording and decoding load. A native 3840×2160 source allows up to 2× zoom on a 1920×1080 canvas without spatial upscaling; 2.5× still enlarges pixels.

## Changes in 0.3.1

Recording now requests NV12 video surfaces, explicitly enables hardware encoding, disables frame reordering, skips idle duplicate encodes while preserving elapsed duration, and pauses editor playback. Microphone meter updates are limited to five per second. These changes reduce capture load; cursor responsiveness still needs a real recording comparison on the affected display.

## Changes in 0.3

- Microphone capture now explicitly requests 48 kHz mono Float32 PCM and saves that track losslessly. A 50% default input gain and peak limiter provide headroom; the live meter warns when the incoming device signal is already clipped. Lower hardware input gain if that warning persists: clipping at the device cannot be repaired downstream.
- Enable **Track mouse** before recording. Select the resulting clip and choose **Follow mouse** or **Focus clicks** under Smart Editing, with adjustable zoom. Smooth pan/zoom is shared by preview and export. Cursor metadata is saved beside the movie and embedded into imported project clips; old recordings without metadata cannot automatically follow the mouse.
- **Analyze & Preview Cuts** detects pauses in a selected audio source. Set the silence threshold and minimum pause, preview the retained sections, then apply or cancel. Video and all associated audio are cut together, originals remain untouched, and the operation can be undone.

## Changes in 0.2

- Replaced SwiftUI VideoPlayer with a native AppKit AVPlayerView to avoid the `_AVKit_SwiftUI` class-metadata abort in the supplied macOS 26 crash report. Imported video playback was verified after this change.
- Added named displays, drag-selected regions, independent microphone/system-audio controls, microphone-device discovery and application-specific output audio.
- Retain every audio track through composition and export, including original silent offsets; added per-source volume controls.
- Added capture-size limits, global recording shortcut, menu-bar timer/control, dropped video/audio counts, earlier encoder failures and no-frame timeout.
- Reuse the last complete image for idle screen frames and close static spans at stop time, avoiding a timeline that ends early when the desktop stops changing. Live permission-gated recording still needs validation.
- Serialized writer operations, placed microphone configuration on a background queue, and aligned microphone timestamps to the host clock.
- Added readable permission errors and recording finalization when quitting.

## Verification

Release compilation and local signing pass. Model/geometry tests pass, including Retina scaling, region clipping, minimum region size, trim/split validation, per-source audio validation and old-project decoding. A real synthetic video with two distinct audio tones was imported and played in the running native app. H.264 export produced 1920×1080, 30 fps, 2.0-second video with AAC audio. Spectral checks confirmed both tones and the microphone track's 250 ms initial silent offset.

The composition suite checks real video import, two-track retention, trim/split/speed timing, transforms and serialization. The command-line AVFoundation encoder harness remains limited by error -11834 in the tool execution environment; native-app H.264 export succeeded.

The 0.3 PCM checks verify waveform preservation, gain, overload limiting, sample duration and host timestamps. Mouse-focus smoothing, viewport bounds and silence planning pass automated checks. Native-app silence analysis and preview successfully reduced a six-second synthetic demo to two retained sections. Native H.264 mouse-focus export produced six seconds of 1920×1080 video with 48 kHz AAC audio. Fresh hardware microphone capture, app-specific audio capture, recording drift, HEVC export and sustained capture performance still require validation. Earlier raw recordings had excessive microphone levels; the exact hardware contribution remains unconfirmed. The drag-selection overlay was exercised interactively and accepted a region correctly. No ScreenFlow comparison has been performed.

## Build and checks

```sh
./scripts/build.sh
./scripts/test.sh
./scripts/test.sh --composition
./scripts/test.sh --integration
```

The composition fixture uses an already-installed ffmpeg; nothing is installed automatically. The app itself does not depend on ffmpeg. Direct swiftc builds work with Command Line Tools. Package.swift is provided for full Xcode installations; older Command Line Tools may lack metadata required by SwiftPM.

## Remaining limitations

Sequential video lane with associated audio, not a multitrack visual compositor. Audio follows speed without pitch preservation. No camera recording, pause/resume, window-only capture, text/annotations, transitions, captions, effects, portable project bundles or ScreenFlow project import yet. Unexpected process termination still has no recording recovery. A preview/export source must contain video. Production distribution needs Developer ID signing and notarization. See ROADMAP.md for remaining work and measurable performance targets.
