// RemoteDesktop 中継サーバー
//
// ホスト (Windows) とビューア (iPad / Mac) の両方が外向きに WebSocket で接続し、
// このサーバーがバイト列を受け渡すだけ。中身は端末間で Noise 暗号化されているので、
// このサーバー (と運営者) には画面も入力も見えない。サーバーを信用する必要はない。
//
//   GET  /healthz                         ヘルスチェック
//   WS   /host?room=ROOM                  ホストの待ち受け (制御用、テキスト JSON)
//   WS   /connect?room=ROOM               ビューアの接続
//   WS   /accept?room=ROOM&id=SESSION     ホストがセッションを受け取る (以降はバイナリを中継)
//
// ROOM = Base32(SHA-256("RemoteDesktop relay room v2" || トークン))[:26]。
// トークンはホストだけが持つ 256bit の秘密で、/host の最初のメッセージ {"t":"auth","token":"<hex>"} で示す。
// 中継サーバーは ROOM がトークンのハッシュと一致するときだけ待ち受けを登録する (部屋の先取り・乗っ取り防止)。
// ROOM は登録済みの端末にだけ暗号化された通路で渡されるので、知らない人は接続を試すこともできない。

'use strict';

const http = require('http');
const crypto = require('crypto');
const { WebSocketServer } = require('ws');

const config = {
  port: Number(process.env.PORT || 8080),
  trustProxy: process.env.TRUST_PROXY === '1', // Render などのリバースプロキシ配下なら 1
  maxMessage: 70 * 1024, // Noise のレコード (最大 65537 バイト) + 余裕
  maxRooms: Number(process.env.MAX_ROOMS || 500),
  maxSessions: Number(process.env.MAX_SESSIONS || 200),
  maxPendingPerRoom: 4,
  maxConnsPerIP: 16,
  maxNewConnsPerMinute: 60,
  pendingTimeoutMs: 15000,
  pendingBufferLimit: 256 * 1024,
  maxBuffered: 16 * 1024 * 1024, // 相手が受け取れないまま溜まったら切る (メモリ保護)
  heartbeatMs: 30000,
  hostAuthTimeoutMs: 5000,
  // 部屋ごとの帯域 (双方向合計)。無料枠の使い潰し対策。既定 8 MB/s、瞬間的には 64 MB まで
  roomBytesPerSecond: Number(process.env.ROOM_BYTES_PER_SECOND || 8 * 1024 * 1024),
  roomBurstBytes: Number(process.env.ROOM_BURST_BYTES || 64 * 1024 * 1024),
  statsIntervalMs: 10 * 60 * 1000,
};

const ROOM_LABEL = Buffer.from('RemoteDesktop relay room v2', 'utf8');
const B32 = '0123456789ABCDEFGHJKMNPQRSTVWXYZ';

/** Crockford Base32 (Swift 側の Base32.encode と同じ) */
function base32(buf) {
  let out = '';
  let bits = 0;
  let value = 0;
  for (const b of buf) {
    value = (value << 8) | b;
    bits += 8;
    while (bits >= 5) {
      out += B32[(value >>> (bits - 5)) & 31];
      bits -= 5;
    }
    value &= (1 << bits) - 1;
  }
  if (bits > 0) out += B32[(value << (5 - bits)) & 31];
  return out;
}

function roomFromToken(tokenHex) {
  const token = Buffer.from(tokenHex, 'hex');
  const digest = crypto.createHash('sha256').update(ROOM_LABEL).update(token).digest();
  return base32(digest.subarray(0, 16));
}

const stats = { hostAuthFail: 0, rateLimited: 0, bandwidthKilled: 0, sessions: 0 };

const ROOM_RE = /^[0-9A-Z]{26}$/;
const ID_RE = /^[0-9a-f]{32}$/;

/** room -> { host, pending: Map<id, {viewer, buffer, size, timer, ip}>, tokens, last } (tokens = 帯域のバケツ) */
const rooms = new Map();
let activeSessions = 0;

const connsPerIP = new Map();
const recentConns = new Map(); // ip -> timestamps (直近 1 分)

function clientIP(req) {
  if (config.trustProxy) {
    const xff = req.headers['x-forwarded-for'];
    // 末尾 = 直前のプロキシ (Render) が付け足した値。先頭はクライアントが自由に書けるので使わない
    if (typeof xff === 'string' && xff.length > 0) return xff.split(',').pop().trim().slice(0, 64);
  }
  return (req.socket.remoteAddress || 'unknown').slice(0, 64);
}

function log(...args) {
  // 中身は記録しない。部屋 ID も先頭だけ。
  console.log(new Date().toISOString(), ...args);
}

