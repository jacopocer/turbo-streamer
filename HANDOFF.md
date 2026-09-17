# Turbo Streamer — Handoff / Deep State

Last updated by session that added the parallel-session workflow. Keep this current at push moments.

## What this is

A native macOS app (SwiftUI, Swift Package Manager, macOS 13+) that streams to one or more RTMP/RTMPS endpoints. The app is a thin **orchestrator**: all media work runs in separate bundled `ffmpeg` subprocesses. This is the core reliability decision — if ffmpeg chokes, it is an isolated process that dies and gets relaunched; the app itself stays up. Do NOT move capture/encode into the app process (that is the OBS crash model we are deliberately avoiding).

Repo: `github.com/jacopocer/turbo-streamer` (currently PUBLIC; owner is handling making it private). Local checkout: `/Users/jacopocerati/streamer`. Work from this checkout, not a worktree.

## Architecture & data flow

- `StreamManager` (`@MainActor` `ObservableObject`) is the brain: owns config, all process lifecycle, reconnect supervision, failsafe, the preview engine, overlay, device probing, debug logging.
- `ProcessRegistry` (thread-safe via `NSLock`) tracks the live-stream ffmpeg processes. `terminate` escalates SIGTERM then SIGKILL after 6s. `killAll` is used on app quit.
- Configure tab (`SetupView` → one `StreamConfigCard` per stream, with `OverlayEditor`) edits `manager.configs` (a `@Published [StreamConfig]`). `configs.didSet` persists to `UserDefaults` and syncs running previews.
- **Start Streams**: `startStreams()` creates a `RunningStreamRecord` (fresh UUID per launch) and a supervised `Task` per stream. The Task loop: pre-flight reachability check → run ffmpeg → on failure, exponential backoff (1,2,4,8,15s, reset after a healthy run) → repeat. Phase flips to Live when frames flow.
- `runFFmpeg` builds args (`buildArgs`), spawns the bundled ffmpeg, drains stdout+stderr via a single `readabilityHandler` (never a blocking read in the termination handler — that caused a crash/hang, fixed), parses live metrics, writes per-stream logs.
- A **hang watchdog** (process-matched) restarts ffmpeg if no frames arrive for 10s (capture unplug / frozen source / stuck RTMP). `freezedetect`/`blackdetect` produce a warning badge (not a restart, so static slates are not killed).
- Live tab (`ActiveStreamsView` → `StreamStatusCard`) shows phase, uptime/fps/bitrate/speed, the per-stream log, a freeze/black badge, and a live overlay-text control.

## Files (`Sources/Streamer/`)

- `StreamerApp.swift` — `@main`; loads bundled fonts; window is resizable + full-screen capable.
- `ContentView.swift` — root: header (wobbling app icon + Indigital logo top-right), custom two-tab bar, fills the window/full-screen.
- `Models.swift` — `StreamConfig` (Codable with a RESILIENT custom decoder so adding fields never wipes saved configs; includes the `fpsMatchSource` flag and the `StreamConfig.splitRTMPURL` paste helper), `TextOverlay`, `OverlayPosition`, `ResolutionPreset`/`RTMPPreset`/`InputType`, `StreamStatus` (parses ffmpeg progress for live metrics + freeze/black), `RunningStreamRecord`, `CaptureDevice`, `Profile` (named snapshot of all configs), `Diagnostic` (plain-language error catalog + matcher; `StreamStatus.currentDiagnostic` holds the active one).
- `StreamManager.swift` — everything dynamic (lifecycle, args, failsafe, preview, overlay, device + framerate probing incl. `probeFileFramerate` / match-source resolution, named-profile persistence, drop/recover webhook alerts). Largest file.
- `ProcessRegistry.swift` — process table + terminate/killAll.
- `Preflight.swift` — TCP reachability via `NWConnection`.
- `SetupView.swift` — Configure tab + footer (Preview Streams / Start Streams) + the **Profiles** menu (save/load/delete named config snapshots) and the **Alerts** webhook popover in the sub-header.
- `StreamConfigCard.swift` — per-stream config UI (Destination + "Paste full URL" splitter, Failsafe, Text Overlay, Video + FPS "Match source" toggle, Input) + device dropdowns + file/font pickers.
- `OverlayEditor.swift` — overlay styling controls; `Color(hex:)`.
- `LivePreviewBox.swift` — `LivePreviewBox` (refreshes the preview JPEG ~12fps) + `PreviewPanel` (pinned, vertically resizable, has the Refresh Preview button).
- `ActiveStreamsView.swift` — Live tab.
- `StreamStatusCard.swift` — per-stream live status card + the plain-language **diagnostic panel** (`diagnosticPanel`, driven by `StreamStatus.currentDiagnostic`).
- `FontLoader.swift` — registers bundled OTFs via CoreText at launch.

