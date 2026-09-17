# turbolink — pairing rendezvous

Lets Turbo Streamer and Turbo Receiver find each other without pasting URLs.

**It never carries video.** It stores only connection coordinates; the stream
goes straight from the streamer to each receiver. That keeps the latency work
(SRT, direct path) intact. A future relay mode — one publish, N subscribers
through the server — would be a separate service alongside this one.

## Flow

1. Turbo Streamer opens a session → gets a 6-character code (`S29XA6`) and a
   secret, and shows the code.
2. Each Turbo Receiver joins with that code, publishing where it can be
   reached: protocol, host, port, stream key, SRT latency.
3. Turbo Streamer polls the session with its secret and adds each receiver as a
   destination.

One streamer, up to 32 receivers per session. Sessions expire after 24 h.

## API

| | |
|---|---|
| `POST /v1/session` | `{name}` → `{code, secret, expiresAt}` |
| `POST /v1/session/:code/join` | `{label, protocol, host, port, streamKey, latencyMs}` → `{ok, receiverId}` |
| `GET /v1/session/:code` | header `x-secret` → `{name, receivers[]}` |
| `DELETE /v1/session/:code` | header `x-secret` → `{ok}` |
| `GET /health` | `{ok, sessions}` |

The code is the capability to *join*; the secret is the capability to *read*
who joined. Codes use an unambiguous alphabet (no `0/O/1/I`) so they can be read
over the phone.

## Run locally

```
PORT=8791 TURBOLINK_DATA=./data node index.js
```

## Deploy

`deploy/deploy.sh` — new service on the production box: `/opt/turbolink`, port
8791, `link.indigital.tv`. It adds a systemd unit and an nginx site and touches
nothing already running. **Server work is authorized per run by the owner.**
