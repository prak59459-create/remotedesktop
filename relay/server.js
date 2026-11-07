// RemoteDesktop 中継サーバー
//
// ホスト (Windows) とビューア (iPad / Mac) の両方が外向きに接続し、
// このサーバーがバイト列を受け渡すだけ。中身は端末間で Noise 暗号化されているので、
// このサーバー (と運営者) には画面も入力も見えない。サーバーを信用する必要はない。
//
// 通り道は 2 種類あり、混ぜて使える (ホストが WebSocket、ビューアが HTTP でもよい)。
//
// WebSocket:
//   GET  /healthz                         ヘルスチェック
//   WS   /host?room=ROOM                  ホストの待ち受け (制御用、テキスト JSON)
//   WS   /connect?room=ROOM               ビューアの接続
//   WS   /accept?room=ROOM&id=SESSION     ホストがセッションを受け取る (以降はバイナリを中継)
//
// HTTP (WebSocket を通さないプロキシや社内ネットワーク向け。普通の HTTPS リクエストだけを使う):
//   POST /h/host?room=ROOM                ホストの待ち受け (ロングポーリング)。
//                                         本文 {"t":"auth","token":"<hex>","hid":"<32hex>"}
//                                         → {"events":[{"t":"incoming","id","ip"}...]} (最大 hostPollMs 待つ)
//   POST /h/connect?room=ROOM             ビューアの接続 → {"leg":"<32hex>"}
//   POST /h/accept?room=ROOM&id=SESSION   ホストがセッションを受け取る → {"leg":"<32hex>"}
//   POST /h/send?leg=LEG&seq=N            上り。本文がそのまま相手に届く。N は 1 からの通し番号
//                                         (同じ N の再送は無視するので、失敗したら同じ N で送り直してよい)
//   GET  /h/recv?leg=LEG&mode=stream      下り (ストリーム)。応答を閉じずに [u32 長さ][データ] を流し続ける。
//                                         長さ 0 は生存確認 (最初に 1 回と、その後 keepaliveMs ごと)、
//                                         0xFFFFFFFF は切断。/h/ready を受けるまではデータを流さない
//   POST /h/ready?leg=LEG                 ストリームの最初の生存確認が届いた (= 途中で溜め込まれていない) ことの通知
//   GET  /h/recv?leg=LEG&mode=poll&seq=N  下り (ロングポーリング)。ストリームが途中のプロキシに溜め込まれる環境向け。
//                                         溜まっているデータを返す (無ければ最大 pollWaitMs 待って空)。
//                                         同じ N の再要求には同じ中身を返す。切断後は 410
//   POST /h/close?leg=LEG                 切断
//
// LEG は推測できない 128bit の値で、知っている人だけがそのセッションを読み書きできる。
//
// ROOM = Base32(SHA-256("RemoteDesktop relay room v2" || トークン))[:26]。
// トークンはホストだけが持つ 256bit の秘密で、/host の最初のメッセージ (または /h/host の本文) で示す。
// 中継サーバーは ROOM がトークンのハッシュと一致するときだけ待ち受けを登録する (部屋の先取り・乗っ取り防止)。
// ROOM は登録済みの端末にだけ暗号化された通路で渡されるので、知らない人は接続を試すこともできない。

'use strict';

const http = require('http');
const crypto = require('crypto');
const { EventEmitter } = require('events');
const { WebSocketServer } = require('ws');

