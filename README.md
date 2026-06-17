# Turbo Streamer

A native macOS app for streaming video files and capture cards to RTMP endpoints — simultaneously, reliably, with no terminal required.

---

## Status — where we're at

A native macOS SwiftUI shell that orchestrates **bundled ffmpeg** subprocesses. Feature-complete and reliability-hardened for a *simple, dependable* multi-stream RTMP streamer. The architecture (app orchestrates, ffmpeg does the work in isolated processes) means a streaming failure restarts ffmpeg, not the app.

### Core capabilities

| Area | Status | Notes |
|---|---|---|
| Multi-stream | ✅ | 1–8 simultaneous RTMP streams |
| UI | ✅ | Two tabs — **Configure** (build streams while others run) + **Live** (monitor) |
| Inputs | ✅ | File loop · Capture card (AVFoundation) · **Blackmagic DeckLink** |
| Destinations | ✅ | Mux / YouTube / Vimeo presets + Custom; RTMP **and RTMPS**; paste a full URL to auto-split into URL + key |
| Encoder | ✅ | **Auto** — libx264 (≤1080p) / VideoToolbox (4K). No toggle to get wrong |
| Bitrate | ✅ | Auto-fills per resolution (1080p 5872k, 4K 16000k) |
| Frame rate | ✅ | Per-stream; **Match source** encodes at the camera/file's native rate |
| Settings | ✅ | Persist across launches; resilient decode (updates won't wipe them); **save/load named profiles** |
| Live metrics | ✅ | Uptime · fps · bitrate · speed per stream |
| Diagnostics | ✅ | Plain-language **"What's happening"** card translates ffmpeg/app errors into a friendly explanation + fix tip; raw log stays |
| Live preview | ✅ | **Preview Streams** (next to Start) shows each stream's composed output running live in a **pinned, resizable** panel (stays put while you scroll the settings); overlay/style changes update it in real time |
| Text overlay | ✅ | Lower-third/standby text — font (bundled or **upload your own**), size, colour, position, multi-line, background box; **live-editable on-air**, shown in the live preview |
| Branding | ✅ | Dark theme, Sofia Pro + Bello Pro fonts; health-reactive wobbling icon |

### Failsafe / reliability

| Feature | Default | What it does |
|---|---|---|
| Auto-reconnect + backoff | always on | 1→2→4→8→15s, resets after a healthy run |
| Hang watchdog | always on | No frames 10s → restart + re-acquire device |
| Freeze / black detection | always on | Warns when feed freezes or goes black |
| Pre-flight check | always on | Verifies destination reachable before air |
| Audible alerts | always on | Chimes on disconnect / recover / freeze |
| Graceful shutdown | always on | SIGTERM→SIGKILL escalation; clean file finalize |
| Power assertion | always on | Blocks idle-sleep while live; warns on lid-close sleep |
| Recent-frame fallback | opt-in | Holds last good frame on-air if input drops |
| Backup RTMP | opt-in | Second ingest via `tee` (failure can't kill primary) |
| Safety recording | opt-in | Records `.ts` to disk while streaming (crash-survivable) |
| Adaptive bitrate | opt-in | Drops bitrate on instability, steps back up |
| Drop/recover alerts | opt-in | Fire-and-forget webhook POST on drop & recover (→ Zapier/Make → WhatsApp/email) |

### Known limitations

| Caveat | Detail |
|---|---|
| Fallback has a ~1–2s cut | True zero-gap needs a compositor (out of scope) |
| 4K output | Only if your platform accepts 4K live ingest |
| DeckLink driver | Needs Blackmagic Desktop Video **16.0+** (matches bundled SDK) |
| Sharing to other Macs | Ad-hoc signed → Gatekeeper friction; true plug-and-play needs **Developer ID + notarization** |
| Intel | Use `build_universal.sh` (one-time x86 Homebrew setup) |

---

## What it is

Turbo Streamer is a lightweight SwiftUI app that wraps ffmpeg in a clean, dark-themed GUI. It lets non-technical operators start and monitor one or more RTMP streams — looping a video file or reading from a capture card — without ever opening a terminal.

Streams run in the background with automatic reconnection. You can configure new streams while others are already live.

---

## Why it exists

Most RTMP streaming tools either require a terminal, are heavy Electron apps, or cost a subscription. Turbo Streamer is a single self-contained `.app` file that runs natively on Apple Silicon (and Intel via the universal build), needs no installation, and bundles its own ffmpeg — so it works plug-and-play on any Mac you hand it to.

It was built specifically for live event production where you need to:
- Loop a video file continuously to multiple platforms
- Stream from a capture card (e.g. Elgato, Blackmagic)
- Keep streams alive with automatic reconnection if the connection drops
- Hand the app to a non-technical team member with zero setup

---

## Features

- **Multi-stream** — configure and run 1–8 independent RTMP streams simultaneously
- **Two tabs** — Configure streams while others are already live; Live tab shows all active streams
- **File loop** — streams a video file end-to-end on repeat (`-stream_loop -1`)
- **Capture card** — reads from any AVFoundation video/audio device, picked from a live dropdown
- **Blackmagic / DeckLink** — captures from DeckLink / UltraStudio devices (requires a DeckLink-enabled ffmpeg — see setup)
- **Device dropdowns** — pick video/audio sources from auto-scanned lists; refresh button re-scans
- **Automatic encoder** — no toggle to get wrong: 1080p/vertical use libx264 (`veryfast`, `zerolatency`); 4K uses Apple's VideoToolbox hardware encoder (the only one fast enough at 2160p)
- **Hardware decoding** — `-hwaccel videotoolbox` for ProRes and other heavy sources
- **Failsafe suite** — designed to survive real-world failures:
  - **Auto-reconnect** with exponential backoff (1→2→4→8→15s), resets after a healthy run
  - **Hang watchdog** — if frames stop for 10s (capture unplugged, source frozen, RTMP stuck), it restarts and re-acquires the device automatically
  - **Freeze / black detection** — warns when the feed freezes or goes black even though frames technically flow
  - **Backup RTMP destination** — push to a second ingest simultaneously (a backup failure never takes down the primary)
  - **Safety recording** — records the program to disk (`~/Documents/TurboStreamer Recordings`) while streaming, as resilient `.ts`
  - **Fallback on input loss** — the app continuously grabs a recent frame (~1/sec) from the live feed; if the input drops, that **most recent frame** is held on-air (instead of black), then it cuts back when the feed returns. Optionally override with a custom card.
  - **Adaptive bitrate** — lowers bitrate when the connection is unstable and steps it back up once stable
  - **Pre-flight check** — verifies the destination is reachable before going live
  - **Audible alerts** — chimes on disconnect, recovery, and freeze/black
- **Remembers your setup** — stream configs persist across launches automatically
- **Smart defaults** — bitrate auto-fills to a sensible value when you change resolution
- **Live metrics** — uptime, fps, bitrate, and encode speed shown per stream on the Live tab
- **Log persistence** — every stream writes a timestamped log to `~/Documents/TurboStreamer Logs/`
- **Presets** — Mux, YouTube, Vimeo, or Custom RTMP URL
- **Self-contained** — ffmpeg and all dylibs are bundled inside the `.app`; nothing to install

---

## Requirements

- macOS 13 Ventura or later
- Apple Silicon Mac (M1 or later) for the standard build
- Both Apple Silicon and Intel for the universal build (see below)
- [Homebrew](https://brew.sh) with ffmpeg installed: `brew install ffmpeg`
- Swift (comes with Xcode Command Line Tools): `xcode-select --install`

---

## Setup

### 1. Clone the repo

```bash
git clone https://github.com/jacopocer/turbo-streamer.git
cd turbo-streamer
```

### 2. Install fonts

The app uses two commercial fonts that are **not included** in this repo due to licensing:

| Font | Where to buy |
|------|-------------|
| **Sofia Pro** | [mostardesign.com](https://www.mostardesign.com/fonts/sofia-pro) |
| **Bello Pro** | [underware.nl](https://www.underware.nl/fonts/bello/) |

Once purchased, place all `.otf` files in `Resources/Fonts/`:

```
Resources/
└── Fonts/
    ├── Sofia Pro Regular Az.otf
    ├── Sofia Pro Bold Az.otf
    ├── Sofia Pro SemiBold Az.otf
    ├── ... (all weights)
    └── bellopro.otf
```

> **No fonts?** The app still builds and runs — it falls back to the system font. Fonts are purely cosmetic.

### 3. Add your logo *(optional)*

Place a `indigital-logo.png` (or your own logo PNG) in `Resources/`. It will appear in the top-right corner of the app header.

If you don't want a logo, remove the relevant block from `Sources/Streamer/ContentView.swift`.

### 4. Install ffmpeg

```bash
brew install ffmpeg
```

### 5. Build

**Standard build (Apple Silicon):**

```bash
bash build.sh
open Streamer.app
```

**Universal build (Apple Silicon + Intel):**

```bash
bash build_universal.sh
```

> Run `build_universal.sh` from Terminal.app the first time — it installs x86_64 Homebrew and ffmpeg via Rosetta and will ask for your password once. Subsequent runs are fully automated.

---

## Blackmagic / DeckLink support (optional)

The standard Homebrew ffmpeg is **not** compiled with DeckLink support, so Blackmagic
devices (DeckLink, UltraStudio, etc.) won't appear until you build a DeckLink-enabled
ffmpeg. A helper script automates this.

### 1. Install the Desktop Video driver

Install **Desktop Video** on the machine and make sure it's reasonably current:
[blackmagicdesign.com/support](https://www.blackmagicdesign.com/support)

> **Version matters.** ffmpeg refuses to open the device unless the installed driver
> version is **≥ the SDK version it was built against**. If you build against SDK 16.0,
> you need Desktop Video 16.0+. Match them.

### 2. Download the Desktop Video SDK

Grab the **Desktop Video SDK** (the developer package, *not* the driver) from
[blackmagicdesign.com/developer/product/capture-and-playback](https://www.blackmagicdesign.com/developer/product/capture-and-playback).
Unzip it — the headers live in `<SDK>/Mac/include`.

### 3. Run the setup script

```bash
bash scripts/setup-decklink-ffmpeg.sh "/path/to/Blackmagic DeckLink SDK XX.Y/Mac/include"
```

This copies the SDK headers into Homebrew's include dir, patches in the base COM
`IID_IUnknown` symbol (Blackmagic SDK 12+ removed it, but ffmpeg still references it),
and rebuilds ffmpeg from the `homebrew-ffmpeg` tap with `--with-decklink`.

### 4. Rebuild the app

```bash
bash build.sh      # or build_universal.sh
```

Verify it worked:

```bash
./Streamer.app/Contents/Resources/bin/ffmpeg -hide_banner -sources decklink
```

You should see your device listed. In the app, choose **Blackmagic** as the input,
hit the refresh button, and pick the device from the dropdown.

---

## Usage

1. Open `Streamer.app`
2. In the **Configure** tab, set your stream name, RTMP platform and key, resolution, bitrate, and input source
   - For **Capture Card** or **Blackmagic**, pick the device from the dropdown; use the ↻ refresh button to re-scan if you plug something in
3. Press **Start Streams** — streams appear in the **Live** tab
4. Go back to Configure any time to set up additional streams while the current ones are running
5. Use the **Stop** button per stream, or **Stop All** to kill everything
6. Logs are saved automatically to `~/Documents/TurboStreamer Logs/`

---

## Project structure

```
turbo-streamer/
├── Sources/Streamer/
│   ├── StreamerApp.swift        # App entry point, font loading
│   ├── Models.swift             # Data types (StreamConfig, StreamStatus, etc.)
│   ├── StreamManager.swift      # All ffmpeg lifecycle logic, log writing
│   ├── ProcessRegistry.swift    # Thread-safe ffmpeg process registry
│   ├── FontLoader.swift         # Registers bundled OTF fonts at launch
│   ├── ContentView.swift        # Root view with custom tab bar
│   ├── SetupView.swift          # Configure tab
│   ├── ActiveStreamsView.swift   # Live tab
│   ├── StreamConfigCard.swift   # Per-stream config card (device dropdowns)
│   └── StreamStatusCard.swift   # Per-stream status card with live log
├── Resources/
│   ├── AppIcon.icns
│   ├── indigital-logo.png       # Header logo (not tracked, add your own)
│   └── Fonts/                   # Not tracked — add licensed fonts here
├── scripts/
│   └── setup-decklink-ffmpeg.sh # Builds a DeckLink-enabled ffmpeg
├── Package.swift
├── Streamer.entitlements
├── build.sh                     # arm64 build
└── build_universal.sh           # Universal (arm64 + x86_64) build
```

---

## Notes on RTMP vs RTMPS

Mux defaults to `rtmp://global-live.mux.com/app` (port 1935). If your platform requires RTMPS (port 443), ffmpeg needs to be compiled with TLS support — verify with `ffmpeg -protocols | grep rtmps`.

---

## License

MIT — do what you want, no warranty.
