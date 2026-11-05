'use strict';
const test = require('node:test');
const assert = require('node:assert');
const WebSocket = require('ws');
const { server, config } = require('../server');

const ROOM = 'A'.repeat(26);
let base;

test.before(async () => {
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

test('rejects malformed rooms and unknown paths', async () => {
  await assert.rejects(open('/host?room=short'), /HTTP 400/);
  await assert.rejects(open('/admin?room=' + ROOM), /HTTP 400/);
  await assert.rejects(open('/accept?room=' + ROOM + '&id=zz'), /HTTP 400/);
});

test('viewer without host is closed', async () => {
  const v = await open('/connect?room=' + 'B'.repeat(26));
  assert.strictEqual(await closed(v), 4004);
});

test('relays binary both ways, room cannot be taken over', async () => {
  const host = await open('/host?room=' + ROOM);
  host.send('ping');
  assert.strictEqual((await next(host)).d.toString(), 'pong');

  const squatter = await open('/host?room=' + ROOM);
  assert.strictEqual(await closed(squatter), 4009);

  const viewer = await open('/connect?room=' + ROOM);
  viewer.send(Buffer.from([1, 2, 3])); // ホストが受け取る前に送ったデータも届く
  const inc = JSON.parse((await next(host)).d.toString());
  assert.strictEqual(inc.t, 'incoming');
  assert.match(inc.id, /^[0-9a-f]{32}$/);

  // 存在しないセッション ID は WebSocket を確立する前に拒否
  await assert.rejects(open(`/accept?room=${ROOM}&id=${'0'.repeat(32)}`), /HTTP 404/);

  const acc = await open(`/accept?room=${ROOM}&id=${inc.id}`);
  const first = await next(acc);
  assert.deepStrictEqual([...first.d], [1, 2, 3]);
  acc.send(Buffer.from([9]));
  assert.deepStrictEqual([...(await next(viewer)).d], [9]);

  // 同じ ID は二度使えない
  await assert.rejects(open(`/accept?room=${ROOM}&id=${inc.id}`), /HTTP 404/);

  // データ経路でテキストを送ると両方切断
  const both = Promise.all([closed(viewer), closed(acc)]);
  viewer.send('text is not allowed');
  await both;
  host.close();
  await closed(host);
});

test('oversized messages are rejected', async () => {
  const host = await open('/host?room=' + 'C'.repeat(26));
  const viewer = await open('/connect?room=' + 'C'.repeat(26));
  const inc = JSON.parse((await next(host)).d.toString());
  const acc = await open(`/accept?room=${'C'.repeat(26)}&id=${inc.id}`);
  const c = closed(viewer);
  viewer.send(Buffer.alloc(config.maxMessage + 1));
  assert.strictEqual(await c, 1009);
  acc.close();
  host.close();
});

test('many sessions in a row are not blocked by the per-IP limit', async () => {
  const room = 'D'.repeat(26);
  const host = await open('/host?room=' + room);
  for (let i = 0; i < 25; i++) {
    const viewer = await open('/connect?room=' + room);
    const inc = JSON.parse((await next(host)).d.toString());
    const acc = await open(`/accept?room=${room}&id=${inc.id}`);
    viewer.send(Buffer.from([i]));
    assert.deepStrictEqual([...(await next(acc)).d], [i]);
    viewer.close();
    await closed(acc);
  }
  host.close();
});