const config = {
  port: Number(process.env.PORT || 8080),
  trustProxy: process.env.TRUST_PROXY === '1', // Render などのリバースプロキシ配下なら 1
  maxMessage: 70 * 1024, // Noise のレコード (最大 65537 バイト) + 余裕
  maxRooms: Number(process.env.MAX_ROOMS || 500),
  // 同時セッション数。相手が受け取れないまま溜められる量 (maxBuffered) との積がメモリの上限の目安になる
  maxSessions: Number(process.env.MAX_SESSIONS || 32),
  maxPendingPerRoom: 4,
  maxConnsPerIP: 16,
  maxNewConnsPerMinute: 60,
  pendingTimeoutMs: 15000,
  pendingBufferLimit: 256 * 1024,
  maxBuffered: 8 * 1024 * 1024, // 相手が受け取れないまま溜まったら切る (メモリ保護)
  // サーバー全体で、HTTP の通り道で溜めておけるデータの合計 (無料プランのメモリを守る)
  maxTotalQueued: Number(process.env.MAX_TOTAL_QUEUED || 96 * 1024 * 1024),
  // サーバー全体の帯域 (全部屋の合計)。部屋ごとの上限だけだと、部屋を増やせば無料枠を使い切れてしまう
  totalBytesPerSecond: Number(process.env.TOTAL_BYTES_PER_SECOND || 16 * 1024 * 1024),
  totalBurstBytes: Number(process.env.TOTAL_BURST_BYTES || 128 * 1024 * 1024),
  // 1 日 (UTC) に中継してよい合計バイト数。0 なら無制限 (例: 月 5GB の無料枠なら 150000000 程度)
  dailyBytesLimit: Number(process.env.DAILY_BYTES_LIMIT || 0),
  // 使える部屋をこれだけに限る (カンマ区切り)。空なら制限なし。
  // 個人用の中継サーバーなら、自分の部屋 ID だけを入れておくと、他人がホストを登録して枠を埋めることができない
  allowedRooms: new Set((process.env.ALLOWED_ROOMS || '').split(',').map((r) => r.trim()).filter(Boolean)),
  heartbeatMs: 30000,
  hostAuthTimeoutMs: 5000,
  // 部屋ごとの帯域 (双方向合計)。無料枠の使い潰し対策。既定 8 MB/s、瞬間的には 64 MB まで
  roomBytesPerSecond: Number(process.env.ROOM_BYTES_PER_SECOND || 8 * 1024 * 1024),
  roomBurstBytes: Number(process.env.ROOM_BURST_BYTES || 64 * 1024 * 1024),
  statsIntervalMs: 10 * 60 * 1000,
  // HTTP の通り道
  maxSendBody: 1024 * 1024, // /h/send 1 回分の上限
  maxPollBody: 1024 * 1024, // /h/recv (poll) 1 回分の上限
  hostPollMs: 20000, // /h/host がイベントを待つ時間
  hostIdleMs: 45000, // この間 /h/host が来なければホストは落ちたとみなす
  pollWaitMs: 20000, // /h/recv (poll) がデータを待つ時間
  legIdleMs: 60000, // この間 /h/recv が無ければセッションを閉じる
  keepaliveMs: 15000, // ストリームの生存確認の間隔 (途中のプロキシのアイドル切断対策も兼ねる)
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

/** トークンが部屋 ID と一致するか */
function tokenMatches(token, room) {
  return typeof token === 'string' && /^[0-9a-f]{64}$/.test(token) &&
    crypto.timingSafeEqual(Buffer.from(roomFromToken(token)), Buffer.from(room));
}

const stats = { hostAuthFail: 0, rateLimited: 0, bandwidthKilled: 0, sessions: 0, httpSessions: 0, roomNotAllowed: 0, memoryKilled: 0 };

/** サーバー全体の帯域・日ごとの量・メモリ */
const totals = {
  tokens: config.totalBurstBytes,
  last: Date.now(),
  day: new Date().toISOString().slice(0, 10),
  dayBytes: 0,
  queued: 0, // HTTP の通り道で溜めているバイト数の合計
};

/** 部屋が使えるか (ALLOWED_ROOMS) */
function roomAllowed(room) {
  return config.allowedRooms.size === 0 || config.allowedRooms.has(room);
}

const ROOM_RE = /^[0-9A-Z]{26}$/;
const ID_RE = /^[0-9a-f]{32}$/;
const SEQ_RE = /^[1-9][0-9]{0,14}$/;

/**
 * room -> { host, pending: Map<id, {viewer, buffer, size, timer, ip}>, tokens, last } (tokens = 帯域のバケツ)
 * host は WSHost か HTTPHost (alive() / notify() / close() を持つ)
 */
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

function connInc(ip) {
  connsPerIP.set(ip, (connsPerIP.get(ip) || 0) + 1);
}

function connDec(ip) {
  const n = (connsPerIP.get(ip) || 1) - 1;
  if (n <= 0) connsPerIP.delete(ip);
  else connsPerIP.set(ip, n);
}

/** 接続 (WebSocket か HTTP のセッション) を IP ごとに数える */
function track(conn, ip) {
  connInc(ip);
  conn.once('close', () => connDec(ip));
}

// MARK: - セッションの片側 (leg)
//
// WebSocket と HTTP を同じように扱うための薄い層。
//   open / buffered / send(buf) / close(code, reason) と、イベント 'data' (Buffer) / 'close'

class WSLeg extends EventEmitter {
  constructor(ws) {
    super();
    this.ws = ws;
    ws.on('message', (data, isBinary) => {
      // データ経路はバイナリだけ
      if (!isBinary) return this.close(1003, 'binary only');
      this.emit('data', data);
    });
    ws.on('close', () => this.emit('close'));
    ws.on('error', () => this.close(1011, 'error'));
  }

  get open() {
    return this.ws.readyState === 1;
  }

  get buffered() {
    return this.ws.bufferedAmount;
  }

  send(buf) {
    this.ws.send(buf, { binary: true });
  }

  close(code, reason) {
    if (this.ws.readyState <= 1) this.ws.close(code, reason);
  }
}

/** leg ID -> HTTPLeg */
const httpLegs = new Map();

const CLOSE_FRAME = Buffer.from([0xff, 0xff, 0xff, 0xff]);
const KEEPALIVE_FRAME = Buffer.alloc(4);

class HTTPLeg extends EventEmitter {
  constructor(ip) {
    super();
    this.id = crypto.randomBytes(16).toString('hex');
    this.ip = ip;
    this.closed = false;
    this.queue = []; // 相手から届いて、まだこのクライアントに渡していないデータ
    this.queued = 0;
    this.upSeq = 0; // 受け取り済みの /h/send の通し番号
    this.mode = null; // 'stream' | 'poll'
    this.stream = null; // ストリームの応答
    this.ready = false; // ストリームが溜め込まれずに届くと確認できたか
    this.poll = null; // 待たせている /h/recv (poll) の { res, timer }
    this.pollSeq = 0;
    this.lastBody = null; // 直前の poll 応答 (同じ通し番号の再要求に同じ中身を返す)
    this.lastSeen = Date.now();
    httpLegs.set(this.id, this);
  }

  get open() {
    return !this.closed;
  }

  get buffered() {
    return this.queued + (this.stream ? this.stream.writableLength : 0);
  }

  send(buf) {
    if (this.closed) return;
    if (totals.queued + buf.length > config.maxTotalQueued) {
      // サーバー全体のメモリを守る (このセッションを切る。相手側も pipe で閉じられる)
      stats.memoryKilled++;
      return this.close(1013, 'server busy');
    }
    this.queue.push(buf);
    this.queued += buf.length;
    totals.queued += buf.length;
    this.flush();
  }

  /** 溜めている分を n バイト減らす (全体の計数も) */
  dequeued(n) {
    this.queued -= n;
    totals.queued = Math.max(0, totals.queued - n);
  }

  /** 溜まっているデータを、開いている下りの応答に流す */
  flush() {
    if (this.mode === 'stream' && this.stream && this.ready) {
      for (const b of this.queue) {
        const h = Buffer.alloc(4);
        h.writeUInt32BE(b.length);
        this.stream.write(h);
        this.stream.write(b);
      }
      this.queue = [];
      this.dequeued(this.queued);
      if (this.closed) this.endStream();
    } else if (this.mode === 'poll' && this.poll && (this.queued > 0 || this.closed)) {
      const { res, timer } = this.poll;
      clearTimeout(timer);
      this.poll = null;
      this.respondPoll(res);
    }
  }

  /** poll の応答。溜まっている分 (上限まで) を返す。閉じていて何も無ければ 410 */
  respondPoll(res) {
    if (this.queued === 0 && this.closed) {
      res.writeHead(410, { 'cache-control': 'no-store' });
      res.end();
      httpLegs.delete(this.id);
      return;
    }
    const parts = [];
    let size = 0;
    while (this.queue.length && size + this.queue[0].length <= config.maxPollBody) {
      const b = this.queue.shift();
      parts.push(b);
      size += b.length;
    }
    if (parts.length === 0 && this.queue.length) {
      // 1 個で上限を超える (送信側の上限より小さくはしないので普通は起きない)
      const b = this.queue.shift();
      parts.push(b);
      size = b.length;
    }
    this.dequeued(size);
    this.lastBody = Buffer.concat(parts, size);
    res.writeHead(200, {
      'content-type': 'application/octet-stream',
      'content-length': this.lastBody.length,
      'cache-control': 'no-store, no-transform',
    });
    res.end(this.lastBody);
  }

  endStream() {
    if (!this.stream) return;
    const s = this.stream;
    this.stream = null;
    s.end(CLOSE_FRAME);
  }

  close() {
    if (this.closed) return;
    this.closed = true;
    if (this.mode === 'stream' && this.ready) {
      this.flush(); // 送り出すだけ (保持はしない)
    }
    // 届けられなかった分はすぐ捨てる (閉じた接続にメモリを持たせ続けない)
    this.queue = [];
    this.dequeued(this.queued);
    this.endStream();
    if (this.poll) {
      const { res, timer } = this.poll;
      clearTimeout(timer);
      this.poll = null;
      empty(res, 410);
    }
    httpLegs.delete(this.id);
    this.emit('close');
  }

  /** 生存確認と掃除 */
  tick(now) {
    if (this.stream) this.stream.write(KEEPALIVE_FRAME);
    const waiting = this.stream || this.poll;
    if (!waiting && now - this.lastSeen > config.legIdleMs) {
      httpLegs.delete(this.id);
      this.close();
    }
  }
}

function closeBoth(a, b, code, reason) {
  for (const leg of [a, b]) {
    if (leg && leg.open) leg.close(code, reason);
  }
}

/** 部屋とサーバー全体の帯域を消費する。足りなければ false */
function spend(state, n) {
  const now = Date.now();
  state.tokens = Math.min(config.roomBurstBytes, state.tokens + ((now - state.last) / 1000) * config.roomBytesPerSecond);
  state.last = now;
  totals.tokens = Math.min(config.totalBurstBytes, totals.tokens + ((now - totals.last) / 1000) * config.totalBytesPerSecond);
  totals.last = now;
  const today = new Date(now).toISOString().slice(0, 10);
  if (today !== totals.day) {
    totals.day = today;
    totals.dayBytes = 0;
  }
  if (config.dailyBytesLimit > 0 && totals.dayBytes + n > config.dailyBytesLimit) return false;
  if (state.tokens < n || totals.tokens < n) return false;
  state.tokens -= n;
  totals.tokens -= n;
  totals.dayBytes += n;
  return true;
}

/** a で受けたバイナリを b へ。過大なバッファ、帯域超過は切断。 */
function pipe(a, b, state) {
  a.on('data', (data) => {
    if (!b.open) return;
    if (b.buffered > config.maxBuffered) return closeBoth(a, b, 1013, 'backpressure');
    if (state && !spend(state, data.length)) {
      stats.bandwidthKilled++;
      return closeBoth(a, b, 4029, 'bandwidth limit');
    }
    b.send(data);
  });
  a.on('close', () => closeBoth(a, b, 1000, 'peer closed'));
}

// MARK: - ホストの待ち受け

class WSHost {
  constructor(ws) {
    this.ws = ws;
  }

  alive() {
    return this.ws.readyState === 1;
  }

  notify(obj) {
    this.ws.send(JSON.stringify(obj));
  }

  same(other) {
    return other instanceof WSHost && other.ws === this.ws;
  }
}

class HTTPHost {
  constructor(hid, ip) {
    this.hid = hid;
    this.ip = ip;
    this.counted = false; // IP ごとの接続数に数えたか
    this.events = [];
    this.poll = null; // { res, timer }
    this.lastPoll = Date.now();
    this.dead = false;
  }

  alive() {
    return !this.dead && (this.poll !== null || Date.now() - this.lastPoll < config.hostIdleMs);
  }

  notify(obj) {
    this.events.push(obj);
    if (this.events.length > 64) this.events.shift();
    this.flush();
  }

  flush() {
    if (!this.poll || this.events.length === 0) return;
    const { res, timer } = this.poll;
    clearTimeout(timer);
    this.poll = null;
    this.lastPoll = Date.now();
    json(res, 200, { events: this.events });
    this.events = [];
  }

  same(other) {
    return other instanceof HTTPHost && other.hid === this.hid;
  }
}

/** 部屋にホストを登録する。失敗したら { code, status, reason } */
function registerHost(room, host) {
  const existing = rooms.get(room);
  if (existing && existing.host.alive() && !existing.host.same(host)) {
    // 同じトークンのホストが既に生きている (二重起動など)。先に来た方を残す。
    // 新しい方を優先すると、両方が再接続のたびに追い出し合い続ける。
    // 古い方が死んでいれば、ハートビート (最大 60 秒) で消えたあとに登録できる。
    return { code: 4009, status: 409, reason: 'room in use' };
  }
  if (!existing && rooms.size >= config.maxRooms) return { code: 4029, status: 429, reason: 'server full' };
  if (existing && existing.host.same(host)) return null; // HTTP のホストの 2 回目以降のポーリング
  if (existing && existing.host instanceof HTTPHost) releaseHost(existing.host); // 死んだ HTTP のホストの分を戻す
  const state = existing || { host, pending: new Map(), tokens: config.roomBurstBytes, last: Date.now() };
  state.host = host;
  if (host instanceof HTTPHost && !host.counted) {
    // HTTP のホストも、IP ごとの同時接続数に数える (WebSocket のホストは track で数えている)
    host.counted = true;
    connInc(host.ip);
  }
  rooms.set(room, state);
  log('host up', room.slice(0, 4) + '…', host instanceof HTTPHost ? '(http)' : '(ws)');
  return null;
}

function releaseHost(host) {
  if (host.counted) {
    host.counted = false;
    connDec(host.ip);
  }
}

/** ホストが落ちた。部屋を消して、待っているビューアを切る */
function hostDown(room, host) {
  if (host instanceof HTTPHost) releaseHost(host);
  const s = rooms.get(room);
  if (!s || s.host !== host) return;
  for (const p of s.pending.values()) {
    clearTimeout(p.timer);
    p.viewer.close(4004, 'host offline');
  }
  rooms.delete(room);
  log('host down', room.slice(0, 4) + '…');
}

function handleHost(ws, room) {
  // 最初のメッセージで部屋トークンを示すまでは何もさせない
  let authed = false;
  const host = new WSHost(ws);
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
      if (!(msg && msg.t === 'auth' && tokenMatches(msg.token, room))) {
        stats.hostAuthFail++;
        return ws.close(4003, 'bad token');
      }
      authed = true;
      clearTimeout(timer);
      const err = registerHost(room, host);
      if (err) ws.close(err.code, err.reason);
      return;
    }
    if (text === 'ping') ws.send('pong');
  });

  ws.on('close', () => {
    clearTimeout(timer);
    hostDown(room, host);
  });
}

