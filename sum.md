# PopCat Event — Project Summary (for redesigning the Leaderboard page)

A Halloween-themed **PopCat clicker race** for a room of Analog Devices (ADI)
employees. Players tap a cat on their phone; scores race live. The
**leaderboard runs on a big projector/main screen** in the room — that page is
the one you're redesigning. Make it feel **competitive, cinematic, and alive**.

- **Live URL:** https://popcat-event.vercel.app
- **Leaderboard:** https://popcat-event.vercel.app/leaderboard.html
- **Stack:** static HTML/CSS/vanilla JS (no framework, no build step) +
  **Supabase** (Postgres + PostgREST RPC) + **Vercel** hosting.
- **Deploy:** `cd popcat-event; npx vercel deploy --prod --yes`

## Files
| File | Role |
|------|------|
| `index.html` | Player page (mobile). Join form + the tappable cat. |
| `leaderboard.html` | **The main-screen board — redesign target.** Self-contained: inline `<style>` + inline `<script>`. |
| `admin.html` | Admin panel (PIN-gated): start/stop round, reset scores, delete players. |
| `style.css` | Shared styles (tokens, buttons, row flash keyframes). |
| `sb.js` | Shared helpers: `rpc(name,args)`, `serverNow()`, `msLeft(iso)`, `clock()`, `num()`, `pop()` (audio blip), atmosphere (bats/fog/grain). |
| `config.js` | `CFG`: Supabase URL + anon key, `EVENT_NAME`, `DEPARTMENTS[]` (fixed 25-dept list). |
| `schema.sql` | Backend source of truth (tables + RPC). Idempotent; re-run in Supabase SQL editor to apply changes. |

## Data — everything comes from ONE call: `rpc('get_board', { p_limit: 40 })`
Returns JSON:
```jsonc
{
  "server_now":   "ISO",
  "starts_at":    "ISO | null",   // race lead-in; countdown target (now+3s)
  "ends_at":      "ISO | null",   // race end; null = open/idle play
  "round_seconds": 60,
  "total_players": 123,
  "total_clicks":  45678,
  "top":  [ { "rank":1, "id":"uuid", "username":"Alice", "department":"IT", "score":812 }, ... ], // sorted by score
  "depts":[ { "department":"IT", "total":5400, "members":12 }, ... ]  // sorted by total desc
}
```
Poll `get_board` every ~1s. **clicks/sec (cps) is NOT from the server** — the
board computes it client-side as an EMA of each player's `score` delta between
polls. `peak` cps and per-team cps are also derived client-side from `top[]`.

Player writes score via `rpc('add_score',{p_player,p_delta})`; that's the
player page's job, not the board's.

## Current leaderboard features (keep/upgrade these)
- **Bar-chart race:** each racer is a lane; bar width = score/max. Bars animate
  from previous fill (never snap to 0); rows FLIP-reorder as ranks change.
- **Two figures per racer:** live clicks/s (fire) + peak clicks/s (gold).
- **5 fire tiers** at cps ≥ **3 / 6 / 9 / 12 / 15** (warm → orange → fire
  gradient → fire+pulse → fire+lightning). "fire red streak" on the live one.
- **Fastest-now panel:** name + live/s of the single fastest clicker right now.
- **Team strip (bottom):** per department chip = combined team live/s +
  👑 top scorer (name + score) + total pops. Top 6 depts.
- Header: event name, ADI logo, race timer/countdown, players/total-pops/pops-per-sec stats.
- **3-2-1 countdown overlay** when admin starts a round.

## Design constraints (important)
- **Main projector screen** — big, readable from across a room; landscape.
  Everything must fit **one viewport, no scroll** (`100vw/100vh`, no clipping).
- **Theme:** Halloween × ADI. Dark, premium, fiery/competitive energy.
  Tokens in `style.css` (pumpkin/ember/blood/toxic/witch colors, glass, hairlines).
- **Bilingual:** usernames/departments may be Thai — use UTF-8, Thai-capable
  font, and size containers so Thai/long names don't overflow (ellipsis).
- **Performance:** animate only `transform`/`opacity` (bar width is isolated to
  an absolutely-positioned `.barfill`). `backdrop-blur` only on fixed elements.
- **Competitive feel is the point:** movement, racing bars, rank changes,
  fire that intensifies with speed. Make climbing/falling feel dramatic.

## Departments (fixed dropdown, players pick one)
PSG (JULITA), DCE (SANYA), PES (WANEE), QOET (NATTASAK), SERDES (Thana),
BMS (Kanokwan), IC-DESIGN, TPE, PROD, PE, ME, SAF, PCB, QA, IE, GR, PLANNING,
NPI, SCM, PMO, CSR, SHIPPING, GTC, ACCOUNT, PROCUREMENT, FINANCE, SEC, EHS,
FAC, IT, FA LAB, Rel Lab, FRITZ, Secretary, HR.

## Gotchas
- Only the **anon key** is in `config.js` (safe to expose). Schema/DDL changes
  require re-running `schema.sql` in the Supabase SQL editor — the app can't run DDL.
- `leaderboard.html` is fully self-contained (inline style+script) — a new
  design can replace it wholesale as long as it keeps polling `get_board` and
  reads the JSON shape above.
