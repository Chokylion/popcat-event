-- PopCat event — full backend. Paste into the Supabase SQL editor and run ONCE.
-- Clients never touch tables directly: RLS denies everything, all access is via
-- the security-definer functions below.

-- ── tables ──────────────────────────────────────────────────────────────────
create table if not exists public.players (
  id           uuid primary key default gen_random_uuid(),
  employee_id  text not null unique,
  username     text not null,
  department   text not null,
  score        bigint not null default 0,
  -- rate-limit bucket for add_score; see the comment there
  score_win_start timestamptz,
  score_in_win    int not null default 0,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);
alter table public.players add column if not exists score_win_start timestamptz;
alter table public.players add column if not exists score_in_win int not null default 0;
create index if not exists players_score_idx on public.players (score desc, updated_at asc);

create table if not exists public.app_config (
  id             int  primary key default 1,
  -- Admin PIN. This is the ONLY thing guarding /admin, and every admin_* function
  -- is callable by the public anon key, so its length IS the security of this app.
  -- A fresh install gets a random 32-char value (NOT a memorable default, which is
  -- how this ended up as '67' in production); read it out and change it to
  -- something you can type:
  --   select admin_pin from app_config where id = 1;
  --   update app_config set admin_pin = '<16+ characters>' where id = 1;
  admin_pin      text not null default replace(gen_random_uuid()::text, '-', ''),
  round_seconds  int  not null default 60,
  round_ends_at  timestamptz,           -- null = round not running
  round_starts_at timestamptz,          -- lead-in; clicks only count from here (countdown)
  locked         boolean not null default false,  -- admin freeze; beats everything
  constraint app_config_singleton check (id = 1),
  -- a short pin is brute-forceable in seconds against an unauthenticated rpc
  constraint app_config_pin_strength check (length(admin_pin) >= 12)
);
insert into public.app_config (id) values (1) on conflict do nothing;
-- ponytail: no admin employee number. /admin is PIN-only, nobody is admin by ID.
alter table public.app_config drop column if exists admin_employee;
-- countdown lead-in + lock for older projects created before these features
alter table public.app_config add column if not exists round_starts_at timestamptz;
alter table public.app_config add column if not exists locked boolean not null default false;
-- NOTE: the line that used to sit here reset the pin to a 2-digit default.
-- It is gone on purpose. Rotating the pin is security-patch.sql's job, and
-- nothing in this file may ever quietly weaken a pin that is already set.

alter table public.players    enable row level security;
alter table public.app_config enable row level security;
revoke all on public.players    from anon, authenticated;
revoke all on public.app_config from anon, authenticated;

-- ── internal ────────────────────────────────────────────────────────────────
create or replace function public.assert_admin(p_pin text) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if coalesce(p_pin, '') = ''
     or not exists (select 1 from public.app_config where id = 1 and admin_pin = p_pin) then
    -- A failed-attempt COUNTER cannot work here: this function raises, and the
    -- raise rolls back the very UPDATE that recorded the attempt, so the count
    -- would always read zero. pg_sleep is not rolled back -- wall-clock time
    -- passes whether the transaction commits or not. One second per wrong guess
    -- is free for a real admin and ruinous for a sweep.
    perform pg_sleep(1.0);
    raise exception 'bad admin pin' using errcode = '42501';
  end if;
end $$;
revoke all on function public.assert_admin(text) from public, anon, authenticated;