// MARK: - セッションの成立

/** ビューアを部屋に入れられるか。だめなら { code, status, reason } */
function checkConnect(room) {
  const state = rooms.get(room);
  if (!state || !state.host.alive()) return { code: 4004, status: 404, reason: 'host offline' };
  if (state.pending.size >= config.maxPendingPerRoom) return { code: 4029, status: 429, reason: 'too many pending' };
  if (activeSessions >= config.maxSessions) return { code: 4029, status: 429, reason: 'server full' };
  return null;
}

/** ビューアの leg を部屋に入れ、ホストに知らせる (checkConnect 済みであること) */
function handleConnect(viewer, room, ip) {
  const state = rooms.get(room);
  const id = crypto.randomBytes(16).toString('hex');
  const p = { viewer, buffer: [], size: 0, ip, timer: null };
  p.timer = setTimeout(() => {
    state.pending.delete(id);
    viewer.close(4008, 'host did not accept');
  }, config.pendingTimeoutMs);
  state.pending.set(id, p);

  // ホストが受け取るまでの間に届いたデータは一時的に保持
  const onData = (data) => {
    p.size += data.length;
    if (p.size > config.pendingBufferLimit) return viewer.close(1009, 'too much data');
    p.buffer.push(data);
  };
  viewer.on('data', onData);
  p.detach = () => viewer.off('data', onData);
  viewer.once('close', () => {
    if (state.pending.get(id) === p) {
      clearTimeout(p.timer);
      state.pending.delete(id);
    }
  });

  state.host.notify({ t: 'incoming', id, ip });
}

