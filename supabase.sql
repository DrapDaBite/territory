-- Наша территория v0.3
-- Выполни этот SQL целиком в Supabase SQL Editor.

create extension if not exists pgcrypto;

create table if not exists public.rooms (
  id uuid primary key default gen_random_uuid(),
  code text not null unique,
  name text not null default 'Наша территория',
  created_at timestamptz not null default now()
);

create table if not exists public.members (
  id uuid primary key default gen_random_uuid(),
  room_id uuid not null references public.rooms(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  display_name text not null,
  color text not null default 'green' check (color in ('green','purple')),
  created_at timestamptz not null default now(),
  unique(room_id, user_id)
);

create table if not exists public.claims (
  id uuid primary key default gen_random_uuid(),
  room_id uuid not null references public.rooms(id) on delete cascade,
  cell_key text not null,
  user_id uuid not null references auth.users(id) on delete cascade,
  title text not null,
  category text not null default 'Личное',
  date date not null default current_date,
  note text not null default '',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(room_id, cell_key, user_id)
);

create index if not exists members_room_id_idx on public.members(room_id);
create index if not exists members_user_id_idx on public.members(user_id);
create index if not exists claims_room_id_idx on public.claims(room_id);
create index if not exists claims_user_id_idx on public.claims(user_id);

alter table public.rooms enable row level security;
alter table public.members enable row level security;
alter table public.claims enable row level security;

drop policy if exists "members can see their rooms" on public.rooms;
create policy "members can see their rooms" on public.rooms
for select to authenticated
using (exists (select 1 from public.members m where m.room_id = rooms.id and m.user_id = auth.uid()));

drop policy if exists "members can see room members" on public.members;
create policy "members can see room members" on public.members
for select to authenticated
using (exists (select 1 from public.members mine where mine.room_id = members.room_id and mine.user_id = auth.uid()));

drop policy if exists "users can insert themselves into a room" on public.members;
create policy "users can insert themselves into a room" on public.members
for insert to authenticated
with check (user_id = auth.uid());

drop policy if exists "users can update themselves" on public.members;
create policy "users can update themselves" on public.members
for update to authenticated
using (user_id = auth.uid())
with check (user_id = auth.uid());

drop policy if exists "room members can see claims" on public.claims;
create policy "room members can see claims" on public.claims
for select to authenticated
using (exists (select 1 from public.members m where m.room_id = claims.room_id and m.user_id = auth.uid()));

drop policy if exists "room members can insert own claims" on public.claims;
create policy "room members can insert own claims" on public.claims
for insert to authenticated
with check (
  user_id = auth.uid()
  and exists (select 1 from public.members m where m.room_id = claims.room_id and m.user_id = auth.uid())
);

drop policy if exists "room members can update own claims" on public.claims;
create policy "room members can update own claims" on public.claims
for update to authenticated
using (user_id = auth.uid() and exists (select 1 from public.members m where m.room_id = claims.room_id and m.user_id = auth.uid()))
with check (user_id = auth.uid());

drop policy if exists "room members can delete own claims" on public.claims;
create policy "room members can delete own claims" on public.claims
for delete to authenticated
using (user_id = auth.uid() and exists (select 1 from public.members m where m.room_id = claims.room_id and m.user_id = auth.uid()));

create or replace function public.make_code()
returns text
language plpgsql
as $$
declare
  chars text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  out text := '';
  i int;
begin
  for i in 1..6 loop
    out := out || substr(chars, floor(random() * length(chars) + 1)::int, 1);
  end loop;
  return substr(out,1,3) || '-' || substr(out,4,3);
end;
$$;

create or replace function public.create_territory(p_name text, p_display_name text, p_color text)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  r public.rooms;
  c text;
begin
  if auth.uid() is null then raise exception 'Authentication required'; end if;
  loop
    c := public.make_code();
    begin
      insert into public.rooms(code,name) values (c, coalesce(nullif(trim(p_name),''),'Наша территория')) returning * into r;
      exit;
    exception when unique_violation then null;
    end;
  end loop;
  insert into public.members(room_id,user_id,display_name,color)
  values (r.id,auth.uid(),coalesce(nullif(trim(p_display_name),''),'Участник'),case when p_color='purple' then 'purple' else 'green' end)
  on conflict (room_id,user_id) do update set display_name=excluded.display_name,color=excluded.color;
  return json_build_object('room_id',r.id,'code',r.code,'name',r.name);
end;
$$;

grant execute on function public.create_territory(text,text,text) to authenticated;

grant select on public.rooms, public.members, public.claims to authenticated;
grant insert, update, delete on public.members, public.claims to authenticated;

create or replace function public.join_territory(p_code text, p_display_name text, p_color text)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  r public.rooms;
begin
  if auth.uid() is null then raise exception 'Authentication required'; end if;
  select * into r from public.rooms where upper(code)=upper(trim(p_code)) limit 1;
  if r.id is null then raise exception 'Territory not found'; end if;
  insert into public.members(room_id,user_id,display_name,color)
  values (r.id,auth.uid(),coalesce(nullif(trim(p_display_name),''),'Участник'),case when p_color='purple' then 'purple' else 'green' end)
  on conflict (room_id,user_id) do update set display_name=excluded.display_name,color=excluded.color;
  return json_build_object('room_id',r.id,'code',r.code,'name',r.name);
end;
$$;

grant execute on function public.join_territory(text,text,text) to authenticated;

-- Realtime: включаем синхронизацию записей и участников.
do $$
begin
  begin alter publication supabase_realtime add table public.claims; exception when duplicate_object then null; end;
  begin alter publication supabase_realtime add table public.members; exception when duplicate_object then null; end;
end $$;

-- После первого запуска можно оставить SQL как есть. Политики намеренно ограничивают
-- чтение/изменение только участниками конкретной территории и только своими claims.
