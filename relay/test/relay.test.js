'use strict';
const test = require('node:test');
const assert = require('node:assert');
const crypto = require('node:crypto');
const WebSocket = require('ws');
const { server, wss, config, rooms, totals, connsPerIP, roomFromToken, base32 } = require('../server');

let base;

test.before(async () => {
  config.hostAuthTimeoutMs = 300;
  await new Promise((r) => server.listen(0, '127.0.0.1', r));
  base = `ws://127.0.0.1:${server.address().port}`;
});
test.after(() => {
  // 残っている接続も閉じる (閉じないと、Node のバージョンによってはテストのプロセスが終わらない)
  for (const ws of wss.clients) ws.terminate();
  if (server.closeAllConnections) server.closeAllConnections();
  server.close();
});

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
  // サーバーは 1009 で閉じる。Node のバージョンによっては、クライアントには異常切断 (1006) として見える
  const code = await c;
  assert.ok([1009, 1006].includes(code), 'closed with ' + code);
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

// MARK: - HTTP の通り道

function req(method, path, body, localAddress) {
  const u = new URL(base.replace('ws://', 'http://') + path);
  return new Promise((resolve, reject) => {
    const r = require('http').request(u, { method, agent: false, localAddress }, (res) => {
      const parts = [];
      res.on('data', (d) => parts.push(d));
      res.on('end', () => resolve({ status: res.statusCode, body: Buffer.concat(parts) }));
    });
    r.on('error', reject);
    if (body) r.write(body);
    r.end();
  });
}
const post = (path, body) => req('POST', path, body);
const getJSON = (r) => JSON.parse(r.body.toString());

/** ストリームの下り。フレームを読んで貯める */
function openStream(leg) {
  const u = new URL(base.replace('ws://', 'http://') + `/h/recv?leg=${leg}&mode=stream`);
  return new Promise((resolve, reject) => {
    const r = require('http').get(u, { agent: false }, (res) => {
      const s = { res, frames: [], waiters: [], buf: Buffer.alloc(0), ended: false, status: res.statusCode };
      const push = (f) => {
        const w = s.waiters.shift();
        if (w) w(f);
        else s.frames.push(f);
      };
      res.on('data', (d) => {
        s.buf = Buffer.concat([s.buf, d]);
        while (s.buf.length >= 4) {
          const n = s.buf.readUInt32BE(0);
          if (n === 0xffffffff) {
            s.buf = s.buf.subarray(4);
            push('closed');
            continue;
          }
          if (s.buf.length < 4 + n) break;
          push(n === 0 ? 'keepalive' : s.buf.subarray(4, 4 + n));
          s.buf = s.buf.subarray(4 + n);
        }
      });
      res.on('end', () => push('end'));
      s.next = () => (s.frames.length ? Promise.resolve(s.frames.shift()) : new Promise((r2) => s.waiters.push(r2)));
      s.close = () => r.destroy();
      resolve(s);
    });
    r.on('error', reject);
  });
}

/** HTTP のホスト。ポーリングを 1 回投げて、そのイベント待ちを返す */
function hostPoll(token, hid) {
  return post('/h/host?room=' + roomFromToken(token), JSON.stringify({ t: 'auth', token, hid }));
}
const newHid = () => crypto.randomBytes(16).toString('hex');

test('http: host auth and room ownership', async () => {
  const token = newToken();
  const room = roomFromToken(token);
  // 違うトークン・壊れた本文
  assert.strictEqual((await post('/h/host?room=' + room, JSON.stringify({ t: 'auth', token: newToken(), hid: newHid() }))).status, 403);
  assert.strictEqual((await post('/h/host?room=' + room, 'nope')).status, 400);
  assert.strictEqual((await post('/h/host?room=short', '{}')).status, 400);
  assert.strictEqual((await req('GET', '/h/host?room=' + room)).status, 405);
  // 部屋は登録されていない
  assert.strictEqual((await post('/h/connect?room=' + room)).status, 404);

  // 正しいトークンで登録。最初の応答はすぐ返る (登録できたことの通知)
  const hid = newHid();
  const reg = await hostPoll(token, hid);
  assert.strictEqual(reg.status, 200);
  assert.deepStrictEqual(getJSON(reg).events, []);
  // 2 回目からはイベントを待たせる
  const first = hostPoll(token, hid);
  await new Promise((r) => setTimeout(r, 50));
  // 別のホスト (hid が違う) は同じ部屋を取れない。WebSocket のホストも同じ
  assert.strictEqual((await hostPoll(token, newHid())).status, 409);
  const ws = await open('/host?room=' + room);
  ws.send(JSON.stringify({ t: 'auth', token }));
  assert.strictEqual(await closed(ws), 4009);

  // ビューアが来るとポーリングが返る
  const v = await post('/h/connect?room=' + room);
  assert.strictEqual(v.status, 200);
  const r = await first;
  assert.strictEqual(r.status, 200);
  const ev = getJSON(r).events;
  assert.strictEqual(ev.length, 1);
  assert.strictEqual(ev[0].t, 'incoming');
  assert.match(ev[0].id, /^[0-9a-f]{32}$/);
  await post(`/h/close?leg=${getJSON(v).leg}`);
});