/** ホストが受け取れるセッションか (部屋のホストが生きていて、そのホストに通知した ID だけ) */
function pendingFor(room, id) {
  const state = rooms.get(room);
  const p = state && state.pending.get(id);
  if (!p || !state.host.alive()) return null;
  return p;
}

function handleAccept(leg, room, id) {
  const state = rooms.get(room);
  const p = pendingFor(room, id);
  if (!p) return leg.close(4004, 'no such session');
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
  leg.once('close', done);
  p.viewer.once('close', done);

  pipe(p.viewer, leg, state);
  pipe(leg, p.viewer, state);
  stats.sessions++;
  for (const chunk of p.buffer) leg.send(chunk);
  p.buffer = [];
  // 受け取る前にビューアが切れていた
  if (!p.viewer.open) closeBoth(p.viewer, leg, 1000, 'peer closed');
  log('session', room.slice(0, 4) + '…', 'active=' + activeSessions);
}

// MARK: - HTTP の通り道

function json(res, status, obj) {
  const body = Buffer.from(JSON.stringify(obj));
  res.writeHead(status, {
    'content-type': 'application/json',
    'content-length': body.length,
    'cache-control': 'no-store',
  });
  res.end(body);
}

function empty(res, status) {
  res.writeHead(status, { 'cache-control': 'no-store', 'content-length': 0 });
  res.end();
}

