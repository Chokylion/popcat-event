// Tiny Supabase RPC client — no SDK, PostgREST is just HTTP.
let skew = 0; // serverNow - clientNow, so timers survive a wrong phone clock

async function rpc(fn, args = {}, opts = {}) {
  const res = await fetch(`${CFG.SUPABASE_URL}/rest/v1/rpc/${fn}`, {
    method: 'POST',
    headers: {
      apikey: CFG.SUPABASE_ANON_KEY,
      Authorization: `Bearer ${CFG.SUPABASE_ANON_KEY}`,
      'Content-Type': 'application/json'
    },
    body: JSON.stringify(args),
    keepalive: !!opts.keepalive
  });
  const body = await res.json().catch(() => null);
  if (!res.ok) {
    const err = new Error((body && (body.message || body.hint)) || `${fn} failed (${res.status})`);
    // Set ONLY when the server actually answered. A dropped connection rejects
    // out of fetch() instead, so callers can tell "the row is gone" from "no signal".
    err.http = res.status;
    throw err;
  }
  if (body && body.server_now) skew = Date.parse(body.server_now) - Date.now();
  return body;
}

const serverNow = () => Date.now() + skew;

/* The page fires its own get_board from <head>, long before this file is even
   parsed (see the inline script there). This hands that in-flight request to
   the first poll() instead of making a second, identical one.
   One-shot on purpose: it nulls the handle, so every later poll goes down the
   normal rpc() path and a failed prefetch degrades to exactly the old code. */
async function firstBoard() {
  const p = window.__board0;
  if (!p) return null;
  window.__board0 = null;
  const b = await p;
  /* Skew must be measured against when the reply LANDED, not now. rpc() parses
     its response the instant it arrives so the two are the same thing there;
     this one can sit in memory for seconds while the page finishes booting, and
     using Date.now() here would push the clock that far backwards -- which the
     grand countdown runs on, so it would literally count from the wrong number. */
  if (b && b.server_now) skew = Date.parse(b.server_now) - (window.__board0t || Date.now());
  return b;
}

// ms left in the round; 0 when stopped or finished
function msLeft(endsAt) {
  if (!endsAt) return 0;
  return Math.max(0, Date.parse(endsAt) - serverNow());
}

function clock(ms) {
  const t = Math.ceil(ms / 1000);
  const d = Math.floor(t / 86400), h = Math.floor((t % 86400) / 3600);
  const m = Math.floor((t % 3600) / 60), s = t % 60;
  if (d) return `${d}d ${h}h`;                       // multi-day event countdown
  if (h) return `${h}:${String(m).padStart(2, '0')}:${String(s).padStart(2, '0')}`;
  return `${String(m).padStart(2, '0')}:${String(s).padStart(2, '0')}`;
}

const num = n => Number(n || 0).toLocaleString('en-US');

// Short pop blip. No audio file, no autoplay block (created on first tap).
let ac = null;
function audioCtx(noResume) {
  ac = ac || new (window.AudioContext || window.webkitAudioContext)();
  if (!noResume && ac.state === 'suspended') ac.resume();
  return ac;
}

/* Opening the audio device is SYNCHRONOUS and slow: measured 1705ms inside the
   very first Snd.beat(), which lands on the "5" of the countdown — so the one
   moment the whole room is watching froze for the better part of two seconds
   and every later beat ran late. Nothing about that cost belongs to the
   countdown, so the device is opened while the page is idle instead. It starts
   suspended until a real gesture, exactly as it did before. */
function warmAudio() { try { audioCtx(true); } catch { } }

function pop(muted) {
  if (muted) return;
  try {
    const a = audioCtx();
    const t = a.currentTime, o = a.createOscillator(), g = a.createGain();
    o.type = 'sine';
    o.frequency.setValueAtTime(760 + Math.random() * 180, t);
    o.frequency.exponentialRampToValueAtTime(190, t + 0.07);
    g.gain.setValueAtTime(0.28, t);
    g.gain.exponentialRampToValueAtTime(0.0001, t + 0.09);
    o.connect(g).connect(a.destination);
    o.start(t); o.stop(t + 0.1);
  } catch { /* audio is a nice-to-have */ }
}