function admit(ip) {
  const now = Date.now();
  const list = (recentConns.get(ip) || []).filter((t) => now - t < 60000);
  if (list.length >= config.maxNewConnsPerMinute) return false;
  if ((connsPerIP.get(ip) || 0) >= config.maxConnsPerIP) return false;
  list.push(now);
  recentConns.set(ip, list);
  return true;
}

function track(ws, ip) {
  connsPerIP.set(ip, (connsPerIP.get(ip) || 0) + 1);
  ws.on('close', () => {
    const n = (connsPerIP.get(ip) || 1) - 1;
    if (n <= 0) connsPerIP.delete(ip);
    else connsPerIP.set(ip, n);
  });
}

function closeBoth(a, b, code, reason) {
  for (const ws of [a, b]) {
    if (ws && ws.readyState <= 1) ws.close(code, reason);
  }
}

/** 部屋の帯域を消費する。足りなければ false */
function spend(state, n) {
  const now = Date.now();
  state.tokens = Math.min(config.roomBurstBytes, state.tokens + ((now - state.last) / 1000) * config.roomBytesPerSecond);
  state.last = now;
  if (state.tokens < n) return false;
  state.tokens -= n;
  return true;
}

/** a で受けたバイナリを b へ。テキストや過大なバッファ、帯域超過は切断。 */
function pipe(a, b, state) {
  a.on('message', (data, isBinary) => {
    if (!isBinary) return closeBoth(a, b, 1003, 'binary only');
    if (b.readyState !== 1) return;
    if (b.bufferedAmount > config.maxBuffered) return closeBoth(a, b, 1013, 'backpressure');
    if (state && !spend(state, data.length)) {
      stats.bandwidthKilled++;
      return closeBoth(a, b, 4029, 'bandwidth limit');
    }
    b.send(data, { binary: true });
  });
  a.on('close', () => closeBoth(a, b, 1000, 'peer closed'));
  a.on('error', () => closeBoth(a, b, 1011, 'error'));
}

function handleHost(ws, room, ip) {
  // 最初のメッセージで部屋トークンを示すまでは何もさせない
  let authed = false;
  const timer = setTimeout(() => {
    if (!authed) ws.close(4001, 'auth timeout');
  }, config.hostAuthTimeoutMs);

  ws.on('message', (data, isBinary) => {
    if (isBinary || data.length > 256) return ws.close(1003, 'control only');
    const text = data.toString();
    if (!authed) {
      let msg;
      try {
        msg = JSON.parse(text);
      } catch {
        return ws.close(4001, 'bad auth');
      }
      const token = msg && msg.t === 'auth' && typeof msg.token === 'string' ? msg.token : '';
      const ok = /^[0-9a-f]{64}$/.test(token) &&
        crypto.timingSafeEqual(Buffer.from(roomFromToken(token)), Buffer.from(room));
      if (!ok) {
        stats.hostAuthFail++;
        return ws.close(4003, 'bad token');
      }
      authed = true;
      clearTimeout(timer);
      return register();
    }
    if (text === 'ping') ws.send('pong');
  });

  function register() {
    const existing = rooms.get(room);
    if (existing && existing.host.readyState === 1 && existing.host !== ws) {
      // 同じトークンを持つホストが既にいる (二重起動など)。新しい方を優先して古い方を切る
      existing.host.close(4010, 'replaced');
    }
    if (!existing && rooms.size >= config.maxRooms) return ws.close(4029, 'server full');
    const state = existing || { host: ws, pending: new Map(), tokens: config.roomBurstBytes, last: Date.now() };
    state.host = ws;
    rooms.set(room, state);
    log('host up', room.slice(0, 4) + '…');
  }

  ws.on('close', () => {
    clearTimeout(timer);
    const s = rooms.get(room);
    if (s && s.host === ws) {
      for (const p of s.pending.values()) {
        clearTimeout(p.timer);
        p.viewer.close(4004, 'host offline');
      }
      rooms.delete(room);
      log('host down', room.slice(0, 4) + '…');
    }
  });
}