/** 本文を上限付きで読む。超えたら null */
function readBody(req, limit) {
  return new Promise((resolve) => {
    const parts = [];
    let size = 0;
    let over = false;
    req.on('data', (d) => {
      if (over) return;
      size += d.length;
      if (size > limit) {
        over = true;
        parts.length = 0;
        return;
      }
      parts.push(d);
    });
    req.on('end', () => resolve(over ? null : Buffer.concat(parts, size)));
    req.on('error', () => resolve(null));
  });
}

async function httpHost(req, res, room, ip) {
  const body = await readBody(req, 512);
  let msg;
  try {
    msg = JSON.parse(body ? body.toString() : '');
  } catch {
    return empty(res, 400);
  }
  if (!msg || msg.t !== 'auth' || typeof msg.hid !== 'string' || !ID_RE.test(msg.hid)) return empty(res, 400);
  const st = rooms.get(room);
  const known = st && st.host instanceof HTTPHost && st.host.hid === msg.hid && st.host.alive();
  // 登録済みのホストのポーリングは数えない (20 秒ごとに来るので)
  if (!known && !admit(ip)) {
    stats.rateLimited++;
    return empty(res, 429);
  }
  if (!tokenMatches(msg.token, room)) {
    stats.hostAuthFail++;
    return empty(res, 403);
  }
  if (!known && (connsPerIP.get(ip) || 0) >= config.maxConnsPerIP) {
    stats.rateLimited++;
    return empty(res, 429);
  }
  const host = known ? st.host : new HTTPHost(msg.hid, ip);
  const err = registerHost(room, host);
  if (err) return empty(res, err.status);
  if (!known) {
    // 登録できたことをすぐ知らせる (次のポーリングからイベントを待たせる)
    host.lastPoll = Date.now();
    return json(res, 200, { events: [] });
  }

  if (host.poll) {
    // 前のポーリングが残っている (クライアント側で中断された) なら空で返す
    clearTimeout(host.poll.timer);
    json(host.poll.res, 200, { events: [] });
  }
  host.lastPoll = Date.now();
  const entry = { res, timer: null };
  entry.timer = setTimeout(() => {
    if (host.poll !== entry) return;
    host.poll = null;
    host.lastPoll = Date.now();
    json(res, 200, { events: host.events });
    host.events = [];
  }, config.hostPollMs);
  host.poll = entry;
  res.on('close', () => {
    if (host.poll === entry) {
      clearTimeout(entry.timer);
      host.poll = null;
      host.lastPoll = Date.now();
    }
  });
  host.flush();
}