test('http: viewer and host relay bytes both ways (stream down, numbered posts up)', async () => {
  const token = newToken();
  const room = roomFromToken(token);
  const hid = newHid();
  assert.strictEqual((await hostPoll(token, hid)).status, 200);
  const poll = hostPoll(token, hid);
  await new Promise((r) => setTimeout(r, 50));
  const v = getJSON(await post('/h/connect?room=' + room)).leg;
  // 受け取られる前に送ったデータも届く
  assert.strictEqual((await post(`/h/send?leg=${v}&seq=1`, Buffer.from([1, 2, 3]))).status, 204);
  const id = getJSON(await poll).events[0].id;
  assert.strictEqual((await post(`/h/accept?room=${room}&id=${'0'.repeat(32)}`)).status, 404);
  const acc = await post(`/h/accept?room=${room}&id=${id}`);
  assert.strictEqual(acc.status, 200);
  const h = getJSON(acc).leg;
  // ID は 1 回限り
  assert.strictEqual((await post(`/h/accept?room=${room}&id=${id}`)).status, 404);

  const hs = await openStream(h);
  assert.strictEqual(hs.status, 200);
  assert.strictEqual(await hs.next(), 'keepalive');
  // /h/ready の前はデータを流さない
  assert.strictEqual((await post(`/h/ready?leg=${h}`)).status, 204);
  assert.deepStrictEqual([...(await hs.next())], [1, 2, 3]);
  // ストリームは 1 本だけ
  assert.strictEqual((await openStream(h)).status, 409);

  const vs = await openStream(v);
  assert.strictEqual(await vs.next(), 'keepalive');
  await post(`/h/ready?leg=${v}`);
  await post(`/h/send?leg=${h}&seq=1`, Buffer.from([9]));
  assert.deepStrictEqual([...(await vs.next())], [9]);

  // 同じ番号の再送は無視、番号の飛びは切断
  assert.strictEqual((await post(`/h/send?leg=${v}&seq=1`, Buffer.from([7]))).status, 204);
  assert.strictEqual((await post(`/h/send?leg=${v}&seq=2`, Buffer.from([8]))).status, 204);
  assert.deepStrictEqual([...(await hs.next())], [8]);
  assert.strictEqual((await post(`/h/send?leg=${v}&seq=9`, Buffer.from([8]))).status, 409);
  assert.strictEqual(await vs.next(), 'closed');
  assert.strictEqual(await hs.next(), 'closed');
  assert.strictEqual((await post(`/h/send?leg=${h}&seq=2`, Buffer.from([1]))).status, 410);
});

test('http: poll fallback when the stream is held back; mixed with a WebSocket host', async () => {
  const h = await host(newToken()); // ホストは WebSocket
  const v = getJSON(await post('/h/connect?room=' + h.room)).leg;
  const inc = JSON.parse((await next(h.ws)).d.toString());
  const acc = await open(`/accept?room=${h.room}&id=${inc.id}`);

  // ストリームを開いたが ready を送らずに諦めた (溜め込むプロキシを想定)
  const vs = await openStream(v);
  assert.strictEqual(await vs.next(), 'keepalive');
  acc.send(Buffer.from([5, 6]));
  vs.close();
  await new Promise((r) => setTimeout(r, 50));
  // poll では取りこぼさずに受け取れる。同じ番号の再要求には同じ中身
  let r = await req('GET', `/h/recv?leg=${v}&mode=poll&seq=1`);
  assert.deepStrictEqual([...r.body], [5, 6]);
  r = await req('GET', `/h/recv?leg=${v}&mode=poll&seq=1`);
  assert.deepStrictEqual([...r.body], [5, 6]);
  // 待っている間に届いたデータで返る
  const waiting = req('GET', `/h/recv?leg=${v}&mode=poll&seq=2`);
  await new Promise((r2) => setTimeout(r2, 50));
  acc.send(Buffer.from([7]));
  assert.deepStrictEqual([...(await waiting).body], [7]);
  // 番号の飛びは拒否
  assert.strictEqual((await req('GET', `/h/recv?leg=${v}&mode=poll&seq=5`)).status, 409);
  // 上りも届く
  await post(`/h/send?leg=${v}&seq=1`, Buffer.from([1]));
  assert.deepStrictEqual([...(await next(acc)).d], [1]);

  // ホスト側が切ると、ビューアの poll は 410
  acc.close();
  await closed(acc);
  await new Promise((r2) => setTimeout(r2, 50));
  assert.strictEqual((await req('GET', `/h/recv?leg=${v}&mode=poll&seq=3`)).status, 410);
  h.ws.close();
});

