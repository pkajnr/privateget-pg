/** PrivateGet PG networked ALPHA relay (Node 22+, no dependencies).
 * In-memory only; do not expose directly to the public Internet.
 * This server NEVER accepts or saves plaintext chat messages.
 * EXPERIMENTAL: NOT a security-reviewed production messenger.
 */
import http from 'node:http';
import { randomBytes, randomUUID, createHash, timingSafeEqual } from 'node:crypto';

const host = process.env.PG_HOST || '0.0.0.0';
const port = Number(process.env.PG_PORT || '8787');
const isDev = process.env.PG_DEV === '1';
const INVITE_MS = 10 * 60 * 1000;
const MAX_SESSION_MS = 24 * 60 * 60 * 1000;
const IDLE_MS = 30 * 60 * 1000;
const DELIVERY_MS = 3 * 60 * 1000;
const ATTACHMENT_MS = 10 * 60 * 1000;
const MAX_CIPHERTEXT_BYTES = 12 * 1024 * 1024;
const MAX_SESSION_ATTACHMENTS = 4;
const CALL_SIGNAL_MS = 90 * 1000;
const devices = new Map(); // secret bearer -> {id, createdAt}
const invites = new Map(); // hashed invitation code -> invitation metadata
const sessions = new Map(); // id -> session; ciphertext is only queued in volatile memory
const rate = new Map();

