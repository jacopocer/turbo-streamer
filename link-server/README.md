# turbolink — pairing rendezvous

Lets Turbo Streamer and Turbo Receiver find each other without pasting URLs.

**turbolink itself never carries video.** It stores connection coordinates;
by default the stream goes straight from the streamer to each receiver, which
keeps the latency work (SRT, direct path) intact.

**The relay (option B)** is a second service next to it, `turborelay`: MediaMTX
on SRT (UDP 8890) and RTMP (TCP 1935), for when there is no direct path (the
receiver behind the office NAT, a venue blocking UDP). The streamer publishes
to the relay, every receiver pulls from it. Each session carries its own relay
secrets; MediaMTX asks turbolink over localhost (`POST /v1/auth`) whether a
publish or read is allowed, and the answer is yes only for that session's path
with that session's secret. Turbo Streamer probes SRT at start and, if UDP is
blocked, uses the RTMP door by itself. Installed by `deploy/deploy-relay.sh`
(pinned MediaMTX v1.21.0, unit `turborelay`, API on loopback 9997, MoQ off,
capped at CPUQuota 60% / MemoryMax 300M since the box is 1 vCPU / 2 GB shared
with the production sites). For real shows the relay belongs on its own small
VPS: the script takes `TURBOLINK_DEPLOY_HOST`, and `RELAY_HOST` in the turbolink
unit tells the apps where to point.

## Flow

1. Turbo Streamer opens a session → gets a 6-character code (`S29XA6`) and a
   secret, and shows the code.
2. Each Turbo Receiver joins with that code, publishing where it can be
   reached: protocol, host, port, stream key, SRT latency.
3. Turbo Streamer polls the session with its secret and adds each receiver as a
   destination.

One streamer, up to 32 receivers per session. A session expires 24 h after its
last use (poll, join, relay auth), so a code made the day before a show still
works during it.

## API

| | |
|---|---|
| `POST /v1/session` | `{name}` → `{code, secret, expiresAt, relay{srtURL, streamKey, rtmpURL, rtmpKey, latencyMs, path}}` |
| `POST /v1/session/:code/join` | `{label, protocol, host, port, streamKey, latencyMs}` → `{ok, receiverId, relay{source, path, latencyMs}}` |
| `GET /v1/session/:code` | header `x-secret` → `{name, receivers[], relay}` |
| `POST /v1/auth` | MediaMTX only, over localhost: `{action, path, password, ip, …}` → 200 / 401; 404 when it arrives through nginx |
| `DELETE /v1/session/:code` | header `x-secret` → `{ok}` |
| `GET /health` | `{ok, sessions}` |

The code is the capability to *join*; the secret is the capability to *read*
who joined. Codes use an unambiguous alphabet (no `0/O/1/I`) so they can be read
over the phone.

## Run locally

```
PORT=8814 TURBOLINK_DATA=./data node index.js
```

## Deploy

`deploy/deploy.sh` — new service on the production box: `/opt/turbolink`, port
**8814**, `turbostreamer.indigital.tv`.

Port 8814 was picked against the ecosystem's own allocation table in
`~/indigital-coordination/STATE.md`, not guessed: 3000/3100, 8787-8793 and
8811-8813 are taken, 8794-8800 is the reserved boot-check band and 8801-8810 the
dev-server band, so 8814 is the first free service port. Per that protocol it
must be **declared on SYNC.md and verified free on the box** before the first
deploy. An earlier draft of this service used 8791, which is garibaldi
staging's live traffic — the garibaldi session caught it. It adds a systemd unit and an nginx site and touches
nothing already running. **Server work is authorized per run by the owner.**
