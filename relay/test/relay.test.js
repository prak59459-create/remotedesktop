'use strict';
const test = require('node:test');
const assert = require('node:assert');
const crypto = require('node:crypto');
const WebSocket = require('ws');
const { server, config, roomFromToken, base32 } = require('../server');

let base;

test.before(async () => {
  config.hostAuthTimeoutMs = 300;
  await new Promise((r) => server.listen(0, '127.0.0.1', r));
  base = `ws://127.0.0.1:${server.address().port}`;
});
test.after(() => server.close());

function open(path) {
  return new Promise((resolve, reject) => {
    const ws = new WebSocket(base + path);
    // 接続直後に届くメッセージや切断を取りこぼさないよう、最初から貯めておく
    ws.inbox = [];
    ws.waiters = [];
    ws.on('message', (d, bin) => {
      const m = { d, bin };
      const w = ws.waiters.shift();
      if (w) w(m);
      else ws.inbox.push(m);
    });
    ws.closeCode = new Promise((r) => ws.once('close', (code) => r(code)));
    ws.once('open', () => resolve(ws));
    ws.once('unexpected-response', (_req, res) => reject(new Error('HTTP ' + res.statusCode)));
    ws.once('error', reject);
  });
}
const next = (ws) =>
  ws.inbox.length ? Promise.resolve(ws.inbox.shift()) : new Promise((r) => ws.waiters.push(r));
const closed = (ws) => ws.closeCode;
const newToken = () => crypto.randomBytes(32).toString('hex');

/** トークンで部屋を登録したホスト (ping/pong で登録完了を確認) */
async function host(token) {
  const room = roomFromToken(token);
  const ws = await open('/host?room=' + room);
  ws.send(JSON.stringify({ t: 'auth', token }));
  ws.send('ping');
  assert.strictEqual((await next(ws)).d.toString(), 'pong');
  return { ws, room };
}

async function session(h) {
  const viewer = await open('/connect?room=' + h.room);
  const inc = JSON.parse((await next(h.ws)).d.toString());
  const acc = await open(`/accept?room=${h.room}&id=${inc.id}`);
  return { viewer, acc, inc };
}

test('room id matches the Swift implementation', () => {
  // Swift: Base32.encode([0x00..0x0F]) と RelayRoom.id(token: [0x00]*32) の値 (SecurityTests と同じ)
  assert.strictEqual(base32(Buffer.from([...Array(16).keys()])), '000G40R40M30E209185GR38E1W');
  assert.strictEqual(roomFromToken('00'.repeat(32)).length, 26);
});

test('rejects malformed rooms and unknown paths', async () => {
  await assert.rejects(open('/host?room=short'), /HTTP 400/);
  await assert.rejects(open('/admin?room=' + 'A'.repeat(26)), /HTTP 400/);
  await assert.rejects(open('/accept?room=' + 'A'.repeat(26) + '&id=zz'), /HTTP 400/);
});

test('a host without the token cannot take a room', async () => {
  const token = newToken();
  const room = roomFromToken(token);
  // 違うトークン
  const wrong = await open('/host?room=' + room);
  wrong.send(JSON.stringify({ t: 'auth', token: newToken() }));
  assert.strictEqual(await closed(wrong), 4003);
  // 何も送らない
  const silent = await open('/host?room=' + room);
  assert.strictEqual(await closed(silent), 4001);
  // 部屋は登録されていない
  const v = await open('/connect?room=' + room);
  assert.strictEqual(await closed(v), 4004);
});

test('a second host with the same token does not kick out the first', async () => {
  const token = newToken();
  const first = await host(token);
  const second = await open('/host?room=' + first.room);
  second.send(JSON.stringify({ t: 'auth', token }));
  assert.strictEqual(await closed(second), 4009);
  // 最初のホストはそのまま使える
  first.ws.send('ping');
  assert.strictEqual((await next(first.ws)).d.toString(), 'pong');
  first.ws.close();
});

test('viewer without host is closed', async () => {
  const v = await open('/connect?room=' + 'B'.repeat(26));
  assert.strictEqual(await closed(v), 4004);
});

test('relays binary both ways; ids are single use; text on the data path is refused', async () => {
  const h = await host(newToken());
  const viewer = await open('/connect?room=' + h.room);
  viewer.send(Buffer.from([1, 2, 3])); // ホストが受け取る前に送ったデータも届く
  const inc = JSON.parse((await next(h.ws)).d.toString());
  assert.strictEqual(inc.t, 'incoming');
  assert.match(inc.id, /^[0-9a-f]{32}$/);

  await assert.rejects(open(`/accept?room=${h.room}&id=${'0'.repeat(32)}`), /HTTP 404/);

  const acc = await open(`/accept?room=${h.room}&id=${inc.id}`);
  assert.deepStrictEqual([...(await next(acc)).d], [1, 2, 3]);
  acc.send(Buffer.from([9]));
  assert.deepStrictEqual([...(await next(viewer)).d], [9]);

  await assert.rejects(open(`/accept?room=${h.room}&id=${inc.id}`), /HTTP 404/);

  const both = Promise.all([closed(viewer), closed(acc)]);
  viewer.send('text is not allowed');
  await both;
  h.ws.close();
  await closed(h.ws);
});

test('oversized messages are rejected', async () => {
  const h = await host(newToken());
  const { viewer, acc } = await session(h);
  const c = closed(viewer);
  viewer.send(Buffer.alloc(config.maxMessage + 1));
  assert.strictEqual(await c, 1009);
  acc.close();
  h.ws.close();
});

test('per-room bandwidth limit ends the session', async () => {
  const saved = [config.roomBytesPerSecond, config.roomBurstBytes];
  config.roomBytesPerSecond = 1000;
  config.roomBurstBytes = 100 * 1024;
  try {
    const h = await host(newToken());
    const { viewer, acc } = await session(h);
    const c = closed(viewer);
    for (let i = 0; i < 4; i++) viewer.send(Buffer.alloc(60 * 1024));
    assert.strictEqual(await c, 4029);
    await closed(acc);
    h.ws.close();
  } finally {
    [config.roomBytesPerSecond, config.roomBurstBytes] = saved;
  }
});

test('many sessions in a row are not blocked by the per-IP limit', async () => {
  const h = await host(newToken());
  for (let i = 0; i < 25; i++) {
    const { viewer, acc } = await session(h);
    viewer.send(Buffer.from([i]));
    assert.deepStrictEqual([...(await next(acc)).d], [i]);
    viewer.close();
    await closed(acc);
  }
  h.ws.close();
});
