-- ═══════════════════════════════════════════════════════════════════════════
--  Kaizen Pop-Cat — LOCK + COUNTDOWN  (delta, 2026-09-18)
--
--  Paste this WHOLE file into the Supabase SQL editor and press RUN. Once.
--
--  Safe on a live board: it adds two columns and replaces four functions.
--  No player row is read or written, no score changes, nobody is kicked out.
--  Re-running it is harmless.
--
--  schema.sql holds the full picture and has been updated to match.
-- ═══════════════════════════════════════════════════════════════════════════

-- 1 ── state ────────────────────────────────────────────────────────────────
-- locked          : the admin freeze. Taps stop counting even in open play.
-- round_starts_at : lead-in. Scoring and the clock both begin HERE, so every
--                   screen can run the same countdown and the round still gets
--                   its full duration afterwards.
alter table public.app_config add column if not exists locked boolean not null default false;
alter table public.app_config add column if not exists round_starts_at timestamptz;


-- 2 ── the scoring gate ─────────────────────────────────────────────────────
-- Only this function decides whether a tap counts. Everything else is display.
create or replace function public.add_score(p_player_id uuid, p_delta int)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare cfg public.app_config; s bigint; live boolean; rnk int; arnd jsonb; tot int;
begin
  select * into cfg from public.app_config where id = 1;

  -- A lock always wins. With no round set it is open play (everyone may click).
  -- With a round, clicks count only from the end of the countdown to the buzzer.
  live := not cfg.locked
          and (cfg.round_ends_at is null
               or (now() >= coalesce(cfg.round_starts_at, '-infinity'::timestamptz)
                   and now() < cfg.round_ends_at));

  if live and coalesce(p_delta, 0) > 0 then
    -- clamp: 80 per ~1000ms flush = an 80 clicks/sec ceiling, well past human speed
    update public.players
       set score = score + least(p_delta, 80), updated_at = now()
     where id = p_player_id
    returning score into s;
  else
    select score into s from public.players where id = p_player_id;
  end if;

  with ranked as (
    select row_number() over (order by score desc, updated_at asc) as rank,
           id, username, department, score
    from public.players
  ), mine as (
    select rank from ranked where id = p_player_id
  )
  select (select rank from mine),
         coalesce((select jsonb_agg(to_jsonb(r) order by r.rank) from ranked r
                   where r.rank between (select rank from mine) - 1
                                    and (select rank from mine) + 1), '[]'::jsonb),
         (select count(*) from ranked)
    into rnk, arnd, tot;

  return jsonb_build_object('score', coalesce(s, 0), 'live', live,
                            'locked', cfg.locked,
                            'starts_at', cfg.round_starts_at,
                            'ends_at', cfg.round_ends_at, 'server_now', now(),
                            'rank', rnk, 'around', arnd, 'total_players', tot);
end $$;


-- 3 ── one read for everything the screens need ─────────────────────────────
create or replace function public.get_board(p_limit int default 30, p_player uuid default null)
returns jsonb language sql stable security definer set search_path = public, pg_temp as $$
  with ranked as (
    select row_number() over (order by score desc, updated_at asc) as rank,
           id, username, department, score
    from public.players
  ), mine as (
    select rank from ranked where p_player is not null and id = p_player
  )
  select jsonb_build_object(
    'server_now', now(),
    'ends_at',       (select round_ends_at   from public.app_config where id = 1),
    'starts_at',     (select round_starts_at from public.app_config where id = 1),
    'locked',        (select locked          from public.app_config where id = 1),
    'round_seconds', (select round_seconds   from public.app_config where id = 1),
    'total_players', (select count(*) from public.players),
    'total_clicks',  (select coalesce(sum(score), 0) from public.players),
    'top',   coalesce((select jsonb_agg(to_jsonb(r) order by r.rank)
                       from ranked r where r.rank <= greatest(p_limit, 1)), '[]'::jsonb),
    'me',    (select to_jsonb(r) from ranked r where r.id = p_player),
    'around',coalesce((select jsonb_agg(to_jsonb(r) order by r.rank) from ranked r
                       where r.rank between (select rank from mine) - 1
                                        and (select rank from mine) + 1), '[]'::jsonb),
    'depts', coalesce((select jsonb_agg(to_jsonb(d) order by d.total desc, d.department)
                       from (select department, sum(score) as total, count(*) as members
                             from public.players group by department) d), '[]'::jsonb)
  );
$$;


-- 4 ── start: unlock, count down, then run for the full duration ────────────
-- ponytail: the 5s lead-in is hardcoded. Make it an argument only if someone
-- actually asks for a different countdown length.
create or replace function public.admin_start_round(p_pin text, p_seconds int)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare secs int; t0 timestamptz;
begin
  perform public.assert_admin(p_pin);
  secs := least(greatest(coalesce(p_seconds, 60), 5), 3600);
  t0   := now() + interval '5 seconds';
  -- Starting a race unlocks the board on its own, so the host never has to
  -- remember two buttons in the right order in front of a room of people.
  -- Scores are deliberately NOT wiped here: that is its own button, and a host
  -- nudging the clock mid-event must never be able to delete the event.
  update public.app_config
     set locked          = false,
         round_seconds   = secs,
         round_starts_at = t0,
         round_ends_at   = t0 + make_interval(secs => secs)
   where id = 1;
  return jsonb_build_object('ok', true, 'seconds', secs, 'starts_at', t0, 'locked', false);
end $$;


-- 5 ── stop: back to whatever the lock says ─────────────────────────────────
create or replace function public.admin_stop_round(p_pin text)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare l boolean;
begin
  perform public.assert_admin(p_pin);
  update public.app_config set round_ends_at = null, round_starts_at = null where id = 1
    returning locked into l;
  return jsonb_build_object('ok', true, 'locked', l);
end $$;


-- 6 ── the lock itself ──────────────────────────────────────────────────────
create or replace function public.admin_set_lock(p_pin text, p_locked boolean)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
begin
  perform public.assert_admin(p_pin);
  update public.app_config set locked = coalesce(p_locked, false) where id = 1;
  return jsonb_build_object('ok', true, 'locked', coalesce(p_locked, false));
end $$;
grant execute on function public.admin_set_lock(text, boolean) to anon, authenticated;


-- 7 ── admin needs to SEE the state it is controlling ───────────────────────
create or replace function public.admin_list(p_pin text)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare cfg public.app_config;
begin
  perform public.assert_admin(p_pin);
  select * into cfg from public.app_config where id = 1;
  return jsonb_build_object(
    'server_now', now(),
    'ends_at', cfg.round_ends_at, 'starts_at', cfg.round_starts_at,
    'locked', cfg.locked, 'round_seconds', cfg.round_seconds,
    'players', coalesce((select jsonb_agg(to_jsonb(p) order by p.score desc, p.username)
                         from (select id, employee_id, username, department, score
                               from public.players) p), '[]'::jsonb));
end $$;
