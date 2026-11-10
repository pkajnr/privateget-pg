// PG lab relay integration tests for ephemeral ciphertext and call signaling.
// No actual audio/video or Flutter runtime is involved.
import { spawn } from 'node:child_process';
import { strict as assert } from 'node:assert';
import { randomBytes, createHmac } from 'node:crypto';
import { setTimeout as delay } from 'node:timers/promises';

const port = 18789;
const turnSecret = 'pg-integration-only-not-a-real-secret-0123456789';
const turnUrl = 'turn:relay.example.invalid:3478?transport=udp';
const root = 'http://127.0.0.1:' + port;
const proc = spawn(process.execPath, ['server.mjs'], {
  cwd: new URL('.', import.meta.url),
  env: { ...process.env, PG_HOST: '127.0.0.1', PG_PORT: String(port),
    PG_TURN_SECRET: turnSecret, PG_TURN_URLS: turnUrl },
  stdio: 'ignore',
});
const json = async (method, path, token, value) => {
  const response = await fetch(root + path, {
    method,
    headers: {
      ...(token ? { Authorization: 'Bearer ' + token } : {}),
      ...(value === undefined ? {} : { 'Content-Type': 'application/json' }),
    },
    ...(value === undefined ? {} : { body: JSON.stringify(value) }),
  });
  const result = await response.json();
  return { status: response.status, ...result };
};
const reg = () => json('POST', '/v1/devices', null, {});
try {
  let healthy = false;
  for (let i = 0; i < 70; i++) {
    try { if ((await fetch(root + '/health')).ok) { healthy = true; break; } } catch {}
    await delay(70);
  }
  assert.ok(healthy, 'Server must start');
  const a = await reg(), b = await reg(), outsider = await reg();
  const key = () => randomBytes(32).toString('base64url');
  const invite = await json('POST', '/v1/invites', a.token, { publicKey: key() });
  assert.equal(invite.status, 201);
  const accepted = await json('POST', '/v1/invites/accept', b.token,
    { code: invite.code, publicKey: key() });
  assert.equal(accepted.status, 201);
  const sid = accepted.sessionId;
  assert.equal((await json('POST', '/v1/sessions/' + sid + '/approve', a.token, {})).status, 200);

  // ICE credentials are generated only for active session members.
  const aliceIce = await json('GET', '/v1/sessions/' + sid + '/ice', a.token);
  assert.equal(aliceIce.status, 200);
  assert.equal(aliceIce.turnConfigured, true);
  assert.equal(aliceIce.iceServers.length, 2);
  assert.deepEqual(aliceIce.iceServers[1].urls, [turnUrl]);
  const turn = aliceIce.iceServers[1];
  assert.ok(turn.username.includes(':'));
  assert.ok(aliceIce.expiresAt > Math.floor(Date.now() / 1000));
  assert.equal(
    turn.credential,
    createHmac('sha1', turnSecret).update(turn.username).digest('base64')
  );
  assert.equal(
    (await json('GET', '/v1/sessions/' + sid + '/ice', outsider.token)).status, 403
  );

  // Ciphertext is opaque to relay; contents include a fake AEAD tag.
  const ciphertext = randomBytes(128);
  const upload = await fetch(root + '/v1/sessions/' + sid + '/attachments', {
    method: 'POST',
    headers: { Authorization: 'Bearer ' + a.token, 'Content-Type': 'application/octet-stream' },
    body: ciphertext,
  });
  assert.equal(upload.status, 201);
  const { id } = await upload.json();
  assert.ok(id);
  const download = await fetch(root + '/v1/sessions/' + sid + '/attachments/' + id,
    { headers: { Authorization: 'Bearer ' + b.token } });
  assert.equal(download.status, 200);
  assert.deepEqual(Buffer.from(await download.arrayBuffer()), ciphertext);
  const ownDownload = await fetch(root + '/v1/sessions/' + sid + '/attachments/' + id,
    { headers: { Authorization: 'Bearer ' + a.token } });
  assert.equal(ownDownload.status, 403);
  const outsiderDownload = await fetch(root + '/v1/sessions/' + sid + '/attachments/' + id,
    { headers: { Authorization: 'Bearer ' + outsider.token } });
  assert.equal(outsiderDownload.status, 403);

  const callId = '12345678-1234-4000-8000-123456789abc';
  assert.equal((await json('POST', '/v1/sessions/' + sid + '/call',
    a.token, { callId, type: 'offer', data: { video: false, sdp: 'fake-offer' } })).status, 201);
  const bCalls = await json('GET', '/v1/sessions/' + sid + '/call', b.token);
  assert.equal(bCalls.signals.length, 1);
  assert.equal(bCalls.signals[0].data.sdp, 'fake-offer');
  assert.equal((await json('GET', '/v1/sessions/' + sid + '/call', b.token)).signals.length, 0);
  assert.equal((await json('POST', '/v1/sessions/' + sid + '/call', b.token,
    { callId, type: 'answer', data: { sdp: 'fake-answer' } })).status, 201);
  assert.equal((await json('GET', '/v1/sessions/' + sid + '/call', a.token)).signals[0].type, 'answer');

  assert.equal((await json('POST', '/v1/sessions/' + sid + '/end', a.token, {})).status, 200);
  const afterEnd = await fetch(root + '/v1/sessions/' + sid + '/attachments/' + id,
    { headers: { Authorization: 'Bearer ' + b.token } });
  assert.equal(afterEnd.status, 409);
  assert.equal((await json('GET', '/v1/sessions/' + sid + '/call', b.token)).status, 409);
  assert.equal((await json('GET', '/v1/sessions/' + sid + '/ice', b.token)).status, 409);
  console.log('PASS PG attachment and call relay integration tests');
} finally {
  proc.kill();
}
