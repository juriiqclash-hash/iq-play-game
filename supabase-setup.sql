-- Im Supabase Dashboard: SQL Editor -> New query -> einfügen -> Run

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

create policy "lobbies select" on public.lobbies for select to anon using (true);
create policy "lobbies insert" on public.lobbies for insert to anon with check (true);
create policy "lobbies update" on public.lobbies for update to anon using (true) with check (true);

-- Realtime aktivieren
alter publication supabase_realtime add table public.lobbies;
