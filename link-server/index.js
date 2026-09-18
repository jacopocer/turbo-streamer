// turbolink — rendezvous for pairing Turbo Streamer with Turbo Receiver.
//
// It only ever holds connection coordinates, never video: the stream itself
// goes straight from the streamer to each receiver. One streamer opens a
// session and shows a short code; any number of receivers join with that code
// and publish where they can be reached; the streamer polls and adds them as
// destinations.
//
// Relay (option B): every session also carries credentials for the public
// MediaMTX relay next door. The streamer can publish to the relay instead of
// straight to a receiver (when the receiver sits behind NAT or UDP is blocked),
// and each receiver can pull from it. MediaMTX asks this service, over
// localhost, whether a publish/read is allowed (POST /v1/auth); the answer is
// yes only for the session's own path with the session's own secrets.
//
// No dependencies: Node's own http module plus a JSON file for persistence.
'use strict';
const http = require('http');
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');

const PORT = Number(process.env.PORT || 8814);
const HOST = process.env.HOST || '127.0.0.1';
const DATA = process.env.TURBOLINK_DATA || path.join(__dirname, 'data');
const STORE = path.join(DATA, 'sessions.json');
const TTL_MS = Number(process.env.TURBOLINK_TTL_HOURS || 24) * 3600 * 1000;
const MAX_RECEIVERS = 32;

// Public relay coordinates handed to both apps. Host must resolve straight to the
// box (no Cloudflare proxy: SRT is UDP, RTMP is raw TCP).
// Turbo tailnet: the apps embed a Tailscale node (tsnet) and get their join key
// from here, minted on demand through the Tailscale API with a token that lives
// only on this box. Keys are single-use, short-lived, pre-authorised, ephemeral
// (the node vanishes when the app quits) and tagged, so the tailnet's ACL can
// confine Turbo nodes to each other's SRT port.
const TS = {
  token: process.env.TS_API_TOKEN || '',
  tailnet: process.env.TS_TAILNET || '-',
  tag: process.env.TS_TAG || 'tag:turbo',
  keyTTL: Number(process.env.TS_KEY_TTL_SECONDS || 600),
};

const RELAY = {
  host: process.env.RELAY_HOST || 'turbostreamer.indigital.tv',
  srtPort: Number(process.env.RELAY_SRT_PORT || 8890),
  rtmpPort: Number(process.env.RELAY_RTMP_PORT || 1935),
  latencyMs: Number(process.env.RELAY_LATENCY_MS || 200),   // internet-grade SRT buffer
};

// code: unambiguous alphabet (no 0/O/1/I) so it can be read aloud
const ALPHABET = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
const newCode = () => Array.from(crypto.randomFillSync(new Uint8Array(6)))
  .map(b => ALPHABET[b % ALPHABET.length]).join('');
const newSecret = () => crypto.randomBytes(24).toString('base64url');

/** @type {Map<string, {code:string,secret:string,name:string,createdAt:number,lastActive:number,receivers:Array,relay:{publishPass:string,readPass:string}}>} */
let sessions = new Map();

// What each side needs to use the relay. The streamer publishes with the same
// url/key fields it uses for a direct receiver (the app composes "publish:" +
// key for SRT, and "url/key" for RTMP); a receiver points a MediaMTX path source
// at the read URL.
function relayForStreamer(s) {
  return {
    host: RELAY.host, srtPort: RELAY.srtPort, rtmpPort: RELAY.rtmpPort, path: s.code,
    latencyMs: RELAY.latencyMs,
    srtURL: `srt://${RELAY.host}:${RELAY.srtPort}`,
    streamKey: `${s.code}:streamer:${s.relay.publishPass}`,
    rtmpURL: `rtmp://${RELAY.host}:${RELAY.rtmpPort}`,
    rtmpKey: `${s.code}?user=streamer&pass=${s.relay.publishPass}`,
  };
}
function relayForReceiver(s) {
  return {
    host: RELAY.host, srtPort: RELAY.srtPort, path: s.code, latencyMs: RELAY.latencyMs,
    source: `srt://${RELAY.host}:${RELAY.srtPort}?streamid=read:${s.code}:receiver:${s.relay.readPass}`,
  };
}