test('http: unknown legs, oversized posts and leg ids are not guessable', async () => {
  assert.strictEqual((await post(`/h/send?leg=${'0'.repeat(32)}&seq=1`, Buffer.from([1]))).status, 410);
  assert.strictEqual((await req('GET', `/h/recv?leg=zz&mode=poll&seq=1`)).status, 410);
  const h = await host(newToken());
  const v = getJSON(await post('/h/connect?room=' + h.room)).leg;
  assert.match(v, /^[0-9a-f]{32}$/);
  await next(h.ws);
  assert.strictEqual((await post(`/h/send?leg=${v}&seq=0`, Buffer.from([1]))).status, 400);
  assert.strictEqual((await post(`/h/send?leg=${v}&seq=1`, Buffer.alloc(config.maxSendBody + 1))).status, 413);
  assert.strictEqual((await post(`/h/send?leg=${v}&seq=1`, Buffer.from([1]))).status, 410);
  h.ws.close();
});

test('http: hosts count toward the per-IP connection limit', async () => {
  // ほかのテストの接続と混ざらないよう、別の送信元アドレス (127.0.0.2) から試す
  const from = '127.0.0.2';
  const poll = (t, hid) => req('POST', '/h/host?room=' + roomFromToken(t), JSON.stringify({ t: 'auth', token: t, hid }), from);
  const saved = [config.maxConnsPerIP, config.maxNewConnsPerMinute];
  config.maxConnsPerIP = 1;
  config.maxNewConnsPerMinute = 1000;
  const t1 = newToken(), t2 = newToken();
  try {
    const hid = newHid();
    assert.strictEqual((await poll(t1, hid)).status, 200);
    assert.strictEqual(connsPerIP.get(from), 1); // HTTP のホストも 1 つの接続として数える
    // 上限 1 に達しているので、同じ IP から別の部屋のホストは登録できない
    assert.strictEqual((await poll(t2, newHid())).status, 429);
    assert.ok(!rooms.has(roomFromToken(t2)));
    // 登録済みのホストのポーリングは、上限に関係なく続けられる
    const again = poll(t1, hid);
    await new Promise((r) => setTimeout(r, 50));
    rooms.get(roomFromToken(t1)).host.notify({ t: 'incoming', id: '0'.repeat(32), ip: 'x' });
    assert.strictEqual((await again).status, 200);
  } finally {
    [config.maxConnsPerIP, config.maxNewConnsPerMinute] = saved;
    const st = rooms.get(roomFromToken(t1));
    if (st) st.host.dead = true;
  }
});

test('ALLOWED_ROOMS limits the relay to the listed rooms', async () => {
  const mine = newToken();
  const myRoom = roomFromToken(mine);
  config.allowedRooms = new Set([myRoom]);
  try {
    // 他人の部屋はホストも接続もできない
    assert.strictEqual((await hostPoll(newToken(), newHid())).status, 404);
    await assert.rejects(open('/host?room=' + roomFromToken(newToken())), /HTTP 404/);
    // 自分の部屋は使える
    assert.strictEqual((await hostPoll(mine, newHid())).status, 200);
  } finally {
    config.allowedRooms = new Set();
    const st = rooms.get(myRoom);
    if (st) st.host.dead = true;
  }
});

test('server-wide limits: queued memory and daily bytes end sessions', async () => {
  const savedQ = config.maxTotalQueued;
  const savedDaily = config.dailyBytesLimit;
  try {
    // 受け取らない HTTP のビューアに送り続けると、全体の上限で切られる
    config.maxTotalQueued = 200 * 1024;
    const h = await host(newToken());
    const v = getJSON(await post('/h/connect?room=' + h.room)).leg;
    const inc = JSON.parse((await next(h.ws)).d.toString());
    const acc = await open(`/accept?room=${h.room}&id=${inc.id}`);
    const c = closed(acc);
    for (let i = 0; i < 6; i++) acc.send(Buffer.alloc(60 * 1024));
    await c;
    assert.strictEqual(totals.queued, 0); // 閉じたら溜めていた分はすぐ捨てる
    assert.strictEqual((await req('GET', `/h/recv?leg=${v}&mode=poll&seq=1`)).status, 410);
    config.maxTotalQueued = savedQ;

    // 1 日の上限を超えたら、それ以上は中継しない
    config.dailyBytesLimit = totals.dayBytes + 1000;
    const { viewer, acc: acc2 } = await session(h);
    const c2 = closed(viewer);
    viewer.send(Buffer.alloc(2000));
    assert.strictEqual(await c2, 4029);
    await closed(acc2);
    h.ws.close();
  } finally {
    config.maxTotalQueued = savedQ;
    config.dailyBytesLimit = savedDaily;
  }
});
