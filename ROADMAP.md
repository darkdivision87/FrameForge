# Product roadmap and acceptance plan

Reference: [ScreenFlow 10.5 User Guide](https://www.telestream.net/pdfs/user-guides/ScreenFlow-10-User-Guide.pdf). This is an independent implementation; no Telestream code or assets are included. The categories below are planning work, not implemented features.

## Delivered milestone

Native editor, full-display and dragged-region recording, named monitor selection, microphone device selection, independent system/app audio, separate audio tracks and per-source volumes, global recording shortcut, menu-bar timer/stop control, capture resolution limits, cursor visibility, video import, sequential clip editing, split, trim, reorder, duplicate, delete, speed, volume, undo/redo, preview, project save/load, H.264/HEVC MP4 export, resolution and frame-rate selection, export progress and cancellation.

## Remaining milestones

1. **Capture reliability:** validate microphone/system/app-audio synchronization and region capture under real permissions; add camera, window capture, simultaneous multiple displays, pause/resume, countdown, scheduled stop, capture markers, device sources and interruption recovery; extend current dropped-frame telemetry. Keep recordings recoverable through periodic segments rather than a single unfinalized file.
2. **Timeline:** multiple video/audio lanes, arbitrary start times, snapping, ripple/rolling edits, gaps, markers, track mute/solo/lock, nesting, grouping, freeze frames, thumbnails, waveforms, proxy media, missing-file relinking, background autosave and portable project bundles.
3. **Compositing:** spatial transforms, cropping, animated keyframes, easing, transitions, text, shapes, annotations, callouts, cursor/click/key visualization, zoom-follow, reusable presets. Share one render graph across preview and export, with Metal/Core Image rendering and a bounded texture cache.
4. **Audio:** narration, meters, fades, mixing, ducking, noise reduction, equalization, pitch-correct time stretching, multichannel support, independent per-app audio where platform support permits.
5. **Effects and captions:** color correction and LUTs, chroma key, masks/background removal, filter ordering, transcription with explicit model/language choice, editable captions, SRT import/export and subtitle rendering.
6. **Media and delivery:** still images/slides, library search, templates, reusable assets, export presets, batch jobs, GIF/APNG, additional codecs, optional service publishing with separately authorized account connections. Third-party stock assets need a licensed source.
7. **Shipping:** accessibility, localization, drag/drop, icons, multiwindow document lifecycle, complete automated tests, sustained recording tests, crash reporting by consent, Developer ID signing, notarization, update delivery, installer and release notes.

## Performance targets — not yet measured

Compare equal content, output settings and quality on the same Mac against ScreenFlow. Include short and long recordings, dense multitrack edits, high-motion screen content and 4K output. Warm and cold runs should be reported separately. Keep the source set and benchmark procedure reproducible.

- Capture: sustained 4K/60 where hardware permits, <0.1% dropped frames, stable memory over a 60-minute session, measured audio/video drift under 20 ms.
- Editor: responsive controls while importing/exporting, p95 seek-to-visible-frame under 100 ms on proxy media, bounded cache memory and prompt cancellation of stale preview jobs.
- Export: compare wall-clock time, file size, quality metrics, energy use and peak resident memory; target at least a 20% time reduction at equivalent quality before advertising an advantage.
- Reliability: interrupted recording recovery, low-disk handling, missing media, corrupt files, permission revocation, display disconnect and export cancellation.

ScreenFlow feature parity is not complete until these workflows have implemented acceptance tests and interactive review. Performance superiority is not established by choosing native APIs alone.
