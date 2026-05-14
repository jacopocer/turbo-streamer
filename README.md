# Turbo Streamer

A native macOS app for streaming video files and capture cards to RTMP endpoints — simultaneously, reliably, with no terminal required.

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
- **Capture card** — reads from any AVFoundation video/audio device
- **Hardware encoding** — uses Apple's VideoToolbox H.264 encoder for full-speed 4K
- **Hardware decoding** — `-hwaccel videotoolbox` for ProRes and other heavy sources
- **Auto-reconnect** — retries every 10 seconds on disconnect; stops cleanly when you say stop
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

## Usage

1. Open `Streamer.app`
2. In the **Configure** tab, set your stream name, RTMP platform and key, resolution, bitrate, and input source
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
│   ├── StreamConfigCard.swift   # Per-stream configuration card
│   └── StreamStatusCard.swift   # Per-stream status card with live log
├── Resources/
│   ├── AppIcon.icns
│   ├── indigital-logo.png       # Header logo (not tracked, add your own)
│   └── Fonts/                   # Not tracked — add licensed fonts here
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
