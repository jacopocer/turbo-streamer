// turbolink — rendezvous for pairing Turbo Streamer with Turbo Receiver.
//
// It only ever holds connection coordinates, never video: the stream itself
// goes straight from the streamer to each receiver. One streamer opens a
// session and shows a short code; any number of receivers join with that code
// and publish where they can be reached; the streamer polls and adds them as
// destinations.
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

// code: unambiguous alphabet (no 0/O/1/I) so it can be read aloud
const ALPHABET = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
const newCode = () => Array.from(crypto.randomFillSync(new Uint8Array(6)))
  .map(b => ALPHABET[b % ALPHABET.length]).join('');
const newSecret = () => crypto.randomBytes(24).toString('base64url');

/** @type {Map<string, {code:string,secret:string,name:string,createdAt:number,receivers:Array}>} */
let sessions = new Map();

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
function sweep() {
  const cutoff = Date.now() - TTL_MS;
  let dropped = 0;
  for (const [code, s] of sessions) if (s.createdAt < cutoff) { sessions.delete(code); dropped++; }
  if (dropped) save();
}

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
function secretOk(session, given) {
  if (!given) return false;
  const a = Buffer.from(session.secret), b = Buffer.from(String(given));
  return a.length === b.length && crypto.timingSafeEqual(a, b);
}

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
                  createdAt: Date.now(), receivers: [] };
      sessions.set(code, s);
      save();
      return json(res, 201, { code: s.code, secret: s.secret,
                              expiresAt: new Date(s.createdAt + TTL_MS).toISOString() });
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
      save();
      return json(res, 200, { ok: true, receiverId: r.id, sessionName: s.name });
    }

    // GET /v1/session/:code — streamer polls the joined receivers (secret required)
    if (req.method === 'GET' && parts[0] === 'v1' && parts[1] === 'session' && parts.length === 3) {
      const s = sessions.get(String(parts[2] || '').toUpperCase());
      if (!s) return json(res, 404, { error: 'unknown or expired code' });
      const given = req.headers['x-secret'] || url.searchParams.get('secret');
      if (!secretOk(s, given)) return json(res, 403, { error: 'bad secret' });
      return json(res, 200, { code: s.code, name: s.name, receivers: s.receivers,
                              expiresAt: new Date(s.createdAt + TTL_MS).toISOString() });
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
