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
- `comet-1` — Embedded Tailscale (tsnet helper `net/turbo-net`, join keys minted by turbolink `/v1/tailnet/key`), Receiver listens on the tailnet, Streamer dials through it. Files: `net/`, `link-server/index.js` + unit, `Sources/Streamer/TurboNet.swift` (new), `StreamManager.swift`, `receiver/Sources/Receiver/TurboNet.swift` (new), `ServerManager.swift`, `ContentView.swift`, both `build.sh`, docs. ETA: this session.

### ✅ DONE (not yet folded into HANDOFF.md)
- `comet-1` — Relay option B (turbolink relay secrets + `/v1/auth`, MediaMTX relay deploy assets), Streamer "Use relay" + SRT pre-flight probe with RTMP fallback + network passthrough + srt streamid input + encoder-behind diagnostic + slate on SRT; Receiver Direct/Relay per feed, MoQ off. Verified locally end to end; box deploy `deploy-relay.sh` owner-run. Docs updated. Both apps rebuilt + installed. Commit `39c3678`.
- `comet-1` — DeckLink Format/Connector/10-bit controls + per-stream Codec picker (4K60: HEVC hw to SRT, x264 to platforms; h264 hw measured 0.88× on M2 Pro), Match source for explicit DeckLink formats; bundle renamed `Turbo Streamer.app`. `Models.swift`, `StreamManager.swift`, `StreamConfigCard.swift`, build scripts, docs. Both apps rebuilt + installed. Commit `56438ca`. Not run against a physical DeckLink.
- `comet-1` — **Turbo Receiver** (new app, `receiver/`): MediaMTX ingest + RTSP/RTMP/HLS fan-out, NDI output for BirdDog decoders, HLS served as mpegts for TVs. Commits `7970ba3`, `43ada29`, `a641cc9`. Folded into HANDOFF.
- `comet-1` — Turbo Streamer: live gap-free **mute/unmute** (`b2953d8`) and **network input** so an instance can consume a Receiver feed and restream it (`9ab25bf`). Folded into HANDOFF.
- `comet-1` — `build.sh` now selects an ffmpeg that actually runs (Homebrew's is broken here). Both apps rebuilt and installed to /Applications.
- `comet-1` — Drop/recover webhook alerts (opt-in global URL + fire-and-forget POST, paired drop/recover via `streamDropped`/`streamRecovered`, Alerts popover with Send-test feedback). Incl. all 11 /code-review fixes. `StreamManager.swift`, `SetupView.swift`, docs. Folded into HANDOFF. Commit `54ca0b8`, pushed.
- `comet-1` — App icon replaced with new face image: `Resources/AppIcon.icns` regenerated (squared to 1024² transparent + iconutil); the in-app wobbling icon derives from `applicationIconImage`, so it updates automatically. Rebuilt + installed to /Applications. Commit `e50bbee`, pushed.
- `comet-1` — Plain-language diagnostics: `Diagnostic` catalog + "What's happening" panel atop each Live card; **Topolino & Pippo** voice; freeze/black badges re-themed. `Models.swift`, `StreamStatusCard.swift`, docs. Folded into HANDOFF.md. Commit `7953214`. (Matcher unit-tested 15/15; panel rendering pending owner's visual check.)
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