/* ── sound: two independent switches ──────────────────────────────────────
   They are two different jobs. The blip is feedback for YOUR tap; the track is
   atmosphere for the ROOM. Somebody who wants the music without a blip on each
   of four hundred taps can now have exactly that, and the host can kill the
   music from the projector without silencing the countdown.

   Defaults differ on purpose: the projector owns the room's speakers so music
   starts on, while a hundred phones playing the same track a second out of sync
   would be noise, so phones start off. The file is only fetched once music is
   actually switched on — preload='none' keeps 3 MB off every phone that never
   asks for it. Browsers block audio until a gesture, so playback arms itself on
   the first pointerdown/keydown rather than failing silently on load. */
const Snd = {
  sfx: true, music: false, _el: null, _armed: false, _want: false,

  init(opts) {
    const o = opts || {};
    // migrate the old single mute flag: it only ever silenced the blip
    const legacy = localStorage.getItem('popcat.muted');
    const s = localStorage.getItem('popcat.sfx');
    this.sfx = s === null ? (legacy !== '1') : s !== '0';
    const m = localStorage.getItem('popcat.music');
    this.music = m === null ? !!o.musicDefault : m === '1';
    this._src = o.src || 'audio/bgm.mp3';
    this._vol = o.volume == null ? 0.45 : o.volume;
    const arm = () => { this._armed = true; if (this._want) this._play(); };
    addEventListener('pointerdown', arm, { passive: true });
    addEventListener('keydown', arm, { passive: true });
    addEventListener('touchstart', arm, { passive: true });
    if (this.music) this.setMusic(true, true);
    /* Pay for the audio device once the page is idle — not on the first beat of
       the countdown, and not during boot either: it is a ~1.4s synchronous
       task, so parking it at a fixed 700ms just moved the freeze onto the first
       paint. Idle time after the board has drawn is the only place it is free. */
    if (window.requestIdleCallback) requestIdleCallback(warmAudio, { timeout: 6000 });
    else setTimeout(warmAudio, 3000);
    return this;
  },

  setSfx(on) {
    this.sfx = !!on;
    localStorage.setItem('popcat.sfx', this.sfx ? '1' : '0');
    localStorage.setItem('popcat.muted', this.sfx ? '0' : '1');   // keep legacy in step
    if (this.sfx) this.blip();                                    // hear what you turned on
    return this.sfx;
  },

  setMusic(on, quiet) {
    this.music = !!on;
    localStorage.setItem('popcat.music', this.music ? '1' : '0');
    if (this.music) { this._want = true; if (this._armed) this._play(); }
    else { this._want = false; this._stop(); }
    if (!quiet && this.music && !this._armed) return 'gesture';   // caller may hint
    return this.music;
  },

  _play() {
    try {
      if (!this._el) {
        const el = new Audio();
        el.loop = true; el.preload = 'none'; el.volume = 0;
        el.src = this._src;                    // only now does the file download
        this._el = el;
      }
      const p = this._el.play();
      if (p && p.catch) p.catch(() => { this._armed = false; });
      this._fade(this._vol, 700);
    } catch { /* atmosphere is optional */ }
  },

  _stop() {
    if (!this._el) return;
    this._fade(0, 450, () => { try { this._el.pause(); } catch { } });
  },

  // a hard cut on a looping track sounds like a crash; ramp it instead
  _fade(to, ms, done) {
    const el = this._el; if (!el) return;
    clearInterval(this._fadeT);
    const from = el.volume, t0 = performance.now();
    this._fadeT = setInterval(() => {
      const k = Math.min(1, (performance.now() - t0) / ms);
      try { el.volume = from + (to - from) * k; } catch { }
      if (k >= 1) { clearInterval(this._fadeT); if (done) done(); }
    }, 40);
  },

  // duck under the countdown so the beats cut through the track
  duck(ms) {
    if (!this._el || this._el.paused) return;
    this._fade(this._vol * 0.28, 160);
    clearTimeout(this._duckT);
    this._duckT = setTimeout(() => this._fade(this._vol, 900), ms || 1200);
  },

  blip() { if (this.sfx) pop(false); },

  /* Someone walked into the room. This is deliberately the OPPOSITE shape to
     blip(): the tap blip falls 760->190Hz, this one RISES, so the two never
     get confused even though both are "a pop".
     Consecutive arrivals climb a scale — a rush of ten people filing in plays
     a rising run instead of the same note ten times, which is what makes a
     busy lobby sound like momentum rather than a stuck notification. The run
     resets after a short gap so a trickle stays at the root note. */
  _jseq: 0, _jseqT: 0,
  joinPop() {
    if (!this.sfx) return;
    try {
      const a = audioCtx(), t = a.currentTime;
      // The track was burying this on the projector. Gain alone can't win that
      // fight without clipping, so the music steps out of the way instead --
      // same trick the countdown beats use.
      this.duck(700);
      if (t - this._jseqT > 2.6) this._jseq = 0;
      this._jseqT = t;
      // major pentatonic: every step lands consonant, so any run sounds intended
      const semis = [0, 2, 4, 7, 9, 12, 14, 16, 19, 21, 24];
      const f = 300 * Math.pow(2, semis[Math.min(this._jseq++, semis.length - 1)] / 12);

      // body: the cork coming out — pitch snaps UP, then stops dead
      const o = a.createOscillator(), g = a.createGain();
      o.type = 'sine';
      o.frequency.setValueAtTime(f * 0.5, t);
      o.frequency.exponentialRampToValueAtTime(f * 2.05, t + 0.055);
      g.gain.setValueAtTime(0.0001, t);
      g.gain.exponentialRampToValueAtTime(0.62, t + 0.008);
      g.gain.exponentialRampToValueAtTime(0.0001, t + 0.18);
      o.connect(g).connect(a.destination);
      o.start(t); o.stop(t + 0.19);

      // a glassy overtone on top so it reads as a bubble, not a beep
      const o2 = a.createOscillator(), g2 = a.createGain();
      o2.type = 'triangle';
      o2.frequency.setValueAtTime(f * 3.02, t);
      g2.gain.setValueAtTime(0.0001, t);
      g2.gain.exponentialRampToValueAtTime(0.17, t + 0.01);
      g2.gain.exponentialRampToValueAtTime(0.0001, t + 0.12);
      o2.connect(g2).connect(a.destination);
      o2.start(t); o2.stop(t + 0.13);
    } catch { /* audio is a nice-to-have */ }
  },

  // countdown tick: pitch climbs as the number falls, so 1 feels like the edge
  beat(n) {
    if (!this.sfx) return;
    const step = Math.max(0, 5 - (parseInt(n, 10) || 5));
    try {
      const a = audioCtx(), t = a.currentTime;
      const o = a.createOscillator(), g = a.createGain();
      o.type = 'triangle';
      o.frequency.setValueAtTime(180 + step * 46, t);
      o.frequency.exponentialRampToValueAtTime(90 + step * 30, t + 0.22);
      g.gain.setValueAtTime(0.0001, t);
      g.gain.exponentialRampToValueAtTime(0.34, t + 0.012);
      g.gain.exponentialRampToValueAtTime(0.0001, t + 0.3);
      o.connect(g).connect(a.destination);
      o.start(t); o.stop(t + 0.32);
    } catch { }
  },

  // GO: a rising third, loud enough to be the starter pistol
  go() {
    if (!this.sfx) return;
    try {
      const a = audioCtx(), t = a.currentTime;
      [0, 0.09, 0.18].forEach((d, i) => {
        const o = a.createOscillator(), g = a.createGain();
        o.type = i === 2 ? 'sawtooth' : 'square';
        o.frequency.setValueAtTime([392, 523, 784][i], t + d);
        g.gain.setValueAtTime(0.0001, t + d);
        g.gain.exponentialRampToValueAtTime(i === 2 ? 0.3 : 0.2, t + d + 0.015);
        g.gain.exponentialRampToValueAtTime(0.0001, t + d + (i === 2 ? 0.7 : 0.25));
        o.connect(g).connect(a.destination);
        o.start(t + d); o.stop(t + d + 0.75);
      });
    } catch { }
  }
};

