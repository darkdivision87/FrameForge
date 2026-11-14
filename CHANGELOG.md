# FrameForge 0.5.0

- New mint-and-graphite macOS icon, including standard and Retina sizes and the editor header.
- Shift + Command + S selects a region and begins recording; press again to stop. The menu-bar stop control remains available.
- FrameForge hides during region selection and recording, then returns with the newly recorded clip selected. Cancellation and startup errors restore the editor.
- Mouse tracking and zoom default to off. Tracking is easy to enable before recording; active mouse zoom is highlighted in the editor.
- Quick range editing: mark In/Out, drag the handles or enter exact seconds, then Remove Range. Cuts work across clips, close gaps, preserve associated audio, and support Undo/Redo.
- Automatic USB microphone selection, remembered device preference, and connection updates. Automatic mode never selects the built-in computer microphone; explicit manual choices remain available.

Apple Silicon build for macOS 13+. Locally ad-hoc signed and not notarized. Screen Recording and optional Microphone permissions are required. Live recording with the updated build still needs hardware verification.

Validation: optimized compilation, code-signature verification, DMG checksum verification, model tests, and two-source media-composition tests pass. In-app checks covered range removal, Undo, region-selection cancellation, the recording shortcut, USB microphone discovery, and icon rendering.
