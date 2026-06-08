# Turbo Streamer — Parallel Session Logbook

Multiple AI chat sessions edit this repo at the same time. **Read this file before you write or edit anything, and reserve files before touching them.** This prevents sessions from stomping each other.

## Protocol

1. **Pick a session handle** when you start: `<word>-<n>`, e.g. `falcon-2`, `mako-1`. Tell the user your handle. Use it in every entry below.
2. **Reserve before editing.** Add a `🔄 IN PROGRESS` entry at the TOP of the LOG with: your handle, the files/areas you will touch, a one-line plan, and an ETA.
3. **Check for conflicts.** If an existing `🔄` entry reserves files in your scope, route around them or wait. Do not edit another session's reserved files.
4. **On commit:** replace your `🔄` entry with a `✅ DONE` entry: handle, files touched, what changed semantically, and the commit SHA.
5. **Pruning:** `✅ DONE` entries get folded into `HANDOFF.md` at a handoff moment, then removed here to keep this short.
6. **Do not `git push` without the user's explicit OK.** Local commits are fine.

## LOG (newest first)

### 🔄 IN PROGRESS
_(none)_

### ✅ DONE (not yet folded into HANDOFF.md)
- `comet-1` — FPS "Match source" (capture/file; DeckLink deferred), paste-a-URL splitter, save/load named profiles; skipped `-pixel_format` (low value). `Models.swift`, `StreamManager.swift`, `StreamConfigCard.swift`, `SetupView.swift`, `.gitignore`, docs. Folded into HANDOFF.md. Commit `88f82f8`. (GUI click-through still pending owner verification; next up = generic-webhook drop/recover alerts.)
- `setup` — added `SESSIONS.md` + `HANDOFF.md` and the parallel-session workflow. (commit pending)
- prior single-session history (pre-workflow), newest first:
  - Refresh Preview button; removed auto-restart-on-edit. `StreamManager.swift`, `LivePreviewBox.swift`.
  - Fix preview freeze: add `-y` to overwrite ffmpeg file outputs (preview + snapshot). `StreamManager.swift`.
  - Instrument preview lifecycle with debug logging. `StreamManager.swift`.
  - Kill child ffmpeg on app quit (fixes orphan clashes). `ProcessRegistry.swift`, `StreamManager.swift`.
  - Pinned + resizable live preview, real full-screen, live preview sync via `configs.didSet`. `ContentView.swift`, `StreamerApp.swift`, `LivePreviewBox.swift`, `SetupView.swift`.
  - Live, running, resizable preview + "Preview Streams". (superseded preview window)
  - Text overlay (drawtext) with font/size/colour/position, custom font upload, live text, ffmpeg-rendered preview.
  - Camera fixes: probe device framerate, drop forced `-video_size`.
  - Reliability hardening pass (pipe-read crash/hang, leaks, force-unwraps, graceful shutdown, power assertion, sleep warning, regular keyframes).
  - Failsafe suite: fallback slate / recent-frame fallback, adaptive bitrate, backup RTMP, safety recording, watchdog, freeze/black, pre-flight, alerts.
  - DeckLink support (rebuilt ffmpeg with `--with-decklink`, patched SDK headers) + VideoToolbox realtime fix.
  - Config persistence, auto-bitrate, live metrics, encoder auto-select.
  - Two-tab UI, dark theme, fonts, wobbling icon, multi-stream RTMP core.