function now() { return Date.now(); }
function randomToken(len = 24) { return randomBytes(len).toString('base64url'); }
function sha256(value) { return createHash('sha256').update(value).digest('hex'); }
function reply(res, status, payload) {
  res.writeHead(status, { 'Content-Type': 'application/json; charset=utf-8', 'Cache-Control': 'no-store', 'X-Content-Type-Options': 'nosniff', 'Referrer-Policy': 'no-referrer' });
  res.end(JSON.stringify(payload));
}
function fail(res, code, message) { return reply(res, code, { error: message }); }
function good64(s, byteCount) {
  if (typeof s !== 'string' || !/^[A-Za-z0-9_-]+$/.test(s)) return false;
  try { return Buffer.from(s, 'base64url').length === byteCount; } catch { return false; }
}
function json(req, max = 16000) {
  return new Promise((resolve, reject) => {
    let size = 0;
    let chunks = [];
    req.on('data', b => {
      size += b.length;
      if (size > max) { reject(Object.assign(new Error('Request too large'), { status: 413 })); req.destroy(); return; }
      chunks.push(b);
    });
    req.on('end', () => {
      try { resolve(JSON.parse(Buffer.concat(chunks).toString('utf8') || '{}')); }
      catch { reject(Object.assign(new Error('Invalid JSON'), { status: 400 })); }
    });
    req.on('error', reject);
  });
}
function readCiphertext(req, limit = MAX_CIPHERTEXT_BYTES) {
  return new Promise((resolve, reject) => {
    const declared = Number(req.headers['content-length'] || 0);
    if (declared > limit) return reject(Object.assign(new Error('Encrypted attachment too large'), { status: 413 }));
    const blocks = []; let total = 0;
    req.on('data', block => {
      total += block.length;
      if (total > limit) { reject(Object.assign(new Error('Encrypted attachment too large'), { status: 413 })); req.destroy(); return; }
      blocks.push(block);
    });
    req.on('end', () => resolve(Buffer.concat(blocks)));
    req.on('error', reject);
  });
}
function device(req) {
  const head = req.headers.authorization || '';
  const match = /^Bearer ([A-Za-z0-9_-]{20,})$/.exec(head);
  return match ? devices.get(match[1]) : null;
}
function checkRate(key, limit = 80) {
  let b = rate.get(key); const t = now();
  if (!b || t - b.start > 60_000) b = { start: t, n: 0 };
  b.n++; rate.set(key, b); return b.n <= limit;
}
function endSession(s, reason = 'ended') {
  s.state = 'ended'; s.reason = reason; s.endedAt = now();
  s.queue = []; s.aKey = null; s.bKey = null; // drop relay public keys and ciphertext
  s.callSignals = []; s.attachments.clear(); // drop all ephemeral call and media data
}
function sweep() {
  const t = now();
  for (const [key, item] of invites) {
    if (item.expiresAt < t && item.state === 'pending') item.state = 'expired';
    if (item.expiresAt < t - 120_000) invites.delete(key);
  }
  for (const [id, s] of sessions) {
    if (s.state !== 'ended' && (s.createdAt + MAX_SESSION_MS < t || s.lastActivity + IDLE_MS < t)) endSession(s, 'expired');
    s.queue = s.queue.filter(m => m.at + DELIVERY_MS > t);
    s.callSignals = s.callSignals.filter(m => m.at + CALL_SIGNAL_MS > t);
    for (const [fileId, f] of s.attachments) if (f.expiresAt <= t) s.attachments.delete(fileId);
    if (s.state === 'ended' && s.endedAt + 120_000 < t) sessions.delete(id);
  }
  for (const [key, b] of rate) if (t - b.start > 120_000) rate.delete(key);
}
const sweepInterval = setInterval(sweep, 10_000); sweepInterval.unref();
function overview(s, who) {
  return { id: s.id, state: s.state, reason: s.reason || null, role: s.a === who ? 'A' : 'B',
    peerKey: s.state === 'ended' ? null : (s.a === who ? s.bKey : s.aKey),
    createdAt: s.createdAt, expiresAt: Math.min(s.createdAt + MAX_SESSION_MS, s.lastActivity + IDLE_MS),
    safetyHint: 'Compare the safety code shown inside BOTH apps over an independent trusted channel.' };
}
const server = http.createServer(async (req, res) => {
  try {
    const url = new URL(req.url || '/', `http://${req.headers.host || 'localhost'}`);
    if (url.pathname === '/health' && req.method === 'GET') return reply(res, 200, { ok: true, app: 'PrivateGet', mode: 'experimental', e2eeProtocolAudited: false });
    if (req.method !== 'GET' && req.method !== 'POST') return fail(res, 405, 'Method not allowed');
    if (req.method === 'POST' && url.pathname === '/v1/devices') {
      if (!checkRate(`register:${req.socket.remoteAddress}`, 15)) return fail(res, 429, 'Too many registrations');
      const token = randomToken(32); const id = randomUUID();
      devices.set(token, { id, createdAt: now() });
      return reply(res, 201, { deviceId: id, token });
    }
    const who = device(req);
    if (!who) return fail(res, 401, 'Device token required');
    if (!checkRate(`device:${who.id}`, 180)) return fail(res, 429, 'Rate limit exceeded');
    if (req.method === 'POST' && url.pathname === '/v1/invites') {
      const b = await json(req);
      if (!good64(b.publicKey, 32)) return fail(res, 400, 'Valid X25519 public key required');
      let outstanding = 0;
      for (const v of invites.values()) if (v.a === who.id && v.state === 'pending') outstanding++;
      if (outstanding >= 5) return fail(res, 429, 'Maximum 5 active invitations');
      const code = randomToken(24); const id = randomUUID();
      const item = { id, a: who.id, aKey: b.publicKey, createdAt: now(), expiresAt: now() + INVITE_MS, state: 'pending', sessionId: null };
      invites.set(sha256(code), item);
      return reply(res, 201, { id, code, expiresAt: item.expiresAt });
    }
    const matchInvite = /^\/v1\/invites\/([0-9a-f-]+)(?:\/(revoke))?$/.exec(url.pathname);
    if (matchInvite && ((req.method === 'GET' && !matchInvite[2]) || (req.method === 'POST' && matchInvite[2] === 'revoke'))) {
      const i = [...invites.values()].find(x => x.id === matchInvite[1]);
      if (!i || i.a !== who.id) return fail(res, 404, 'Invitation unavailable');
      if (req.method === 'POST') {
        i.state = 'revoked';
        if (i.sessionId) { const s = sessions.get(i.sessionId); if (s && s.state !== 'ended') endSession(s); }
      }
      return reply(res, 200, { id: i.id, state: i.state, expiresAt: i.expiresAt, sessionId: i.sessionId });
    }
    if (req.method === 'POST' && url.pathname === '/v1/invites/accept') {
      const b = await json(req);
      if (!good64(b.publicKey, 32) || typeof b.code !== 'string') return fail(res, 400, 'Code and X25519 public key required');
      const invite = invites.get(sha256(b.code.trim()));
      if (!invite || invite.expiresAt <= now()) return fail(res, 404, 'Invitation missing or expired');
      if (invite.state !== 'pending') return fail(res, 409, 'Invitation already used');
      if (invite.a === who.id) return fail(res, 400, 'Cannot accept your own invite');
      invite.state = 'accepted';
      const s = { id: randomUUID(), a: invite.a, b: who.id, aKey: invite.aKey,
        bKey: b.publicKey, state: 'awaiting_approval', createdAt: now(), lastActivity: now(), queue: [], nextSeq: 0,
        attachments: new Map(), callSignals: [] };
      sessions.set(s.id, s); invite.sessionId = s.id;
      return reply(res, 201, { sessionId: s.id, state: s.state });
    }
    // Opaque binary attachment endpoint. The server is given ciphertext only:
    // no file name, MIME type, AES key or plaintext is sent here.
    const attachmentRoute = /^\/v1\/sessions\/([0-9a-f-]+)\/attachments(?:\/([0-9a-f-]+))?$/.exec(url.pathname);
    if (attachmentRoute) {
      const session = sessions.get(attachmentRoute[1]);
      if (!session) return fail(res, 404, 'Session unavailable');
      if (session.a !== who.id && session.b !== who.id) return fail(res, 403, 'Not a participant');
      if (session.state !== 'active') return fail(res, 409, 'Session not active');
      if (req.method === 'POST' && !attachmentRoute[2]) {
        if (session.attachments.size >= MAX_SESSION_ATTACHMENTS) return fail(res, 429, 'Temporary attachment quota reached');
        if (req.headers['content-type']?.split(';')[0] !== 'application/octet-stream') {
          return fail(res, 415, 'Ciphertext body required');
        }
        const blob = await readCiphertext(req);
        if (blob.length < 17) return fail(res, 400, 'Encrypted attachment too small');
        const attachmentId = randomUUID();
        session.attachments.set(attachmentId, {
          bytes: blob, from: who.id, expiresAt: now() + ATTACHMENT_MS,
        });
        session.lastActivity = now();
        return reply(res, 201, { id: attachmentId, expiresInSeconds: ATTACHMENT_MS / 1000 });
      }
      if (req.method === 'GET' && attachmentRoute[2]) {
        const blob = session.attachments.get(attachmentRoute[2]);
        if (!blob || blob.expiresAt < now()) return fail(res, 404, 'Attachment expired');
        if (blob.from === who.id) return fail(res, 403, 'Recipient only');
        res.writeHead(200, {
          'Content-Type': 'application/octet-stream',
          'Content-Length': blob.bytes.length,
          'Cache-Control': 'no-store', 'X-Content-Type-Options': 'nosniff',
          'Referrer-Policy': 'no-referrer',
        });
        return res.end(blob.bytes);
      }
      return fail(res, 405, 'Method not allowed');
    }
    const matchSession = /^\/v1\/sessions\/([0-9a-f-]+)(?:\/(approve|messages|end|call))?$/.exec(url.pathname);
    if (!matchSession) return fail(res, 404, 'Route not found');
    const s = sessions.get(matchSession[1]);
    if (!s) return fail(res, 404, 'Session not found or already destroyed');
    if (s.a !== who.id && s.b !== who.id) return fail(res, 403, 'Not a participant');
    const action = matchSession[2] || '';
    if (req.method === 'GET' && action === '') return reply(res, 200, overview(s, who.id));
    if (req.method === 'POST' && action === 'approve') {
      if (s.a !== who.id) return fail(res, 403, 'Only inviter can approve');
      if (s.state !== 'awaiting_approval') return fail(res, 409, 'Not awaiting approval');
      s.state = 'active'; s.lastActivity = now();
      return reply(res, 200, overview(s, who.id));
    }
    if (req.method === 'POST' && action === 'end') {
      if (s.state !== 'ended') endSession(s);
      return reply(res, 200, { state: 'ended' });
    }
    if (action === 'call') {
      if (s.state !== 'active') return fail(res, 409, 'Session not active');
      if (req.method === 'GET') {
        const mine = s.callSignals.filter(m => m.to === who.id);
        s.callSignals = s.callSignals.filter(m => m.to !== who.id);
        return reply(res, 200, { signals: mine.map(({callId,type,data}) => ({callId,type,data})) });
      }
      if (req.method === 'POST') {
        const b = await json(req, 100000);
        const allowed = new Set(['offer','answer','ice','end','decline']);
        if (typeof b.callId !== 'string' || !/^[a-zA-Z0-9-]{16,64}$/.test(b.callId) ||
            !allowed.has(b.type) || !b.data || typeof b.data !== 'object' ||
            Array.isArray(b.data)) return fail(res, 400, 'Invalid call signal');
        if (s.callSignals.length >= 160) return fail(res, 429, 'Call signal queue full');
        s.callSignals.push({
          to: who.id === s.a ? s.b : s.a,
          callId: b.callId, type: b.type, data: b.data, at: now(),
        });
        return reply(res, 201, { queued: true });
      }
      return fail(res, 405, 'Method not allowed');
    }
    if (action === 'messages') {
      if (s.state !== 'active') return fail(res, 409, 'Session not active');
      if (req.method === 'GET') {
        const recipient = who.id;
        const own = s.queue.filter(m => m.to !== recipient);
        const mine = s.queue.filter(m => m.to === recipient);
        s.queue = own; // destructive poll; no history or second retrieval
        return reply(res, 200, { messages: mine.map(({ seq, iv, ciphertext, mac }) => ({ seq, iv, ciphertext, mac })) });
      }
      if (req.method === 'POST') {
        const b = await json(req);
        if (!good64(b.iv, 12) || !good64(b.mac, 16) || typeof b.ciphertext !== 'string' ||
            b.ciphertext.length < 1 || b.ciphertext.length > 6000 || !/^[A-Za-z0-9_=-]+$/.test(b.ciphertext)) {
          return fail(res, 400, 'Ciphertext envelope required (no plaintext accepted)');
        }
        if (s.queue.length >= 100) return fail(res, 429, 'Delivery queue full');
        s.lastActivity = now();
        const seq = ++s.nextSeq;
        s.queue.push({ seq, from: who.id, to: who.id === s.a ? s.b : s.a,
          at: now(), iv: b.iv, ciphertext: b.ciphertext, mac: b.mac });
        return reply(res, 201, { deliveredToRelay: true, seq });
      }
    }
    return fail(res, 405, 'Method not allowed');
  } catch (e) {
    const status = e.status || 500;
    // Never log request bodies or sensitive tokens.
    if (status === 500) console.error('[PG server error]', e.message);
    if (!res.headersSent && !res.destroyed) fail(res, status, status === 500 ? 'Internal error' : e.message);
  }
});
server.listen(port, host, () => console.log(`PG experimental relay listening on http://${host}:${port} (LOCAL LAB ONLY)`));
export { server };