function handleConnect(ws, room, ip) {
  const state = rooms.get(room);
  if (!state || state.host.readyState !== 1) return ws.close(4004, 'host offline');
  if (state.pending.size >= config.maxPendingPerRoom) return ws.close(4029, 'too many pending');
  if (activeSessions >= config.maxSessions) return ws.close(4029, 'server full');

  const id = crypto.randomBytes(16).toString('hex');
  const p = { viewer: ws, buffer: [], size: 0, ip, timer: null };
  p.timer = setTimeout(() => {
    state.pending.delete(id);
    ws.close(4008, 'host did not accept');
  }, config.pendingTimeoutMs);
  state.pending.set(id, p);

  // ホストが受け取るまでの間に届いたデータは一時的に保持
  const onMessage = (data, isBinary) => {
    if (!isBinary) return ws.close(1003, 'binary only');
    p.size += data.length;
    if (p.size > config.pendingBufferLimit) return ws.close(1009, 'too much data');
    p.buffer.push(data);
  };
  ws.on('message', onMessage);
  p.detach = () => ws.off('message', onMessage);
  ws.on('close', () => {
    if (state.pending.get(id) === p) {
      clearTimeout(p.timer);
      state.pending.delete(id);
    }
  });

  state.host.send(JSON.stringify({ t: 'incoming', id, ip }));
}

function handleAccept(ws, room, id) {
  const state = rooms.get(room);
  const p = state && state.pending.get(id);
  // 部屋のホスト制御接続が生きていて、そのホストに通知した ID だけを受け付ける
  if (!p || state.host.readyState !== 1) return ws.close(4004, 'no such session');
  state.pending.delete(id);
  clearTimeout(p.timer);
  p.detach();
  activeSessions++;
  let counted = true;
  const done = () => {
    if (counted) {
      counted = false;
      activeSessions--;
    }
  };
  ws.on('close', done);
  p.viewer.on('close', done);

  pipe(p.viewer, ws, state);
  pipe(ws, p.viewer, state);
  stats.sessions++;
  for (const chunk of p.buffer) ws.send(chunk, { binary: true });
  p.buffer = [];
  log('session', room.slice(0, 4) + '…', 'active=' + activeSessions);
}

const server = http.createServer((req, res) => {
  if (req.url === '/healthz' || req.url === '/') {
    res.writeHead(200, { 'content-type': 'text/plain' });
    return res.end('ok\n');
  }
  res.writeHead(404);
  res.end();
});

const wss = new WebSocketServer({
  noServer: true,
  maxPayload: config.maxMessage,
  perMessageDeflate: false, // 暗号文は圧縮できない。圧縮系の攻撃面も減らす
});

server.on('upgrade', (req, socket, head) => {
  const ip = clientIP(req);
  let url;
  try {
    url = new URL(req.url, 'http://relay');
  } catch {
    return socket.destroy();
  }
  const room = url.searchParams.get('room') || '';
  const id = url.searchParams.get('id') || '';
  const kind = url.pathname;
  const valid =
    ROOM_RE.test(room) &&
    (kind === '/host' || kind === '/connect' || (kind === '/accept' && ID_RE.test(id)));
  if (!valid) {
    socket.write('HTTP/1.1 400 Bad Request\r\nConnection: close\r\n\r\n');
    return socket.destroy();
  }
  if (kind === '/accept') {
    // ホストへの通知に載せた推測不能な ID を持つ場合だけ。IP 制限の対象外 (ホストのセッション数で詰まらないように)
    const st = rooms.get(room);
    if (!st || !st.pending.has(id)) {
      socket.write('HTTP/1.1 404 Not Found\r\nConnection: close\r\n\r\n');
      return socket.destroy();
    }
  } else if (!admit(ip)) {
    stats.rateLimited++;
    log('rate limited', kind);
    socket.write('HTTP/1.1 429 Too Many Requests\r\nConnection: close\r\n\r\n');
    return socket.destroy();
  }
  wss.handleUpgrade(req, socket, head, (ws) => {
    track(ws, ip);
    ws.isAlive = true;
    ws.on('pong', () => (ws.isAlive = true));
    ws.on('error', () => ws.terminate());
    if (kind === '/host') handleHost(ws, room, ip);
    else if (kind === '/connect') handleConnect(ws, room, ip);
    else handleAccept(ws, room, id);
  });
});

// 応答のない接続を掃除
const heartbeat = setInterval(() => {
  for (const ws of wss.clients) {
    if (!ws.isAlive) {
      ws.terminate();
      continue;
    }
    ws.isAlive = false;
    ws.ping();
  }
  const now = Date.now();
  for (const [ip, list] of recentConns) {
    if (list.every((t) => now - t >= 60000)) recentConns.delete(ip);
  }
}, config.heartbeatMs);
heartbeat.unref();

// 異常の兆候 (トークン不一致・レート制限・帯域超過) を定期的に記録
const statsTimer = setInterval(() => {
  log('stats', JSON.stringify({ rooms: rooms.size, active: activeSessions, ...stats }));
}, config.statsIntervalMs);
statsTimer.unref();

server.headersTimeout = 10000;
server.requestTimeout = 10000;

if (require.main === module) {
  server.listen(config.port, () => log('relay listening on', config.port));
}

module.exports = { server, config, rooms, roomFromToken, base32 };
