-- ============================================================================
-- PATCH 16: PTM (parent-teacher meeting) tracker
-- Run ONCE in Supabase > SQL Editor on the live school project. Safe to run again.
-- Who can use it: owner, manager (any class) and the class teacher (own class only).
-- Parents and logged-out visitors see nothing.
-- ============================================================================
create table if not exists ptm_records(
  id uuid primary key default gen_random_uuid(),
  student_id uuid not null references students(id) on delete cascade,
  cycle text not null check (cycle ~ '^[0-9]{4}-[0-9]{2}$'),
  status text not null check (status in ('Done','Parent did not come','Needs follow-up')),
  held_on date,
  met_with text check (met_with is null or met_with in ('Father','Mother','Guardian','Other')),
  note text check (note is null or length(note) <= 1000),
  held_by uuid references profiles(id),
  held_by_name text check (held_by_name is null or length(held_by_name) <= 80),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (student_id, cycle));
create index if not exists ptm_records_cycle_idx on ptm_records(cycle);

alter table ptm_records enable row level security;

create or replace function ptm_can(sid uuid) returns boolean language sql stable security definer set search_path = public as
$$ select coalesce(is_admin(), false)
       or (coalesce(my_role() = 'teacher', false)
           and exists(select 1 from students s where s.id = sid and s.class_id = my_class())) $$;
revoke all on function ptm_can(uuid) from public, anon;
grant execute on function ptm_can(uuid) to authenticated;

drop policy if exists ptm_sel on ptm_records;
create policy ptm_sel on ptm_records for select using (ptm_can(student_id));
drop policy if exists ptm_ins on ptm_records;
create policy ptm_ins on ptm_records for insert with check (held_by = (select auth.uid()) and ptm_can(student_id));
drop policy if exists ptm_upd on ptm_records;
create policy ptm_upd on ptm_records for update using (ptm_can(student_id)) with check (ptm_can(student_id));
drop policy if exists ptm_del on ptm_records;
create policy ptm_del on ptm_records for delete using (ptm_can(student_id));

insert into app_patches(name, note) values ('patch-16', 'PTM tracker') on conflict do nothing;

-- Check (expected: ptm_table = 1, ptm_policies = 4, patch-16 in the list)
select
  (select count(*) from pg_tables where schemaname='public' and tablename='ptm_records') as ptm_table,
  (select count(*) from pg_policies where schemaname='public' and tablename='ptm_records') as ptm_policies,
  (select string_agg(name, ', ' order by name) from app_patches) as patches_recorded;