// ── page switcher ────────────────────────────────────────────────────────
// One definition of "where can I go from here", but each page mounts it
// itself: the phone deliberately keeps it off the tap screen, where a link
// beside a target being hit 45 times a second is an accidental exit.
const NAV = [
  { href: '/',            key: 'play',  label: 'Play',  icon: '🐱' },
  { href: '/lobby',       key: 'lobby', label: 'Lobby', icon: '🎃' },
  { href: '/leaderboard', key: 'board', label: 'Board', icon: '🏁' },
  { href: '/admin',       key: 'admin', label: 'Admin', icon: '🔑' }
];

function mountNav(target, current) {
  const host = typeof target === 'string' ? document.querySelector(target) : target;
  if (!host) return null;
  const nav = document.createElement('nav');
  nav.className = 'nav';
  nav.setAttribute('aria-label', 'Pages');
  for (const it of NAV) {
    const a = document.createElement('a');
    a.href = it.href;
    if (it.key === current) { a.className = 'on'; a.setAttribute('aria-current', 'page'); }
    const i = document.createElement('span');
    i.className = 'ni'; i.setAttribute('aria-hidden', 'true'); i.textContent = it.icon;
    const l = document.createElement('span');
    l.className = 'nl'; l.textContent = it.label;
    a.append(i, l);
    nav.append(a);
  }
  host.append(nav);
  return nav;
}