function newHTTPLeg(ip) {
  const leg = new HTTPLeg(ip);
  track(leg, ip);
  stats.httpSessions++;
  return leg;
}

function httpRecv(req, res, leg, url) {
  leg.lastSeen = Date.now();
  const mode = url.searchParams.get('mode');
  if (mode === 'stream') {
    if (leg.mode === 'poll' || leg.closed) return empty(res, 410);
    // ストリームは張り直せない (どこまで届いたか分からないので)。1 本だけ
    if (leg.stream || leg.mode === 'stream') return empty(res, 409);
    leg.mode = 'stream';
    leg.stream = res;
    req.socket.setNoDelay(true);
    res.writeHead(200, {
      'content-type': 'application/octet-stream',
      'cache-control': 'no-store, no-transform',
      'x-accel-buffering': 'no', // nginx 系のプロキシに溜め込ませない
    });
    // 最初の生存確認。これがすぐ届かない経路 (溜め込むプロキシ) なら、クライアントは poll に切り替える
    res.write(KEEPALIVE_FRAME);
    res.on('close', () => {
      if (leg.stream !== res) return;
      leg.stream = null;
      if (leg.ready) {
        // データを流し始めたストリームは、どこまで届いたか分からないので再開できない。セッションごと閉じる
        leg.close();
      } else if (leg.mode === 'stream') {
        leg.mode = null; // 確認前に諦めた (poll に切り替える)
      }
    });
    return;
  }
  if (mode !== 'poll') return empty(res, 400);
  const seqText = url.searchParams.get('seq') || '';
  if (!SEQ_RE.test(seqText)) return empty(res, 400);
  const seq = Number(seqText);
  if (leg.mode === 'stream' && !leg.ready) {
    // ストリームを諦めて poll に切り替えた (まだデータは流していないので、取りこぼしは無い)
    const s = leg.stream;
    leg.stream = null;
    leg.mode = null;
    if (s) s.end();
  }
  if (leg.mode === 'stream') return empty(res, 409);
  leg.mode = 'poll';
  if (seq === leg.pollSeq && leg.lastBody) {
    // 応答が届かなかったので再要求された
    res.writeHead(200, { 'content-type': 'application/octet-stream', 'content-length': leg.lastBody.length });
    return res.end(leg.lastBody);
  }
  if (seq !== leg.pollSeq + 1) return empty(res, 409);
  leg.pollSeq = seq;
  leg.lastBody = null;
  if (leg.poll) {
    clearTimeout(leg.poll.timer);
    empty(leg.poll.res, 409);
    leg.poll = null;
  }
  if (leg.queued > 0 || leg.closed) return leg.respondPoll(res);
  const entry = { res, timer: null };
  entry.timer = setTimeout(() => {
    if (leg.poll !== entry) return;
    leg.poll = null;
    leg.lastSeen = Date.now();
    leg.respondPoll(res);
  }, config.pollWaitMs);
  leg.poll = entry;
  res.on('close', () => {
    if (leg.poll === entry) {
      clearTimeout(entry.timer);
      leg.poll = null;
      leg.lastSeen = Date.now();
    }
  });
}

