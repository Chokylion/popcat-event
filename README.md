# KAIZEN POP-CAT

Halloween clicking game for the Analog Devices event. **Live: https://popcat-event.vercel.app**

Static HTML + Supabase. No build step, no npm, no framework — edit a file, redeploy, done.

| page | who | notes |
|---|---|---|
| `/` | players (phone) | type **name + employee ID + department**, then tap the pumpkin cat. Fits one screen, never scrolls. Returning on another phone? **"Log in with just your ID"** resumes your score. |
| `/leaderboard` | the big monitor | top players + department totals, live rank movement. Also readable on a phone. |
| `/podium` | the big monitor | top 3 on lit plinths + a "chase" list. Same data, more dramatic. Also fits a phone. |
| `/admin` | optional | set a timed round, reset all scores, remove a player. Not needed for open play. |

Players register themselves — there is no "add player" button by design.

## Running it

It's already live and **open** — no host, no setup. Anyone opens
`https://popcat-event.vercel.app`, types name + employee ID + department, and starts tapping.
Scores count immediately and the leaderboard shows `OPEN`.

Put `/leaderboard` or `/podium` on the monitor and press **F11** for fullscreen. That's the whole
thing. On a slow network the first load can take a few seconds before players appear — open it
early, it then refreshes every 1.2s on its own.

### If you want a timed round instead

Open `/admin`, enter the admin PIN, set a duration and hit **START / RESET TIME**. Now the
clock runs and clicks stop counting when it hits zero, with a `FINAL RESULT` banner on the board.
**STOP** puts it back to open play. **Reset all scores** clears everything.

To change the PIN:

```sql
update app_config set admin_pin = '<a long random value>';
```

The PIN is the only thing protecting the controls — there is no admin account, anyone who opens
`/admin` and knows the PIN gets in. Change it if colleagues have seen it.

## Changing things

`config.js` is the only file you should need: `SUPABASE_URL`, `SUPABASE_ANON_KEY`, `EVENT_NAME`,
and the `DEPARTMENTS` list. Department is a required dropdown, so a player can only pick a
name that is on the list — edit `DEPARTMENTS` and redeploy to change the options. Departments
already stored on existing players are left alone; the leaderboard shows whatever the database
holds, even if that name has since been removed from the list.

## How it holds 100 players

Clicks are counted locally (instant, zero latency), then flushed once every 750 ms as a single
atomic `score = score + n` in Postgres — roughly 130 small writes/sec at full load instead of
~1000. The server owns both the clock and the score: an **expired** round rejects deltas, and every
call is clamped to 60 clicks so an autoclicker can't run away with it. Tables have RLS on with
**zero policies** and grants revoked, so the anon key can't touch them at all — everything goes
through the `security definer` functions in `schema.sql`. Names are rendered with `textContent`
because they go on a projector.

Verified: 52 browser checks against a 100-player mock, 34 database checks on real Postgres, and
checks against the live site and live database — including that the anon key can *not* read
the players table, write a score, or read the admin PIN.

## Files

`index.html` join + play · `leaderboard.html` big screen · `podium.html` top-3 big screen ·
`admin.html` controls · `sb.js` RPC client + pop sound + atmosphere · `config.js` your settings ·
`style.css` · `schema.sql` the whole backend · `img/` the pumpkin cat frames