// ── decorative atmosphere: drifting bats, fog, candle flicker, grain ──
// Injected once per page so every screen shares it without duplicated markup.
(function atmosphere() {
  if (matchMedia('(prefers-reduced-motion: reduce)').matches) return;
  const D = 'M32 4c1.2 0 2.2 1 2.4 2.3 3.6-3.1 8.6-4.6 13.6-4.3-1.4 1.7-2 3.6-1.8 5.6 2.9-1.9 6.6-2.6 '
          + '10.2-2-2.6 1.4-4.4 3.6-5.2 6.3-.7 2.4-2.4 4.4-4.7 5.4-2.9 1.3-6.3.9-8.8-1-1.4 1.9-3.3 3-5.7 '
          + '3s-4.3-1.1-5.7-3c-2.5 1.9-5.9 2.3-8.8 1-2.3-1-4-3-4.7-5.4-.8-2.7-2.6-4.9-5.2-6.3 3.6-.6 7.3.1 '
          + '10.2 2 .2-2-.4-3.9-1.8-5.6 5-.3 10 1.2 13.6 4.3C29.8 5 30.8 4 32 4z';
  // top%, width px, delay s, duration s, opacity
  const BATS = [[13, 30, 0, 31, .18], [29, 19, 8, 39, .12], [58, 24, 16, 34, .10],
                [77, 15, 4, 47, .08], [43, 13, 23, 43, .07]];

  const wrap = document.createElement('div');
  wrap.className = 'atmo';
  wrap.setAttribute('aria-hidden', 'true');

  for (const [top, w, delay, dur, op] of BATS) {
    const s = document.createElementNS('http://www.w3.org/2000/svg', 'svg');
    s.setAttribute('viewBox', '0 0 64 28');
    s.setAttribute('width', w); s.setAttribute('height', Math.round(w * 28 / 64));
    s.setAttribute('class', 'bat');
    s.style.cssText = `top:${top}%;opacity:${op};animation:drift ${dur}s linear ${delay}s infinite`;
    const p = document.createElementNS('http://www.w3.org/2000/svg', 'path');
    p.setAttribute('fill', 'currentColor'); p.setAttribute('d', D);
    s.append(p); wrap.append(s);
  }

  const fog = document.createElement('div');
  fog.className = 'fog';
  fog.style.cssText = 'bottom:-8vh;animation:fogroll 28s ease-in-out infinite alternate';
  wrap.append(fog);

  document.body.prepend(wrap);
  for (const c of ['vig', 'grain']) {
    const d = document.createElement('div');
    d.className = c; d.setAttribute('aria-hidden', 'true');
    document.body.append(d);
  }
})();