async function httpSend(req, res, leg, url) {
  leg.lastSeen = Date.now();
  const seqText = url.searchParams.get('seq') || '';
  if (!SEQ_RE.test(seqText)) return empty(res, 400);
  const seq = Number(seqText);
  const body = await readBody(req, config.maxSendBody);
  if (body === null) {
    leg.close(1009, 'too much data');
    return empty(res, 413);
  }
  if (leg.closed) return empty(res, 410);
  if (seq <= leg.upSeq) return empty(res, 204); // 再送 (前回の応答が届かなかった)
  if (seq !== leg.upSeq + 1) {
    leg.close(1002, 'out of order');
    return empty(res, 409);
  }
  leg.upSeq = seq;
  if (body.length > 0) leg.emit('data', body);
  empty(res, leg.closed ? 410 : 204);
}

async function handleHTTP(req, res, url) {
  const ip = clientIP(req);
  const kind = url.pathname;
  const q = url.searchParams;
  if (req.method !== (kind === '/h/recv' ? 'GET' : 'POST')) return empty(res, 405);

  if (kind === '/h/host' || kind === '/h/connect' || kind === '/h/accept') {
    const room = q.get('room') || '';
    if (!ROOM_RE.test(room)) return empty(res, 400);
    if (!roomAllowed(room)) {
      stats.roomNotAllowed++;
      return empty(res, 404);
    }
    if (kind === '/h/host') return httpHost(req, res, room, ip);
    if (kind === '/h/connect') {
      if (!admit(ip)) {
        stats.rateLimited++;
        log('rate limited', kind);
        return empty(res, 429);
      }
      const err = checkConnect(room);
      if (err) return empty(res, err.status);
      const leg = newHTTPLeg(ip);
      handleConnect(leg, room, ip);
      return json(res, 200, { leg: leg.id });
    }
    const id = q.get('id') || '';
    if (!ID_RE.test(id)) return empty(res, 400);
    // ホストへの通知に載せた推測不能な ID を持つ場合だけ。IP 制限の対象外 (ホストのセッション数で詰まらないように)
    if (!pendingFor(room, id)) return empty(res, 404);
    const leg = newHTTPLeg(ip);
    handleAccept(leg, room, id);
    return json(res, 200, { leg: leg.id });
  }

  const legId = q.get('leg') || '';
  const leg = ID_RE.test(legId) ? httpLegs.get(legId) : undefined;
  // 知らない leg と閉じた leg は区別しない
  if (!leg) return empty(res, 410);
  if (kind === '/h/recv') return httpRecv(req, res, leg, url);
  if (kind === '/h/send') return httpSend(req, res, leg, url);
  if (kind === '/h/ready') {
    leg.lastSeen = Date.now();
    if (leg.mode !== 'stream' || !leg.stream) return empty(res, 409);
    leg.ready = true;
    leg.flush();
    return empty(res, 204);
  }
  if (kind === '/h/close') {
    httpLegs.delete(leg.id);
    leg.close(1000, 'closed');
    return empty(res, 204);
  }
  return empty(res, 404);
}