-- ── join / resume ───────────────────────────────────────────────────────────
create or replace function public.join_game(p_employee_id text, p_username text, p_department text)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare rec public.players; cfg public.app_config; eid text;
begin
  eid := trim(coalesce(p_employee_id, ''));

  if eid = ''
     or coalesce(trim(p_username), '') = ''
     or coalesce(trim(p_department), '') = '' then
    raise exception 'name, employee id and department are all required';
  end if;

  -- enforced HERE, not just in the browser: the html pattern attribute is
  -- bypassed completely by anyone calling this rpc directly
  --
  -- The ZBOT exception is deliberate, and it grants an attacker nothing. The
  -- load-test harnesses (botjoin/botswarm/hotbots) MUST use ids that cannot
  -- collide with a real employee: now that a conflict keeps the existing row,
  -- a bot joining as "<an existing employee id>" would add its score to that real person instead
  -- of renaming them. Reserving an obviously-fake prefix is safer than forcing
  -- bots onto 7-digit ids. A ZBOT row can only ever score for itself, which is
  -- true of every row anyway.
  if eid !~ '^[0-9]{7}$' and eid !~ '^ZBOT' then
    raise exception 'employee id must be exactly 7 digits';
  end if;

  -- do NOT overwrite username/department on conflict. Doing so meant typing a
  -- colleague's employee id renamed them on the projector in front of the room.
  -- Cost of this choice: a player who typos their own name needs an admin to fix
  -- it. That is the smaller problem.
  insert into public.players (employee_id, username, department)
  values (eid, left(trim(p_username), 24), left(trim(p_department), 40))
  on conflict (employee_id) do update
     set updated_at = now()
  returning * into rec;

  select * into cfg from public.app_config where id = 1;
  return jsonb_build_object(
    'id', rec.id, 'username', rec.username, 'department', rec.department,
    'employee_id', rec.employee_id, 'score', rec.score,
    'ends_at', cfg.round_ends_at, 'starts_at', cfg.round_starts_at, 'server_now', now());
end $$;

-- ── login: resume an existing player with just their employee id ────────────
create or replace function public.login_game(p_employee_id text)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare rec public.players; cfg public.app_config;
begin
  select * into rec from public.players where employee_id = left(trim(p_employee_id), 24);
  if not found then
    raise exception 'that employee id has not joined yet — fill in your name and department to register';
  end if;
  select * into cfg from public.app_config where id = 1;
  return jsonb_build_object(
    'id', rec.id, 'username', rec.username, 'department', rec.department,
    'employee_id', rec.employee_id, 'score', rec.score,
    'ends_at', cfg.round_ends_at, 'starts_at', cfg.round_starts_at, 'server_now', now());
end $$;

-- ── scoring: atomic, clamped, round-gated ───────────────────────────────────
-- Returns the player's rank + neighbours too, so a phone needs ONE request per
-- tick instead of add_score + get_board. Halves the request rate under load.
create or replace function public.add_score(p_player_id uuid, p_delta int)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare cfg public.app_config; s bigint; live boolean; rnk int; arnd jsonb; tot int;
        win_start timestamptz; win_cnt int; grant_n int;
begin
  select * into cfg from public.app_config where id = 1;
  -- A lock always wins. With no round set it is open play (everyone may click).
  -- With a round, clicks count only from the end of the countdown to the buzzer.
  live := not cfg.locked
          and (cfg.round_ends_at is null
               or (now() >= coalesce(cfg.round_starts_at, '-infinity'::timestamptz)
                   and now() < cfg.round_ends_at));

  if live and coalesce(p_delta, 0) > 0 then
    -- RATE LIMIT. The old per-call clamp of 80 was not a limit at all: nothing
    -- stopped a loop in the browser console from calling this 100 times a second
    -- and awarding 8000 points a second, to ANY player id -- and every id is
    -- published by get_board. A per-call cap only limits the size of one call.
    --
    -- This is a token bucket keyed on the player: at most 800 points per rolling
    -- 10 second window = 80/sec sustained, no matter how the calls are spread.
    -- A fast human taps 10-15/sec, so 80 leaves 5x headroom and the honest path
    -- never touches the ceiling, while "set me to 999999" becomes impossible.
    -- FOR UPDATE serialises concurrent calls for this one player (and only this
    -- one, so there is no global contention).
    select score_win_start, score_in_win into win_start, win_cnt
      from public.players where id = p_player_id for update;

    if win_start is null or now() - win_start > interval '10 seconds' then
      win_start := now(); win_cnt := 0;
    end if;

    grant_n := least(p_delta, 80, greatest(0, 800 - win_cnt));

    update public.players
       set score           = score + grant_n,
           score_win_start = win_start,
           score_in_win    = win_cnt + grant_n,
           updated_at      = case when grant_n > 0 then now() else updated_at end
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