function load() {
  try {
    const raw = JSON.parse(fs.readFileSync(STORE, 'utf8'));
    sessions = new Map(raw.map(s => [s.code, s]));
  } catch { sessions = new Map(); }
  sweep();
}
function save() {
  try {
    fs.mkdirSync(DATA, { recursive: true });
    fs.writeFileSync(STORE, JSON.stringify([...sessions.values()]), { mode: 0o600 });
  } catch (e) { console.error('save failed:', e.message); }
}
// A session lives TTL past its last use (poll, join, relay auth), not past its
// creation: a code made the day before a show must still work during the show.
function sweep() {
  const cutoff = Date.now() - TTL_MS;
  let dropped = 0;
  for (const [code, s] of sessions) {
    if (Math.max(s.createdAt, s.lastActive || 0) < cutoff) { sessions.delete(code); dropped++; }
  }
  if (dropped) save();
}
function touch(s) { s.lastActive = Date.now(); }

const json = (res, status, body) => {
  const b = Buffer.from(JSON.stringify(body));
  res.writeHead(status, { 'content-type': 'application/json', 'content-length': b.length });
  res.end(b);
};

function readBody(req) {
  return new Promise((resolve, reject) => {
    let size = 0; const chunks = [];
    req.on('data', c => {
      size += c.length;
      if (size > 16 * 1024) { reject(new Error('body too large')); req.destroy(); return; }
      chunks.push(c);
    });
    req.on('end', () => {
      if (!chunks.length) return resolve({});
      try { resolve(JSON.parse(Buffer.concat(chunks).toString('utf8'))); }
      catch { reject(new Error('invalid JSON')); }
    });
    req.on('error', reject);
  });
}

// Constant-time secret check, so a wrong secret leaks nothing by timing.
function sameSecret(expected, given) {
  if (!given || !expected) return false;
  const a = Buffer.from(String(expected)), b = Buffer.from(String(given));
  return a.length === b.length && crypto.timingSafeEqual(a, b);
}
function secretOk(session, given) { return sameSecret(session.secret, given); }

const str = (v, max = 200) => (typeof v === 'string' ? v.slice(0, max) : '');

