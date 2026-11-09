// End-to-end networked server test, using REAL Node X25519/HKDF/AES-GCM primitives.
// Does not test Flutter binary or production resistance to attacks.
import { spawn } from 'node:child_process';
import { strict as assert } from 'node:assert';
import { generateKeyPairSync, diffieHellman, hkdfSync, randomBytes, createCipheriv, createDecipheriv } from 'node:crypto';
import { setTimeout as sleep } from 'node:timers/promises';
const PORT = '17879';
const base = `http://127.0.0.1:${PORT}`;
const child = spawn(process.execPath, ['server.mjs'], { cwd: new URL('.', import.meta.url), env: { ...process.env, PG_PORT: PORT, PG_HOST: '127.0.0.1' }, stdio: ['ignore','pipe','pipe'] });
child.stderr.on('data', b => process.stderr.write(b));
const pub = key => key.export({ format: 'der', type: 'spki' }).subarray(-32).toString('base64url');
const req = async (method, path, token, data) => {
  const r = await fetch(base + path, { method, headers: { ...(token ? { Authorization: `Bearer ${token}` } : {}), ...(data ? { 'Content-Type': 'application/json' } : {}) }, body: data ? JSON.stringify(data) : undefined });
  return { status: r.status, body: await r.json() };
};
let checks = 0;
try {
  for (let i = 0; i < 70; i++) {
    try { const res = await req('GET','/health'); if (res.status === 200) break; } catch {}
    await sleep(40);
  }
  const { body: a } = await req('POST','/v1/devices',null,{});
  const { body: b } = await req('POST','/v1/devices',null,{});
  const { body: outsider } = await req('POST','/v1/devices',null,{});
  assert(a.token && b.token && outsider.token); checks++;
  const ak = generateKeyPairSync('x25519');
  const bk = generateKeyPairSync('x25519');
  const { body: inv } = await req('POST','/v1/invites',a.token,{publicKey:pub(ak.publicKey)});
  assert(inv.code && inv.id); checks++;
  const { body: acc } = await req('POST','/v1/invites/accept',b.token,{code:inv.code,publicKey:pub(bk.publicKey)});
  assert.equal(acc.state,'awaiting_approval'); checks++;
  const replay = await req('POST','/v1/invites/accept',outsider.token,{code:inv.code,publicKey:pub(bk.publicKey)});
  assert.equal(replay.status,409); checks++;
  const outsiderRead = await req('GET',`/v1/sessions/${acc.sessionId}`,outsider.token);
  assert.equal(outsiderRead.status,403); checks++;
  const before = await req('POST',`/v1/sessions/${acc.sessionId}/messages`,a.token,{iv:randomBytes(12).toString('base64url'),mac:randomBytes(16).toString('base64url'),ciphertext:'dGVzdA'});
  assert.equal(before.status,409); checks++;
  const acceptStatus = await req('GET',`/v1/invites/${inv.id}`,a.token);
  assert.equal(acceptStatus.body.sessionId,acc.sessionId); checks++;
  const approve = await req('POST',`/v1/sessions/${acc.sessionId}/approve`,a.token,{});
  assert.equal(approve.body.state,'active'); checks++;
  const sharedA = diffieHellman({privateKey:ak.privateKey,publicKey:bk.publicKey});
  const sharedB = diffieHellman({privateKey:bk.privateKey,publicKey:ak.publicKey});
  assert.deepEqual(sharedA,sharedB); checks++;
  const key = Buffer.from(hkdfSync('sha256',sharedA,Buffer.from(acc.sessionId),Buffer.from('PG-alpha-A-to-B'),32));
  const iv = randomBytes(12), msg = 'Hello B from a real encrypted client!';
  const cipher = createCipheriv('aes-256-gcm',key,iv);
  cipher.setAAD(Buffer.from(`PG|${acc.sessionId}|A`));
  const ciphertext = Buffer.concat([cipher.update(msg,'utf8'),cipher.final()]);
  const mac = cipher.getAuthTag();
  const send = await req('POST',`/v1/sessions/${acc.sessionId}/messages`,a.token,{iv:iv.toString('base64url'),ciphertext:ciphertext.toString('base64url'),mac:mac.toString('base64url')});
  assert.equal(send.status,201); checks++;
  const emptySender = await req('GET',`/v1/sessions/${acc.sessionId}/messages`,a.token);
  assert.equal(emptySender.body.messages.length,0); checks++;
  const received = await req('GET',`/v1/sessions/${acc.sessionId}/messages`,b.token);
  assert.equal(received.body.messages.length,1); checks++;
  assert(!JSON.stringify(received).includes(msg)); checks++;
  const env = received.body.messages[0];
  const decipher = createDecipheriv('aes-256-gcm',key,Buffer.from(env.iv,'base64url'));
  decipher.setAAD(Buffer.from(`PG|${acc.sessionId}|A`));
  decipher.setAuthTag(Buffer.from(env.mac,'base64url'));
  const plain = Buffer.concat([decipher.update(Buffer.from(env.ciphertext,'base64url')),decipher.final()]).toString('utf8');
  assert.equal(plain,msg); checks++;
  // Verify the other direction uses a separate key and can be read only by Party A.
  const replyKey = Buffer.from(hkdfSync('sha256',sharedB,Buffer.from(acc.sessionId),Buffer.from('PG-alpha-B-to-A'),32));
  const backIv = randomBytes(12), backText = 'Hello A, this is Party B';
  const backCipher = createCipheriv('aes-256-gcm',replyKey,backIv);
  backCipher.setAAD(Buffer.from(`PG|${acc.sessionId}|B`));
  const backCt = Buffer.concat([backCipher.update(backText,'utf8'),backCipher.final()]);
  const backMac = backCipher.getAuthTag();
  const backSend = await req('POST',`/v1/sessions/${acc.sessionId}/messages`,b.token,{
    iv:backIv.toString('base64url'),ciphertext:backCt.toString('base64url'),mac:backMac.toString('base64url') });
  assert.equal(backSend.status,201); checks++;
  const backReceive = await req('GET',`/v1/sessions/${acc.sessionId}/messages`,a.token);
  assert.equal(backReceive.body.messages.length,1); checks++;
  const backEnv = backReceive.body.messages[0];
  const backDecipher = createDecipheriv('aes-256-gcm',replyKey,Buffer.from(backEnv.iv,'base64url'));
  backDecipher.setAAD(Buffer.from(`PG|${acc.sessionId}|B`));
  backDecipher.setAuthTag(Buffer.from(backEnv.mac,'base64url'));
  assert.equal(Buffer.concat([backDecipher.update(Buffer.from(backEnv.ciphertext,'base64url')),
    backDecipher.final()]).toString('utf8'),backText); checks++;
  const attackerWrite = await req('POST',`/v1/sessions/${acc.sessionId}/messages`,outsider.token,{
    iv:backIv.toString('base64url'),ciphertext:backCt.toString('base64url'),mac:backMac.toString('base64url') });
  assert.equal(attackerWrite.status,403); checks++;
  // Altered ciphertext must fail authenticated decryption at the recipient.
  const tampered = Buffer.from(ciphertext); tampered[0] ^= 0x01;
  const badDecipher = createDecipheriv('aes-256-gcm',key,iv);
  badDecipher.setAAD(Buffer.from(`PG|${acc.sessionId}|A`));
  badDecipher.setAuthTag(mac);
  assert.throws(() => Buffer.concat([badDecipher.update(tampered),badDecipher.final()])); checks++;
  const destructive = await req('GET',`/v1/sessions/${acc.sessionId}/messages`,b.token);
  assert.equal(destructive.body.messages.length,0); checks++;
  const end = await req('POST',`/v1/sessions/${acc.sessionId}/end`,b.token,{});
  assert.equal(end.body.state,'ended'); checks++;
  const ended = await req('GET',`/v1/sessions/${acc.sessionId}`,a.token);
  assert.equal(ended.body.state,'ended');
  assert.equal(ended.body.peerKey,null); checks++;
  const after = await req('POST',`/v1/sessions/${acc.sessionId}/messages`,a.token,{iv:iv.toString('base64url'),ciphertext:ciphertext.toString('base64url'),mac:mac.toString('base64url')});
  assert.equal(after.status,409); checks++;
  console.log(`PASS: ${checks} API/security-behavior checks, real X25519/HKDF/AES-GCM ciphertext delivered and decrypted by recipient`);
} finally { child.kill('SIGTERM'); }
