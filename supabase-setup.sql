-- SET Duell – Supabase Setup (idempotent: kann beliebig oft ausgeführt werden)
-- Supabase Dashboard: SQL Editor -> New query -> einfügen -> Run

create table if not exists public.lobbies (
  code       text primary key,
  status     text not null default 'waiting',   -- waiting | playing | finished
  target     int  not null default 5,
  players    jsonb not null default '[]'::jsonb,
  deck       jsonb not null default '[]'::jsonb,
  board      jsonb not null default '[]'::jsonb,
  last       jsonb,
  winner     text,
  version    int  not null default 0,
  created_at timestamptz not null default now()
);

alter table public.lobbies enable row level security;

drop policy if exists "lobbies select" on public.lobbies;
drop policy if exists "lobbies insert" on public.lobbies;
drop policy if exists "lobbies update" on public.lobbies;
drop policy if exists "lobbies delete stale" on public.lobbies;

create policy "lobbies select" on public.lobbies for select to anon using (true);
create policy "lobbies insert" on public.lobbies for insert to anon with check (true);
create policy "lobbies update" on public.lobbies for update to anon using (true) with check (true);

-- Alte / leere Lobbys dürfen von jedem Client aufgeräumt werden
create policy "lobbies delete stale" on public.lobbies for delete to anon using (
  jsonb_array_length(players) = 0
  or (status = 'waiting' and created_at < now() - interval '6 hours')
  or created_at < now() - interval '24 hours'
);

-- Realtime aktivieren (Fehler "already member" wird ignoriert)
do $$ begin
  alter publication supabase_realtime add table public.lobbies;
exception when duplicate_object then null;
end $$;

-- ---------------------------------------------------------------------------
-- Anti-Cheat: Der Server prüft jede Zustandsänderung während eines Spiels.
-- Punkte können nur durch einen gültigen Zug (echtes SET von 3 Karten vom Tisch,
-- korrektes "Kein Set", gültiges Nachlegen) verändert werden.
-- ---------------------------------------------------------------------------

create or replace function public.set_is_set(a int, b int, c int) returns boolean
language sql immutable as $$
  select (a % 3 + b % 3 + c % 3) % 3 = 0
     and ((a / 3) % 3 + (b / 3) % 3 + (c / 3) % 3) % 3 = 0
     and ((a / 9) % 3 + (b / 9) % 3 + (c / 9) % 3) % 3 = 0
     and ((a / 27) % 3 + (b / 27) % 3 + (c / 27) % 3) % 3 = 0
$$;

create or replace function public.set_ints(j jsonb) returns int[]
language sql immutable as $$
  select coalesce(array_agg(v::int order by ord), '{}'::int[])
  from jsonb_array_elements_text(coalesce(j, '[]'::jsonb)) with ordinality as t(v, ord)
$$;

create or replace function public.set_board_has_set(board jsonb) returns boolean
language sql immutable as $$
  with c as (
    select v::int as id, ord
    from jsonb_array_elements_text(board) with ordinality as t(v, ord)
  )
  select exists (
    select 1 from c x join c y on y.ord > x.ord join c z on z.ord > y.ord
    where public.set_is_set(x.id, y.id, z.id)
  )
$$;

create or replace function public.lobbies_guard() returns trigger
language plpgsql as $$
declare
  n int; i int;
  p jsonb; o jsonb;
  ds int; dsets int; dmiss int; dnos int; dtn int; dts bigint;
  mv_ds int := 0; mv_dsets int := 0; mv_dmiss int := 0; mv_dnos int := 0; mv_dtn int := 0; mv_dts bigint := 0;
  movers int := 0;
  ob int[]; nb int[]; od int[]; nd int[];
  removed int[]; added int[]; k int;
  teams boolean; mx int; leaders int; lead text;