## How to build & run (exact)

```
cd /Users/jacopocerati/streamer
swift build -c release          # quick compile check
bash build.sh                   # compile + package "Turbo Streamer.app" (arm64) + bundle ffmpeg/dylibs/fonts + ad-hoc codesign
open "Turbo Streamer.app"       # run
```

- Universal (Intel + Apple Silicon): `bash build_universal.sh` (run from Terminal.app the first time; it installs x86_64 Homebrew + ffmpeg via Rosetta and asks for a password once).
- **Relaunch clean** (kill the running instance + any orphan ffmpeg, then open fresh):
  ```
  osascript -e 'tell application "Turbo Streamer" to quit'; pkill -x Streamer; sleep 1
  pkill -9 -f "Resources/bin/ffmpeg"; sleep 1
  open "Turbo Streamer.app"
  ```
- The app prefers the bundled ffmpeg, else `/opt/homebrew/bin/ffmpeg`. `build.sh` bundles `/opt/homebrew/bin/ffmpeg`, which MUST be the special build with `--with-decklink --with-srt --with-zeromq` (and `--enable-libfreetype/fontconfig/harfbuzz` for `drawtext`).
- To rebuild that ffmpeg (needed for DeckLink): download the Blackmagic Desktop Video SDK, copy its `Mac/include/*.h` and `*.cpp` to `/opt/homebrew/include`, patch `DeckLinkAPI.h` to define `IID_IUnknown` (SDK 12+ removed it), then:
  ```
  brew install homebrew-ffmpeg/ffmpeg/ffmpeg --with-decklink --with-srt --with-zeromq
  ```
- Locations: per-stream logs `~/Documents/TurboStreamer Logs/` (+ `preview-debug.log`, verbose, currently ON). Recordings `~/Documents/TurboStreamer Recordings/` (`.ts`, crash-safe). Preview/snapshot/overlay temp files `~/Library/Caches/TurboStreamer/`.

## What works