const server = http.createServer(async (req, res) => {
  const url = new URL(req.url, 'http://localhost');
  const parts = url.pathname.split('/').filter(Boolean);

  try {
    if (req.method === 'GET' && url.pathname === '/health') {
      return json(res, 200, { ok: true, sessions: sessions.size });
    }

    // POST /v1/session — streamer opens a session
    if (req.method === 'POST' && parts[0] === 'v1' && parts[1] === 'session' && parts.length === 2) {
      const body = await readBody(req);
      sweep();
      let code; do { code = newCode(); } while (sessions.has(code));
      const s = { code, secret: newSecret(), name: str(body.name) || 'Feed',
                  createdAt: Date.now(), lastActive: Date.now(), receivers: [],
                  relay: { publishPass: newSecret(), readPass: newSecret() } };
      sessions.set(code, s);
      save();
      return json(res, 201, { code: s.code, secret: s.secret,
                              expiresAt: new Date(s.createdAt + TTL_MS).toISOString(),
                              relay: relayForStreamer(s) });
    }

    // POST /v1/tailnet/key — an app asks for a key to join the Turbo tailnet
    if (req.method === 'POST' && url.pathname === '/v1/tailnet/key') {
      if (!TS.token) return json(res, 503, { error: 'tailnet not configured on this server' });
      const body = await readBody(req);
      const r = await fetch(`https://api.tailscale.com/api/v2/tailnet/${encodeURIComponent(TS.tailnet)}/keys`, {
        method: 'POST',
        headers: { authorization: `Bearer ${TS.token}`, 'content-type': 'application/json' },
        body: JSON.stringify({
          description: `turbo ${str(body.app, 20) || 'app'} ${str(body.host, 40)}`.trim(),
          expirySeconds: TS.keyTTL,
          capabilities: { devices: { create: {
            reusable: false, ephemeral: true, preauthorized: true, tags: [TS.tag],
          } } },
        }),
      });
      if (!r.ok) {
        const detail = (await r.text()).slice(0, 200);
        console.error('tailnet key mint failed:', r.status, detail);
        return json(res, 502, { error: `tailnet key refused (${r.status})` });
      }
      const k = await r.json();
      return json(res, 200, { authKey: k.key, expiresIn: TS.keyTTL, tag: TS.tag });
    }

    // POST /v1/auth — MediaMTX (the relay, on this box) asks whether an action is
    // allowed: {user, password, ip, action, path, protocol, id, query}. Only the
    // session whose code is the path, with that session's own secret, may publish
    // or read. External callers never reach this: nginx stamps X-Real-IP on
    // everything it proxies, and MediaMTX calls over localhost without it.
    if (req.method === 'POST' && url.pathname === '/v1/auth') {
      if (req.headers['x-real-ip'] || req.headers['x-forwarded-for']) return json(res, 404, { error: 'not found' });
      const body = await readBody(req);
      const action = str(body.action, 20);
      if (['api', 'metrics', 'pprof'].includes(action)) {
        return json(res, /^(127\.|::1)/.test(str(body.ip, 64)) ? 200 : 401, {});
      }
      const s = sessions.get(str(body.path, 20).toUpperCase());
      if (!s || !s.relay) return json(res, 401, {});
      const pw = str(body.password, 200);
      let ok = false;
      if (action === 'publish') ok = sameSecret(s.relay.publishPass, pw);
      else if (action === 'read') ok = sameSecret(s.relay.readPass, pw) || sameSecret(s.relay.publishPass, pw);
      if (ok) { touch(s); save(); }
      return json(res, ok ? 200 : 401, {});
    }

    // POST /v1/session/:code/join — a receiver publishes where to reach it
    if (req.method === 'POST' && parts[0] === 'v1' && parts[1] === 'session' && parts[3] === 'join') {
      const s = sessions.get(String(parts[2] || '').toUpperCase());
      if (!s) return json(res, 404, { error: 'unknown or expired code' });
      if (s.receivers.length >= MAX_RECEIVERS) return json(res, 429, { error: 'too many receivers' });
      const body = await readBody(req);
      const host = str(body.host, 120);
      if (!host) return json(res, 400, { error: 'host is required' });
      const r = {
        id: crypto.randomUUID(),
        label: str(body.label, 60) || 'Receiver',
        protocol: ['srt', 'rtmp'].includes(body.protocol) ? body.protocol : 'srt',
        host,
        port: Number.isInteger(body.port) ? body.port : 8890,
        streamKey: str(body.streamKey, 120),
        latencyMs: Number.isInteger(body.latencyMs) ? body.latencyMs : 120,
        joinedAt: Date.now(),
      };
      // same host+port+key replaces the previous entry (receiver restarted)
      s.receivers = s.receivers.filter(
        x => !(x.host === r.host && x.port === r.port && x.streamKey === r.streamKey));
      s.receivers.push(r);
      touch(s);
      save();
      return json(res, 200, { ok: true, receiverId: r.id, sessionName: s.name,
                              relay: s.relay ? relayForReceiver(s) : null });
    }

    // GET /v1/session/:code — streamer polls the joined receivers (secret required)
    if (req.method === 'GET' && parts[0] === 'v1' && parts[1] === 'session' && parts.length === 3) {
      const s = sessions.get(String(parts[2] || '').toUpperCase());
      if (!s) return json(res, 404, { error: 'unknown or expired code' });
      const given = req.headers['x-secret'] || url.searchParams.get('secret');
      if (!secretOk(s, given)) return json(res, 403, { error: 'bad secret' });
      touch(s);
      return json(res, 200, { code: s.code, name: s.name, receivers: s.receivers,
                              expiresAt: new Date(Math.max(s.createdAt, s.lastActive || 0) + TTL_MS).toISOString(),
                              relay: s.relay ? relayForStreamer(s) : null });
    }

    // DELETE /v1/session/:code — streamer closes it
    if (req.method === 'DELETE' && parts[0] === 'v1' && parts[1] === 'session' && parts.length === 3) {
      const s = sessions.get(String(parts[2] || '').toUpperCase());
      if (!s) return json(res, 404, { error: 'unknown or expired code' });
      const given = req.headers['x-secret'] || url.searchParams.get('secret');
      if (!secretOk(s, given)) return json(res, 403, { error: 'bad secret' });
      sessions.delete(s.code); save();
      return json(res, 200, { ok: true });
    }

    return json(res, 404, { error: 'not found' });
  } catch (e) {
    return json(res, 400, { error: e.message || 'bad request' });
  }
});

load();
setInterval(sweep, 10 * 60 * 1000).unref();
server.listen(PORT, HOST, () => console.log(`turbolink on http://${HOST}:${PORT}`));
