// Keeps the Supabase project awake.
//
// A free-tier Supabase project pauses itself after ~7 days with no API activity.
// Between now and the event that could easily happen on a quiet week, and a paused
// project takes the whole game down - every click would fail.
//
// Vercel Cron calls this once a day. It makes one real database read (that is what
// counts as activity - a static page view does not), then stops on its own once the
// event date in config.js has passed, so nothing is left running forever.
//
// Reads the Supabase URL/key straight from the deployed config.js so there is only
// ever one copy of them. That key is the public anon key - every table is RLS-denied
// and all access goes through RPCs, so it is safe to use here.

module.exports = async (req, res) => {
  const origin = `https://${req.headers.host}`;
  const out = { at: new Date().toISOString() };

  let cfg;
  try {
    const r = await fetch(`${origin}/config.js`);
    if (!r.ok) throw new Error('config.js HTTP ' + r.status);
    cfg = await r.text();
  } catch (e) {
    return res.status(500).json({ ...out, ok: false, step: 'config', error: String(e) });
  }

  const url = (cfg.match(/https:\/\/[a-z0-9]+\.supabase\.co/) || [])[0];
  const key = (cfg.match(/eyJ[\w.-]+/) || [])[0];
  const end = (cfg.match(/EVENT_END:\s*'([^']+)'/) || [])[1] || null;
  out.eventEnd = end;

  if (!url || !key) {
    return res.status(500).json({ ...out, ok: false, step: 'parse', error: 'could not read config.js' });
  }

  // one day of grace so the final leaderboard is still viewable, then let it sleep
  if (end && Date.now() > Date.parse(end) + 86400000) {
    return res.status(200).json({ ...out, ok: true, skipped: true, reason: 'event finished - letting the project sleep' });
  }

  const t0 = Date.now();
  try {
    const r = await fetch(`${url}/rest/v1/rpc/get_board`, {
      method: 'POST',
      headers: { apikey: key, Authorization: `Bearer ${key}`, 'Content-Type': 'application/json' },
      body: JSON.stringify({ p_limit: 1 })
    });
    const body = await r.json().catch(() => null);
    out.ms = Date.now() - t0;
    out.status = r.status;
    if (!r.ok) return res.status(502).json({ ...out, ok: false, step: 'supabase', body });
    out.players = body && body.total_players != null ? body.total_players : null;
    out.clicks = body && body.total_clicks != null ? body.total_clicks : null;
    const left = end ? (Date.parse(end) - Date.now()) / 86400000 : null;
    out.daysLeft = left == null ? null : Math.round(left * 100) / 100;
    return res.status(200).json({ ...out, ok: true });
  } catch (e) {
    return res.status(502).json({ ...out, ok: false, step: 'supabase', error: String(e) });
  }
};