const server = http.createServer((req, res) => {
  let url;
  try {
    url = new URL(req.url, 'http://relay');
  } catch {
    return empty(res, 400);
  }
  if (url.pathname === '/healthz' || url.pathname === '/') {
    res.writeHead(200, { 'content-type': 'text/plain' });
    return res.end('ok\n');
  }
  if (url.pathname.startsWith('/h/')) {
    return handleHTTP(req, res, url).catch((e) => {
      log('http error', e && e.message);
      if (!res.headersSent) empty(res, 500);
      else res.destroy();
    });
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
  if (!roomAllowed(room)) {
    stats.roomNotAllowed++;
    socket.write('HTTP/1.1 404 Not Found\r\nConnection: close\r\n\r\n');
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
    if (kind === '/host') return handleHost(ws, room);
    const leg = new WSLeg(ws);
    if (kind === '/connect') {
      const err = checkConnect(room);
      if (err) return ws.close(err.code, err.reason);
      handleConnect(leg, room, ip);
    } else {
      handleAccept(leg, room, id);
    }
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
  // ポーリングが途絶えた HTTP のホスト
  for (const [room, s] of rooms) {
    if (s.host instanceof HTTPHost && !s.host.alive()) {
      s.host.dead = true;
      hostDown(room, s.host);
    }
  }
}, config.heartbeatMs);
heartbeat.unref();

// HTTP のストリームの生存確認と、放置された HTTP のセッションの掃除
const keepalive = setInterval(() => {
  const now = Date.now();
  for (const leg of [...httpLegs.values()]) leg.tick(now);
}, config.keepaliveMs);
keepalive.unref();

// 異常の兆候 (トークン不一致・レート制限・帯域超過) を定期的に記録
const statsTimer = setInterval(() => {
  log('stats', JSON.stringify({ rooms: rooms.size, active: activeSessions, queued: totals.queued, today: totals.dayBytes, ...stats }));
}, config.statsIntervalMs);
statsTimer.unref();

server.headersTimeout = 10000;
server.requestTimeout = 10000;

if (require.main === module) {
  server.listen(config.port, () => log('relay listening on', config.port));
}

module.exports = { server, wss, config, rooms, httpLegs, totals, connsPerIP, roomFromToken, base32 };