-- keeps the ranked window fast as the player table grows
create index if not exists players_score_idx on public.players (score desc, updated_at asc);

-- ── one read for everything the UI needs ────────────────────────────────────
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
    'ends_at',       (select round_ends_at from public.app_config where id = 1),
    'starts_at',     (select round_starts_at from public.app_config where id = 1),
    'locked',        (select locked from public.app_config where id = 1),
    'round_seconds', (select round_seconds from public.app_config where id = 1),
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

-- ── admin ───────────────────────────────────────────────────────────────────
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

create or replace function public.admin_start_round(p_pin text, p_seconds int)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare secs int; t0 timestamptz;
begin
  perform public.assert_admin(p_pin);
  secs := least(greatest(coalesce(p_seconds, 60), 5), 3600);
  -- ponytail: the 5s lead-in is hardcoded. Make it an argument only if someone
  -- actually asks for a different countdown length.
  t0 := now() + interval '5 seconds';
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

create or replace function public.admin_stop_round(p_pin text)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare l boolean;
begin
  perform public.assert_admin(p_pin);
  update public.app_config set round_ends_at = null, round_starts_at = null where id = 1
    returning locked into l;
  return jsonb_build_object('ok', true, 'locked', l);
end $$;

-- the admin freeze: taps stop counting even in open play
create or replace function public.admin_set_lock(p_pin text, p_locked boolean)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
begin
  perform public.assert_admin(p_pin);
  update public.app_config set locked = coalesce(p_locked, false) where id = 1;
  return jsonb_build_object('ok', true, 'locked', coalesce(p_locked, false));
end $$;

create or replace function public.admin_reset_scores(p_pin text)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare n int;
begin
  perform public.assert_admin(p_pin);
  -- ponytail: score <> 0 is a real filter AND satisfies the safe-update guard
  -- (a bare UPDATE errors with "UPDATE requires a WHERE clause" on Supabase)
  update public.players set score = 0, updated_at = now() where score <> 0;
  get diagnostics n = row_count;
  return jsonb_build_object('ok', true, 'reset', n);
end $$;

create or replace function public.admin_remove_player(p_pin text, p_player_id uuid)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare n int;
begin
  perform public.assert_admin(p_pin);
  delete from public.players where id = p_player_id;
  get diagnostics n = row_count;
  return jsonb_build_object('ok', n > 0);
end $$;

-- danger: delete EVERY player (full wipe) and clear any running round
create or replace function public.admin_wipe_players(p_pin text)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare n int;
begin
  perform public.assert_admin(p_pin);
  delete from public.players where true;          -- WHERE satisfies safe-update guard
  get diagnostics n = row_count;
  update public.app_config set round_ends_at = null, round_starts_at = null where id = 1;
  return jsonb_build_object('ok', true, 'deleted', n);
end $$;

create or replace function public.admin_set_score(p_pin text, p_player_id uuid, p_score int)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare n int;
begin
  perform public.assert_admin(p_pin);
  update public.players set score = greatest(0, p_score), updated_at = now() where id = p_player_id;
  get diagnostics n = row_count;
  return jsonb_build_object('ok', n > 0, 'score', greatest(0, p_score));
end $$;

-- ── grants (assert_admin stays private) ─────────────────────────────────────
grant execute on function public.join_game(text, text, text)                to anon, authenticated;
grant execute on function public.login_game(text)                           to anon, authenticated;
grant execute on function public.add_score(uuid, int)                       to anon, authenticated;
grant execute on function public.get_board(int, uuid)                       to anon, authenticated;
grant execute on function public.admin_list(text)                           to anon, authenticated;
grant execute on function public.admin_start_round(text, int)               to anon, authenticated;
grant execute on function public.admin_stop_round(text)                     to anon, authenticated;
grant execute on function public.admin_reset_scores(text)                   to anon, authenticated;
grant execute on function public.admin_remove_player(text, uuid)            to anon, authenticated;
grant execute on function public.admin_set_lock(text, boolean)              to anon, authenticated;
grant execute on function public.admin_wipe_players(text)                   to anon, authenticated;
grant execute on function public.admin_set_score(text, uuid, int)           to anon, authenticated;
