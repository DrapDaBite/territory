-- Синхронизация формы карты между всеми участниками территории.
-- Выполнить ОДИН РАЗ в Supabase SQL Editor.

alter table public.rooms
  add column if not exists mask jsonb;

create or replace function public.save_territory_mask(
  p_room_id uuid,
  p_mask jsonb
)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is null then
    raise exception 'Authentication required';
  end if;

  if not public.is_room_member(p_room_id, auth.uid()) then
    raise exception 'Not a member of this territory';
  end if;

  update public.rooms
  set mask = p_mask
  where id = p_room_id;

  if not found then
    raise exception 'Territory not found';
  end if;

  return true;
end;
$$;

revoke all on function public.save_territory_mask(uuid, jsonb) from public;
grant execute on function public.save_territory_mask(uuid, jsonb) to authenticated;

-- Чтобы изменения карты тоже приходили партнёру через Realtime.
do $$
begin
  begin
    alter publication supabase_realtime add table public.rooms;
  exception when duplicate_object then
    null;
  end;
end $$;