begin
  if TG_OP <> 'UPDATE' then return NEW; end if;
  if NEW.version <> OLD.version + 1 then
    raise exception 'invalid version';
  end if;

  -- Spielstart (auch Revanche): frischer Zustand
  if OLD.status <> 'playing' and NEW.status = 'playing' then
    if exists (
      select 1 from jsonb_array_elements(NEW.players) q
      where coalesce((q->>'score')::int, 0) <> 0 or coalesce((q->>'sets')::int, 0) <> 0
         or coalesce((q->>'misses')::int, 0) <> 0 or coalesce((q->>'tn')::int, 0) <> 0
         or coalesce((q->>'tsum')::bigint, 0) <> 0 or coalesce((q->>'nos')::int, 0) <> 0
    ) then
      raise exception 'invalid start: scores must be zero';
    end if;
    if jsonb_array_length(NEW.board) + jsonb_array_length(NEW.deck) <> 81
       or (select count(distinct v) from (
             select jsonb_array_elements_text(NEW.board) as v
             union all select jsonb_array_elements_text(NEW.deck)) u) <> 81 then
      raise exception 'invalid start: deck';
    end if;
    return NEW;
  end if;

  -- Nach Spielende: Ergebnis einfrieren
  if OLD.status = 'finished' and NEW.status = 'finished' then
    n := jsonb_array_length(OLD.players);
    if jsonb_array_length(NEW.players) <> n or NEW.winner is distinct from OLD.winner then
      raise exception 'result is locked';
    end if;
    for i in 0 .. n - 1 loop
      p := NEW.players -> i; o := OLD.players -> i;
      if (p->>'id') <> (o->>'id')
         or coalesce((p->>'score')::int, 0) <> coalesce((o->>'score')::int, 0)
         or coalesce((p->>'sets')::int, 0) <> coalesce((o->>'sets')::int, 0)
         or coalesce((p->>'misses')::int, 0) <> coalesce((o->>'misses')::int, 0)
         or coalesce((p->>'tn')::int, 0) <> coalesce((o->>'tn')::int, 0)
         or coalesce((p->>'tsum')::bigint, 0) <> coalesce((o->>'tsum')::bigint, 0) then
        raise exception 'result is locked';
      end if;
    end loop;
    return NEW;
  end if;

  -- Laufendes Spiel
  if OLD.status = 'playing' and NEW.status in ('playing', 'finished') then
    if NEW.target <> OLD.target then raise exception 'target is locked during a game'; end if;
    n := jsonb_array_length(OLD.players);
    if jsonb_array_length(NEW.players) <> n then raise exception 'players are locked during a game'; end if;
    if (NEW.players -> 0 -> 'cfg') is distinct from (OLD.players -> 0 -> 'cfg') then
      raise exception 'settings are locked during a game';
    end if;

    for i in 0 .. n - 1 loop
      p := NEW.players -> i; o := OLD.players -> i;
      if (p->>'id') <> (o->>'id') or (p->>'name') is distinct from (o->>'name')
         or (p->>'team') is distinct from (o->>'team') then
        raise exception 'players are locked during a game';
      end if;
      ds    := coalesce((p->>'score')::int, 0)  - coalesce((o->>'score')::int, 0);
      dsets := coalesce((p->>'sets')::int, 0)   - coalesce((o->>'sets')::int, 0);
      dmiss := coalesce((p->>'misses')::int, 0) - coalesce((o->>'misses')::int, 0);
      dnos  := coalesce((p->>'nos')::int, 0)    - coalesce((o->>'nos')::int, 0);
      dtn   := coalesce((p->>'tn')::int, 0)     - coalesce((o->>'tn')::int, 0);
      dts   := coalesce((p->>'tsum')::bigint, 0) - coalesce((o->>'tsum')::bigint, 0);
      if ds <> 0 or dsets <> 0 or dmiss <> 0 or dnos <> 0 or dtn <> 0 or dts <> 0 then
        movers := movers + 1;
        mv_ds := ds; mv_dsets := dsets; mv_dmiss := dmiss; mv_dnos := dnos; mv_dtn := dtn; mv_dts := dts;
      end if;
    end loop;
    if movers > 1 then raise exception 'only one player may score per update'; end if;

    ob := public.set_ints(OLD.board); nb := public.set_ints(NEW.board);
    od := public.set_ints(OLD.deck);  nd := public.set_ints(NEW.deck);
    removed := coalesce(array(select x from unnest(ob) x where x <> all (nb)), '{}');
    added   := coalesce(array(select x from unnest(nb) x where x <> all (ob)), '{}');
    k := coalesce(array_length(added, 1), 0);

    if movers = 0 then
      if nb = ob and nd = od then
        null;                                           -- z.B. Spieler verlassen
      else                                              -- Nachlegen (Zeitlimit)
        if k = 0 or k % 3 <> 0 or coalesce(array_length(removed, 1), 0) <> 0
           or nb <> ob || od[1:k] or nd <> od[k + 1:coalesce(array_length(od, 1), 0)] then
          raise exception 'invalid deal';
        end if;
      end if;

    elsif mv_ds = 1 and mv_dsets = 1 and mv_dmiss = 0 and mv_dnos = 0 and mv_dtn = 1 then
      -- gültiges SET
      if coalesce(array_length(removed, 1), 0) <> 3
         or not public.set_is_set(removed[1], removed[2], removed[3])
         or k % 3 <> 0
         or (select coalesce(array_agg(x order by x), '{}') from unnest(added) x)
            <> (select coalesce(array_agg(x order by x), '{}') from unnest(od[1:k]) x)
         or nd <> od[k + 1:coalesce(array_length(od, 1), 0)]
         or mv_dts < 500 or mv_dts > 120000 then
        raise exception 'invalid set';
      end if;

    elsif mv_ds = 1 and mv_dsets = 0 and mv_dmiss = 0 and mv_dnos = 1 and mv_dtn = 1 then
      -- korrektes "Kein Set"
      if public.set_board_has_set(OLD.board)
         or coalesce(array_length(removed, 1), 0) <> 0
         or k % 3 <> 0
         or nb <> ob || od[1:k]
         or nd <> od[k + 1:coalesce(array_length(od, 1), 0)]
         or mv_dts < 500 or mv_dts > 120000 then
        raise exception 'invalid no-set report';
      end if;

    elsif mv_ds = -1 and mv_dsets = 0 and mv_dmiss = 1 and mv_dnos = 0 and mv_dtn = 0 and mv_dts = 0 then
      -- falscher Zug: Tisch bleibt unverändert
      if nb <> ob or nd <> od then raise exception 'invalid miss'; end if;

    else
      raise exception 'invalid score change';
    end if;

    -- Spielende nur, wenn es die Regeln hergeben
    if NEW.status = 'finished' then
      teams := coalesce(NEW.players -> 0 -> 'cfg' ->> 'kind', 'ffa') = 'teams';
      if teams then
        select max(s) into mx from (
          select sum(coalesce((q->>'score')::int, 0)) as s
          from jsonb_array_elements(NEW.players) q group by (q->>'team')) g;
      else
        select max(coalesce((q->>'score')::int, 0)) into mx from jsonb_array_elements(NEW.players) q;
      end if;
      if (NEW.last ->> 'left') = 'true' then
        null;
      elsif jsonb_array_length(NEW.deck) = 0 and not public.set_board_has_set(NEW.board) then
        null;
      elsif NEW.target > 0 and mx >= NEW.target then
        -- Sieger muss die führende Seite sein (bei Gleichstand nicht prüfbar)
        if teams then
          select count(*) into leaders from (
            select sum(coalesce((q->>'score')::int, 0)) as s
            from jsonb_array_elements(NEW.players) q group by (q->>'team')) g where g.s = mx;
          if leaders = 1 then
            select 't' || (q->>'team') into lead from jsonb_array_elements(NEW.players) q
            group by (q->>'team') having sum(coalesce((q->>'score')::int, 0)) = mx;
          end if;
        else
          select count(*) into leaders from jsonb_array_elements(NEW.players) q
          where coalesce((q->>'score')::int, 0) = mx;
          if leaders = 1 then
            select (q->>'id') into lead from jsonb_array_elements(NEW.players) q
            where coalesce((q->>'score')::int, 0) = mx;
          end if;
        end if;
        if lead is not null and NEW.winner is distinct from lead then
          raise exception 'invalid winner';
        end if;
      else
        raise exception 'invalid finish';
      end if;
    end if;
  end if;

  return NEW;
end $$;

drop trigger if exists lobbies_guard_trg on public.lobbies;
create trigger lobbies_guard_trg before update on public.lobbies
  for each row execute function public.lobbies_guard();