- 1–8 simultaneous RTMP/RTMPS streams; inputs: file loop, capture card (AVFoundation), Blackmagic DeckLink.
- Encoder: per-stream `videoCodec` (Auto / h264_videotoolbox / libx264 / hevc_videotoolbox), resolved in `resolveCodec`. Auto = libx264 (`veryfast`, `zerolatency`, `sc_threshold 0`) for ≤1080p; `h264_videotoolbox` for 4K ≤30 fps; at 4K >30 fps `hevc_videotoolbox` when the destination is SRT (Turbo Receiver) else libx264. Reason: measured on an M2 Pro, synthetic 4K60 → h264_videotoolbox 0.88× real-time (drops), hevc_videotoolbox 1.31×, libx264 veryfast 1.54×. The chosen encoder is logged at launch.
- Per-resolution auto bitrate; settings persist across launches (resilient decode).
- Failsafe suite (mostly opt-in, off by default): reconnect+backoff, hang watchdog, freeze/black detection, backup RTMP (`tee`), safety recording (`.ts`), recent-frame fallback (snapshot → slate), adaptive bitrate, pre-flight reachability, idle-sleep power assertion, lid-sleep warning, audible alerts (disconnect/recover/freeze).
- Text overlay: `drawtext` with font (bundled Sofia Pro / Bello Pro, or upload `.otf/.ttf`), size, colour, position, multi-line, background box. Text updates **live** on-air (textfile + `reload=1`); other style changes apply on **Refresh**.
- Live, pinned, resizable preview (`Preview Streams`) of the composed output, with a **Refresh Preview** button; full-screen via the green button.
- Wobbling health icon; child ffmpeg killed on app quit (no orphans).
- **FPS "Match source"** (per-stream `fpsMatchSource` flag): encode at the source's native rate instead of a typed value. Capture probes the device's highest native mode (`probeCaptureFramerate(preferMax:)`); file parses the rate from `ffmpeg -i` (`probeFileFramerate`). The rate is resolved ONCE at pre-flight, cached in `captureFramerate[id]`, and threaded through `buildArgs`/`buildSlateArgs` as a numeric `outputFPS`; the encode path stays CFR. `config.fps` is ALWAYS numeric (the fallback). DeckLink: available once `deckLinkFormat` is explicit (the rate comes from the format table in `DeckLinkFormat.fps`); with Auto-detect the toggle is hidden because the rate is unknown before the card reports it.
- **Paste-a-URL splitter**: a "Paste full URL" button in each Destination section reads the clipboard, splits a combined `rtmp(s)://host/app/streamkey` into URL + key via `StreamConfig.splitRTMPURL`, and flips the preset to Custom. The splitter refuses to mis-split a keyless URL or a non-rtmp string (unit-checked, 9 cases).
- **Named profiles**: the "Profiles" menu in the Configure header saves/loads/deletes named snapshots of all stream configs (`Profile` in Models, persisted in `UserDefaults` under `profilesKey`). Loading swaps the editable configs only — running streams (which hold their own snapshots) are untouched.
- **Plain-language diagnostics**: a `Diagnostic` catalog (`Models.swift`) translates known ffmpeg/app failure signatures into a friendly "What's happening" callout atop each Live card (`StreamStatusCard.diagnosticPanel`) — title + what-it-means + a fix tip — while the raw technical log stays untouched below. Matching runs in `StreamStatus.appendLog` (first match per batch; cleared when a progress line shows frames resuming). Copy is themed in a **Topolino & Pippo** voice (owner's pick); the catalog and the freeze/black badge text (`StreamStatus.frozenBadge`/`blackBadge`) are plain data — re-theme by editing strings, the `match:` arrays (the real triggers) stay. Deliberately a focused ~12-entry set (connection / input / device / disk / engine) to avoid false alarms on benign log noise.
- **Drop/recover webhook alerts** (opt-in, off by default): a global "Alerts" webhook URL (Configure-header popover, persisted in `UserDefaults`). On a real drop (a healthy stream — ran > `healthyRunSeconds` — going down) and the paired recover, the app fires a fire-and-forget JSON POST `{app, event, stream, message, time}` (`sendWebhookAlert` → `Task.detached`, errors swallowed — never blocks or affects the stream). Pairing is centralized in `streamDropped`/`streamRecovered` over a `droppedStreams` set; "Send test" reports the HTTP outcome. Point the URL at Zapier/Make/Slack/Telegram to reach WhatsApp/email/SMS.

- **Live mute/unmute** per stream: the audio chain always carries a `volume` filter, and the toggle sends ffmpeg a runtime filter command on **stdin** (`cvolume -1 volume 0`). Nothing restarts, the video is untouched. `runFFmpeg` keeps stdin as a `Pipe` per stream; SIGPIPE is ignored so writing to a dead ffmpeg can't kill the app. `mutedStreams` seeds the filter's initial value, so a reconnect comes back muted.
- **SRT output** for the low-latency WAN hop: if the destination URL starts with `srt://`, buildArgs switches to MPEG-TS and passes `-srt_streamid publish:<key>` plus a configurable `srtLatencyMs` (default 120). SRT absorbs packet loss with retransmission inside that budget instead of stalling like TCP/RTMP. tee is disabled on SRT (per-target streamid can't be expressed), so backup RTMP and safety recording are skipped on that path.
- **Pairing via turbolink** (`link-server/`, live at `turbostreamer.indigital.tv`): instead of pasting URLs, Turbo Streamer shows a 6-character code ("Link receiver" in the Destination section) and each Turbo Receiver enters it ("Link" on the feed card), publishing where it can be reached. The streamer polls and fills URL, key and SRT latency with one click. **The server only ever holds coordinates, never video**, so the direct low-latency path is untouched. Endpoint overridable via the `TurboStreamer.linkBase` / `TurboReceiver.linkBase` defaults for testing against a local instance.
- **Network input** (`InputType.network` + `networkURL`): consume a live RTSP/RTMP/SRT/HTTP source — typically a feed served by Turbo Receiver — and restream it. No `-re`/`-stream_loop` (a live source paces itself); RTSP is forced over TCP.

## Turbo Receiver (second app, `receiver/`)

Separate SwiftPM package, same orchestrator model: a thin SwiftUI shell around a bundled **MediaMTX** (single static Go binary, MIT). The app moves no pixels.

- One sender publishes to `rtmp://<host>:1935/<key>`; MediaMTX republishes the same stream simultaneously on **RTSP :8554**, **RTMP :1935** and **HLS :8888**, so N readers consume it at once (OBS and other Turbo Streamer instances over RTSP; TVs/browsers over HLS).
- Only declared keys go into the generated config, so the 24-char key is the publish secret and unknown paths are refused.
- Paths are added/removed at runtime through the MediaMTX API (`:9997`), so adding a feed needs no restart. Status polling reads `ready`/tracks/readers and derives bitrate from the byte delta.
- Address picker lists every non-loopback IPv4 and prefers a Tailscale `100.x`.
- **NDI output** (for the BirdDog decoders): per enabled feed the app runs ffmpeg (decodes into two FIFOs: raw UYVY422 + s16le) and `ndi-sender` (`receiver/ndi/`, C, links the NDI runtime). Clocking is off because the source is already live. A supervisor restarts the bridge if either process dies while NDI is still on. `ndi-find` lists NDI sources from a terminal, which is how the sender is verified without a GUI.
- `fetch-mediamtx.sh` pulls the binary into `vendor/` (gitignored); `build-ndi.sh` compiles the NDI tools against the SDK headers (`NDI_SDK_DIR`, or the DistroAV checkout).
## Known bugs / gotchas (do not rediscover these)

- `build.sh` bundles only an ffmpeg that **runs and is fit** (arm64, `--enable-libsrt`, `--enable-decklink`) and otherwise stops; the bundle it is rebuilding is never a source. This exists because a rebuild once fell through to a stale x86_64 `./bin/ffmpeg` without SRT or DeckLink and the app kept building. Homebrew's ffmpeg needs the `homebrew-ffmpeg/ffmpeg` tap trusted (`brew trust`) for its dependencies to install. `receiver/build.sh` copies the set from `Turbo Streamer.app`. Do not "simplify" any of this back to an existence check.
- **DeckLink input options** (`deckLinkInputOptions`): `-format_code` only when not Auto, `-video_input` only when not "Card default", `-raw_format uyvy422` or `yuv422p10`. ffmpeg accepts them (verified: fails only at device open without a card). **Not yet run against a physical card** — 2160p60 capture is the expected use; verify on hardware first.
- **10-bit chain order**: with `deckLinkTenBit` + HEVC the `format=p010le` conversion goes LAST (after freeze/black detectors and drawtext). Placed first, ffmpeg auto-inserts p010le→yuv420p10le→p010le around the detectors: 1.09× vs 1.36× at 4K60.
- MediaMTX binds listeners **IPv6-only** when the address is written as `:port`. An IPv4 client then never reaches it and MediaMTX logs nothing at all, because the packets never arrive — this cost real debugging time on SRT. The receiver now writes every listener as `0.0.0.0:port`.
- ffmpeg **ignores `streamid` in an SRT query string**. It must be passed as the dedicated option: `-srt_streamid publish:<path>`. The path travels in the streamid, not in the URL.
- MediaMTX HLS defaults to `hlsVariant: lowLatency`, which sits behind a `cookieCheck` redirect that returns **404** to ffmpeg and VLC. The receiver generates `hlsVariant: mpegts` + `hlsAlwaysRemux` so ordinary players and TVs work.
- NDI needs **NDI Tools installed** (`/usr/local/lib/libndi.dylib`); `ndi-sender` links it via rpath. NDI output can only be switched on while a feed is actually live, because ffprobe reads the format from the running source.

- ffmpeg `image2` file outputs MUST include `-y`, or on a restart the existing file triggers "Overwrite? [y/N] Not overwriting - exiting" and the process dies with no frames. This is fixed for preview + snapshot; remember it for any new file output.
- `config.id` is PERSISTENT (saved). Preview/overlay/snapshot cache files are keyed by it, so they survive across runs. Orphaned ffmpeg from a previous run will fight over the same files — the on-quit `killAll` prevents this; do not regress it.
- AVFoundation cameras reject arbitrary framerate/pixel format. We probe the device's supported framerate (`probeCaptureFramerate`) and do NOT force `-video_size`. The "pixel format (yuv420p) not supported" stderr line is a non-fatal warning.
- DeckLink: the installed Blackmagic Desktop Video DRIVER must be >= the SDK ffmpeg was built against (16.0). On a target Mac, update Desktop Video.
- Distribution to OTHER Macs: ad-hoc codesigning hits Gatekeeper/quarantine and flaky camera TCC. True double-click-and-run needs Developer ID + notarization. See README Status section.
- Verbose `preview-debug.log` logging is currently ON (it caught the overwrite bug). Owner may ask to trim it.

## Open requests / next steps

- Owner is KEEPING the verbose preview debug logging ON (used for testing) — do not trim without asking.
- **DONE — drop/recover webhook alerts shipped** (see What works). Future idea: optional native Telegram/Slack/Discord presets so users skip the Zapier/Make bridge.
- **DeckLink "Match source" with Auto-detect** — works only with an explicit Format today. Parsing the detected mode from ffmpeg's log (`Found Decklink mode W x H with rate R`) at pre-flight would remove that limit; needs the physical card to verify the log line.
- `-pixel_format` on AVFoundation input — **decided against**: the yuv420p warning is harmless, the filter chain forces yuv420p downstream anyway, and a safe version needs a per-device probe for near-zero benefit.
- Distribution: Developer ID + notarization if it ships beyond the owner's machines.

## Deferred / researched (do NOT build unless explicitly asked)

- Zero-gap seamless source failover via a persistent local relay/compositor. Researched and prototyped: ffmpeg `streamselect` + ZeroMQ can switch sources on one continuous output, BUT it stalls when the live input physically dies. True zero-gap needs a real compositor (libobs-grade). Big project; owner chose to keep the simpler slate-on-reconnect.
- Instant live style updates via ffmpeg `zmq` + `drawtext reinit` (no camera re-open). Offered; owner chose the Refresh Preview button instead.

## Durable decisions (do not relitigate)

- App orchestrates; ffmpeg does the work in subprocesses. Crash isolation is the whole point.
- Encoder defaults to Auto; the per-stream Codec picker overrides it.
- Recording is `.ts` (survives an abrupt kill).
- Failsafe features are opt-in and off by default; the default path stays dead simple.
- The owner wants a RELIABLE, SIMPLE streamer, not OBS. Push back on features that add crash surface. When in doubt, stop and ask.

## Ideas backlog (not committed to)

Audio VU meter, desktop notifications, manual cut-to-standby, scheduled go-live / countdown card, menu-bar status, save/load named profiles, paste-a-URL helper (split into URL+key), webhook/email alert on drop, launch-at-login.
