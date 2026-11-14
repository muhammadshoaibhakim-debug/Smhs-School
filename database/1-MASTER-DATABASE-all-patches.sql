-- ============================================================================
-- SCHOLARS MODEL HIGH SCHOOL (SMHS ELLAHABAD): MASTER DATABASE FILE (everything in ONE file)
--
-- WHAT IS INSIDE (in this order):
--   1. Tables + columns + limits (check rules)      17 tables incl. exams / exam_marks
--   2. Helper functions (who is asking?)
--   3. Row Level Security: every table locked, each role sees only its own data
--   4. PATCH 1  attendance only when every active student is marked
--      PATCH 2  create teacher / parent / manager logins from the app
--      PATCH 3  automatic parent logins from student data
--      PATCH 4  people who sign up themselves see NOTHING
--      PATCH 5  logins list, reset password, class-wise slips
--      PATCH 6  Pakistan-time dates, diary due date
--      PATCH 7  student withdrawal, delete students / logins
--      PATCH 8  speed (indexes, faster loading)
--      PATCH 9  phone notification tables
--      PATCH 10 simple logins
--      PATCH 11 Tests and Results (exams, exam_marks)
--      PATCH 12 hardening + System check (Backup page)
--      PATCH 13 security hardening
--      PATCH 14 Results: Term column (First / Second / Final Term)
--   5. Final check at the very end (shows OK counts)
--
-- HOW TO USE: only on a NEW, EMPTY Supabase project. Run it ONCE.
--   SQL Editor > New query > paste everything > Run.
--   If an error appears nothing is kept (all or nothing). Send the error text.
--   If the project already has the school database this file stops by itself
--   with a clear message and changes nothing.
-- AFTER IT: create the owner with OWNER-first-login.sql (set your own strong
--   password there), then Authentication > turn OFF "Allow new users to sign up".
-- NOT inside (on purpose): patch 9b notification clock (needs this school's own
--   URL and secret) and any password.
-- ============================================================================

do $guard$ begin
  if to_regclass('public.profiles') is not null then
    raise exception 'STOP: this project already has the school database. Do not run this file again.';
  end if;
end $guard$;



-- ############################################################################
-- ##  PART 1 of 13: DATABASE (tables, security rules)
-- ############################################################################

-- Scholars Model High School: Phase 1 database for Supabase (PostgreSQL)
-- Run once in: Supabase dashboard > SQL Editor > New query > paste > Run.
-- Run it on a fresh, empty project first. (Checked on a local PostgreSQL 16 with a stand-in for Supabase's login tables; not yet on a real Supabase project.)

create extension if not exists pgcrypto;

-- ============ TABLES ============
create table profiles(
  id uuid primary key references auth.users on delete cascade,
  username text unique not null check (username ~ '^[a-z0-9._]{3,30}$'),
  name text not null,
  role text not null check (role in ('admin','manager','teacher','parent')),
  class_id uuid, phone text,
  salary int check (salary >= 0),
  active boolean not null default true,
  must_change boolean not null default true,
  created_at timestamptz not null default now());

create table classes(
  id uuid primary key default gen_random_uuid(),
  name text unique not null,
  teacher_id uuid references profiles on delete set null);
alter table profiles add foreign key (class_id) references classes on delete set null;

create table students(
  id uuid primary key default gen_random_uuid(),
  admission_no text unique not null,
  name text not null, father text not null, phone text,
  class_id uuid references classes,
  roll int not null check (roll > 0),
  admission_date date not null check (admission_date >= '2000-01-01'),
  monthly_fee int not null check (monthly_fee between 0 and 500000),
  status text not null default 'Active' check (status in ('Active','Left','Graduated','Archived')),
  gender text, dob date, b_form text, father_cnic text, prev_school text, address text,
  photo_path text,
  created_at timestamptz not null default now());
create unique index students_roll_per_class on students(class_id, roll) where status = 'Active';

create table parent_students(
  parent_id uuid references profiles on delete cascade,
  student_id uuid references students on delete cascade,
  primary key (parent_id, student_id));

create table attendance(
  student_id uuid references students on delete cascade,
  day date not null,
  status text not null check (status in ('Present','Absent','Late','Leave')),
  marked_by uuid references profiles,
  primary key (student_id, day));

create table attendance_final(
  class_id uuid references classes on delete cascade,
  day date not null,
  finalized_by uuid references profiles,
  created_at timestamptz not null default now(),
  primary key (class_id, day));

create sequence receipt_seq start 1001;
create table fees(
  id uuid primary key default gen_random_uuid(),
  receipt text unique not null default ('RC-' || nextval('receipt_seq')),
  student_id uuid not null references students,
  month text not null check (month ~ '^\d{4}-\d{2}$'),
  amount int not null,
  day date not null default current_date,
  method text not null,
  ref text unique,
  kind text not null check (kind in ('payment','reversal')),
  reverses uuid references fees,
  reason text,
  reversed boolean not null default false,
  by_user uuid references profiles,
  created_at timestamptz not null default now(),
  check ((kind = 'payment' and amount > 0)
      or (kind = 'reversal' and amount < 0 and reverses is not null and reason is not null)));
-- one live (not reversed) payment per student per month, enforced by the database
create unique index one_live_payment on fees(student_id, month) where kind = 'payment' and not reversed;

create function mark_reversed() returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.kind = 'reversal' then
    update fees set reversed = true where id = new.reverses and kind = 'payment';
  end if;
  return new;
end $$;
create trigger fees_mark_reversed after insert on fees for each row execute function mark_reversed();

create table expenses(
  id uuid primary key default gen_random_uuid(),
  day date not null check (day <= current_date),
  category text not null, amount int not null check (amount > 0),
  payee text, method text not null, ref text, note text,
  voided boolean not null default false, void_reason text,
  by_user uuid references profiles,
  created_at timestamptz not null default now());

create table notices(
  id uuid primary key default gen_random_uuid(),
  class_id uuid references classes,            -- null = whole school
  title text not null, body text not null,
  author_id uuid not null references profiles,
  removed boolean not null default false,
  created_at timestamptz not null default now());

create table diary(
  id uuid primary key default gen_random_uuid(),
  class_id uuid not null references classes,
  day date not null, subject text not null, homework text,
  published boolean not null default false,
  author_id uuid references profiles,
  created_at timestamptz not null default now());

create table payroll(
  id uuid primary key default gen_random_uuid(),
  teacher_id uuid not null references profiles,
  month text not null check (month ~ '^\d{4}-\d{2}$'),
  basic int not null check (basic >= 0), bonus int not null default 0, deduction int not null default 0,
  status text not null default 'Pending' check (status in ('Pending','Paid')),
  unique (teacher_id, month));

create table audit_log(
  id bigint generated always as identity primary key,
  user_id uuid references profiles,
  action text not null, detail text,
  created_at timestamptz not null default now());

-- ============ HELPER FUNCTIONS (who is asking?) ============
create function my_role() returns text language sql stable security definer set search_path = public as
$$ select role from profiles where id = auth.uid() and active $$;
create function my_class() returns uuid language sql stable security definer set search_path = public as
$$ select class_id from profiles where id = auth.uid() and active $$;
create function is_admin() returns boolean language sql stable security definer set search_path = public as
$$ select coalesce(my_role() in ('admin','manager'), false) $$;
create function is_owner() returns boolean language sql stable security definer set search_path = public as
$$ select coalesce(my_role() = 'admin', false) $$;
create function is_my_kid(sid uuid) returns boolean language sql stable security definer set search_path = public as
$$ select coalesce(my_role() = 'parent', false) and exists(select 1 from parent_students where parent_id = auth.uid() and student_id = sid) $$;
create function kid_in_class(cid uuid) returns boolean language sql stable security definer set search_path = public as
$$ select coalesce(my_role() = 'parent', false) and exists(select 1 from parent_students ps join students s on s.id = ps.student_id where ps.parent_id = auth.uid() and s.class_id = cid) $$;
create function can_see_student(sid uuid) returns boolean language sql stable security definer set search_path = public as
$$ select is_admin() or is_my_kid(sid)
       or (my_role() = 'teacher' and exists(select 1 from students s where s.id = sid and s.class_id = my_class())) $$;
create function is_finalized(sid uuid, d date) returns boolean language sql stable security definer set search_path = public as
$$ select exists(select 1 from attendance_final f join students s on s.class_id = f.class_id where s.id = sid and f.day = d) $$;

-- ============ ROW LEVEL SECURITY (the real protection) ============
alter table profiles enable row level security;
alter table classes enable row level security;
alter table students enable row level security;
alter table parent_students enable row level security;
alter table attendance enable row level security;
alter table attendance_final enable row level security;
alter table fees enable row level security;
alter table expenses enable row level security;
alter table notices enable row level security;
alter table diary enable row level security;
alter table payroll enable row level security;
alter table audit_log enable row level security;

-- profiles: everyone reads own row; staff admins read all; only owner/manager write (never the owner row)
create policy p_sel on profiles for select using (id = auth.uid() or is_admin());
create policy p_upd on profiles for update using (is_admin() and role <> 'admin') with check (is_admin() and role <> 'admin');

-- classes: all signed-in users may read class names; only admin/manager write
create policy c_sel on classes for select using (auth.uid() is not null);
create policy c_all on classes for all using (is_admin()) with check (is_admin());

-- students: admin/manager all; teacher own class; parent own children
create policy s_sel on students for select using (can_see_student(id));
create policy s_ins on students for insert with check (is_admin());
create policy s_upd on students for update using (is_admin()) with check (is_admin());

create policy ps_sel on parent_students for select using (is_admin() or parent_id = auth.uid());
create policy ps_all on parent_students for all using (is_admin()) with check (is_admin());

-- attendance: read by anyone who can see the student; teacher writes own class until submitted; admin always
create policy a_sel on attendance for select using (can_see_student(student_id));
create policy a_ins on attendance for insert with check (
  is_admin() or (my_role() = 'teacher' and can_see_student(student_id) and not is_finalized(student_id, day)));
create policy a_upd on attendance for update
  using (is_admin() or (my_role() = 'teacher' and can_see_student(student_id) and not is_finalized(student_id, day)))
  with check (is_admin() or (my_role() = 'teacher' and can_see_student(student_id) and not is_finalized(student_id, day)));
create policy af_sel on attendance_final for select using (is_admin() or class_id = my_class());
create policy af_ins on attendance_final for insert with check (is_admin() or (my_role() = 'teacher' and class_id = my_class()));

-- fees: admin/manager and the child's parent can read; only admin/manager add; nobody updates or deletes
create policy f_sel on fees for select using (is_admin() or is_my_kid(student_id));
create policy f_ins on fees for insert with check (is_admin());

-- expenses and payroll: admin/manager only; nothing is ever deleted (void instead)
create policy e_sel on expenses for select using (is_admin());
create policy e_ins on expenses for insert with check (is_admin());
create policy e_upd on expenses for update using (is_admin()) with check (is_admin());
create policy pr_all on payroll for all using (is_admin()) with check (is_admin());

-- notices: admin all; teacher own class + whole school; parent own children's classes + whole school
create policy n_sel on notices for select using (not removed and (
  is_admin() or class_id is null or class_id = my_class() or kid_in_class(class_id)));
create policy n_ins on notices for insert with check (author_id = auth.uid() and (
  is_admin() or (my_role() = 'teacher' and class_id is not null and class_id = my_class())));
create policy n_upd on notices for update using (is_admin() or author_id = auth.uid()) with check (is_admin() or author_id = auth.uid());

-- diary: teacher own class; parents see only published entries of their child's class
create policy d_sel on diary for select using (is_admin() or class_id = my_class() or (published and kid_in_class(class_id)));
create policy d_ins on diary for insert with check (author_id = auth.uid() and (is_admin() or (my_role() = 'teacher' and class_id = my_class())));
create policy d_upd on diary for update using (is_admin() or (my_role() = 'teacher' and class_id = my_class()))
  with check (is_admin() or (my_role() = 'teacher' and class_id = my_class()));

-- audit log: anyone signed in may add a line about themselves; only the owner reads; never edited or deleted
create policy al_ins on audit_log for insert with check (user_id = auth.uid());
create policy al_sel on audit_log for select using (is_owner());

-- attendance can be submitted only when every active student of the class is marked
create function check_attendance_complete() returns trigger language plpgsql security definer set search_path = public as $$
begin
  if exists (select 1 from students s
             where s.class_id = new.class_id and s.status = 'Active'
               and not exists (select 1 from attendance a where a.student_id = s.id and a.day = new.day)) then
    raise exception 'Mark every student before submitting attendance';
  end if;
  return new;
end $$;
create trigger attendance_final_complete before insert on attendance_final for each row execute function check_attendance_complete();

-- ============ FIRST OWNER: run OWNER-first-login.sql after this file (it creates the login and the profile in one step) ============


-- ############################################################################
-- ##  PART 2 of 13: PATCH 1
-- ############################################################################

-- PATCH 1: attendance can only be submitted when EVERY active student of the class is marked.
-- (The old line that cleared today's attendance is removed here: a setup file must never delete data.)
create or replace function check_attendance_complete() returns trigger language plpgsql security definer set search_path = public as $$
begin
  if exists (select 1 from students s
             where s.class_id = new.class_id and s.status = 'Active'
               and not exists (select 1 from attendance a where a.student_id = s.id and a.day = new.day)) then
    raise exception 'Mark every student before submitting attendance';
  end if;
  return new;
end $$;
drop trigger if exists attendance_final_complete on attendance_final;
create trigger attendance_final_complete before insert on attendance_final for each row execute function check_attendance_complete();



-- ############################################################################
-- ##  PART 3 of 13: PATCH 2
-- ############################################################################

-- PATCH 2: create teacher/parent/manager logins and reset passwords FROM THE APP (no secret key in the browser).
-- Run once in the SQL Editor (after supabase-schema.sql and patch 1).

create or replace function create_school_user(
  p_username text, p_name text, p_role text, p_password text,
  p_phone text default null, p_class uuid default null, p_students uuid[] default '{}', p_salary int default null)
returns uuid language plpgsql security definer set search_path = public, auth, extensions as $$
declare uid uuid; em text; s uuid; u text := lower(trim(p_username));
begin
  if not is_admin() then raise exception 'Not allowed'; end if;
  if p_role not in ('manager','teacher','parent') then raise exception 'Role must be manager, teacher or parent'; end if;
  if p_role = 'manager' and not is_owner() then raise exception 'Only the owner can create managers'; end if;
  if u !~ '^[a-z0-9._]{3,30}$' then raise exception 'Username: 3 to 30 letters, digits, dot or underscore'; end if;
  if length(coalesce(p_password,'')) < 8 or p_password !~ '[A-Za-z]' or p_password !~ '[0-9]' or position(u in lower(p_password)) > 0 then
    raise exception 'Password needs 8+ characters with letters and numbers, and must not contain the username'; end if;
  if coalesce(trim(p_name),'') = '' then raise exception 'Enter the name'; end if;
  if exists (select 1 from profiles where username = u) then raise exception 'This username is already taken'; end if;
  em := u || '@names.school'; uid := gen_random_uuid();
  insert into auth.users(instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,raw_app_meta_data,raw_user_meta_data,created_at,updated_at,confirmation_token,recovery_token,email_change_token_new,email_change)
  values ('00000000-0000-0000-0000-000000000000',uid,'authenticated','authenticated',em,crypt(p_password,gen_salt('bf')),now(),'{"provider":"email","providers":["email"]}','{}',now(),now(),'','','','');
  insert into auth.identities(id,user_id,provider_id,identity_data,provider,last_sign_in_at,created_at,updated_at)
  values (gen_random_uuid(),uid,uid::text,jsonb_build_object('sub',uid::text,'email',em,'email_verified',true),'email',now(),now(),now());
  insert into profiles(id,username,name,role,class_id,phone,salary,must_change)
  values (uid,u,trim(p_name),p_role,case when p_role='teacher' then p_class end,p_phone,p_salary,true);
  if p_role = 'teacher' and p_class is not null then
    update profiles set class_id = null where class_id = p_class and role = 'teacher' and id <> uid;
    update classes set teacher_id = uid where id = p_class;
  end if;
  if p_role = 'parent' then
    foreach s in array coalesce(p_students,'{}') loop
      insert into parent_students values (uid, s) on conflict do nothing;
    end loop;
  end if;
  insert into audit_log(user_id,action,detail) values (auth.uid(),'user.create',p_role || ' ' || u);
  return uid;
end $$;

create or replace function reset_school_password(p_username text, p_password text)
returns void language plpgsql security definer set search_path = public, auth, extensions as $$
declare t profiles; u text := lower(trim(p_username));
begin
  if not is_admin() then raise exception 'Not allowed'; end if;
  select * into t from profiles where username = u;
  if t.id is null then raise exception 'No such user'; end if;
  if t.role = 'admin' then raise exception 'The owner password cannot be reset here'; end if;
  if t.role = 'manager' and not is_owner() then raise exception 'Only the owner can reset a manager'; end if;
  if length(coalesce(p_password,'')) < 8 or p_password !~ '[A-Za-z]' or p_password !~ '[0-9]' or position(u in lower(p_password)) > 0 then
    raise exception 'Password needs 8+ characters with letters and numbers, and must not contain the username'; end if;
  update auth.users set encrypted_password = crypt(p_password, gen_salt('bf')), updated_at = now() where id = t.id;
  update profiles set must_change = true where id = t.id;
  insert into audit_log(user_id,action,detail) values (auth.uid(),'user.reset_password',u);
end $$;

-- a user who just changed their own password clears the "must change" flag
create or replace function password_changed() returns void language sql security definer set search_path = public as
$$ update profiles set must_change = false where id = auth.uid() $$;

revoke all on function create_school_user(text,text,text,text,text,uuid,uuid[],int) from public;
revoke all on function reset_school_password(text,text) from public;
revoke all on function password_changed() from public;
grant execute on function create_school_user(text,text,text,text,text,uuid,uuid[],int) to authenticated;
grant execute on function reset_school_password(text,text) to authenticated;
grant execute on function password_changed() to authenticated;


-- ############################################################################
-- ##  PART 4 of 13: PATCH 3
-- ############################################################################

-- PATCH 3: automatic parent logins from student data (one login per parent phone number).
-- Username = 'p' + phone digits, random temporary password (shown once, must be changed at first sign-in).
-- Brothers and sisters with the same phone share one login. Run once in the SQL Editor (after patches 1 and 2).

create or replace function _rnd(alpha text, n int) returns text language sql volatile security definer set search_path = public, extensions as
$$ select string_agg(substr(alpha, 1 + (get_byte(gen_random_bytes(1), 0) % length(alpha)), 1), '') from generate_series(1, n) $$;

-- 0311-5551234, 03115551234, +92 311 5551234 and 0092 311 5551234 all become 03115551234
create or replace function _norm_phone(p text) returns text language sql immutable as $$
  select case when d ~ '^0092' then '0' || substr(d, 5)
              when d ~ '^92' and length(d) = 12 then '0' || substr(d, 3)
              else d end
  from (select regexp_replace(coalesce(p,''), '\D', '', 'g') as d) x $$;

create or replace function create_parent_logins()
returns table(login_name text, temp_password text, parent_name text, children_names text, parent_phone text)
language plpgsql security definer set search_path = public, auth, extensions as $$
declare r record; u text; pw text;
begin
  if not is_admin() then raise exception 'Not allowed'; end if;
  for r in
    select _norm_phone(s.phone) as d, (array_agg(s.father order by s.roll))[1] as fname,
           array_agg(s.id) as sids, string_agg(s.name, ', ' order by s.name) as names, min(s.phone) as ph
    from students s
    where s.status = 'Active' and s.phone is not null
      and length(_norm_phone(s.phone)) between 8 and 15
      and not exists (select 1 from parent_students ps where ps.student_id = s.id)
    group by _norm_phone(s.phone)
  loop
    u := 'p' || r.d;
    if exists (select 1 from profiles where username = u) then
      -- this parent already has a login: just link the new children, no new password
      insert into parent_students select (select id from profiles where username = u), x from unnest(r.sids) x on conflict do nothing;
      continue;
    end if;
    pw := _rnd('ABCDEFGHJKMNPQRSTUVWXYZ', 2) || _rnd('abcdefghjkmnpqrstuvwxyz', 6) || _rnd('23456789', 3);
    perform create_school_user(u, r.fname, 'parent', pw, r.ph, null, r.sids);
    login_name := u; temp_password := pw; parent_name := r.fname; children_names := r.names; parent_phone := r.ph;
    return next;
  end loop;
end $$;

revoke all on function _rnd(text,int) from public;
revoke all on function create_parent_logins() from public;
revoke all on function _norm_phone(text) from public;
grant execute on function _norm_phone(text) to authenticated;
grant execute on function create_parent_logins() to authenticated;


-- ############################################################################
-- ##  PART 5 of 13: PATCH 4
-- ############################################################################

-- PATCH 4 (security): people who sign themselves up (no school profile) must see NOTHING.
-- Before this, any such account could read class names and whole-school notices. Run once in the SQL Editor.
drop policy if exists c_sel on classes;
create policy c_sel on classes for select using (my_role() is not null);
drop policy if exists n_sel on notices;
create policy n_sel on notices for select using (
  my_role() is not null and not removed and (is_admin() or class_id is null or class_id = my_class() or kid_in_class(class_id)));


-- ############################################################################
-- ##  PART 6 of 13: PATCH 5
-- ############################################################################

-- PATCH 5: Logins list (owner/manager), one-click Reset password, class-wise slips.
-- Run once in the SQL Editor (after patches 1 to 4). Safe to run twice.
-- Passwords are always generated by the database and shown once on a printable slip; nobody has to invent one.

-- Everyone who has a login (never the owner), with their class and children. Manager rows only for the owner.
create or replace function list_logins()
returns table(login_name text, full_name text, user_role text, phone_no text,
              class_id uuid, class_name text, children_names text, first_login_done boolean, is_active boolean)
language plpgsql stable security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'Not allowed'; end if;
  return query
  select p.username, p.name, p.role, p.phone,
         -- teacher: own class. parent: class of the first child (class name, then roll) so each parent is listed once
         case when p.role = 'teacher' then p.class_id
              when p.role = 'parent' then (select s.class_id from parent_students ps join students s on s.id = ps.student_id
                                           left join classes c on c.id = s.class_id where ps.parent_id = p.id
                                           order by c.name nulls last, s.roll limit 1) end,
         case when p.role = 'teacher' then (select c.name from classes c where c.id = p.class_id)
              when p.role = 'parent' then (select c.name from parent_students ps join students s on s.id = ps.student_id
                                           left join classes c on c.id = s.class_id where ps.parent_id = p.id
                                           order by c.name nulls last, s.roll limit 1) end,
         (select string_agg(s.name, ', ' order by s.name) from parent_students ps join students s on s.id = ps.student_id where ps.parent_id = p.id),
         not p.must_change, p.active
  from profiles p
  where p.role <> 'admin' and (p.role <> 'manager' or is_owner())
  order by p.role, p.name;
end $$;

-- Reset one login: new random temporary password, user must choose their own at next sign-in.
create or replace function reset_login_random(p_username text)
returns table(login_name text, temp_password text, parent_name text, children_names text)
language plpgsql security definer set search_path = public, auth, extensions as $$
declare u text := lower(trim(p_username)); pw text; t profiles; tries int := 0; ok boolean := false;
begin
  if not is_admin() then raise exception 'Not allowed'; end if;
  select * into t from profiles where username = u;
  if t.id is null then raise exception 'No such user'; end if;
  while not ok loop
    tries := tries + 1;
    pw := _rnd('ABCDEFGHJKMNPQRSTUVWXYZ', 2) || _rnd('abcdefghjkmnpqrstuvwxyz', 6) || _rnd('23456789', 3);
    begin
      perform reset_school_password(u, pw); ok := true;
    exception when others then
      -- only a password that happens to contain the username is worth retrying; permission errors must surface
      if sqlerrm not like 'Password needs%' or tries >= 8 then raise; end if;
    end;
  end loop;
  login_name := u; temp_password := pw; parent_name := t.name;
  children_names := (select string_agg(s.name, ', ' order by s.name) from parent_students ps join students s on s.id = ps.student_id where ps.parent_id = t.id);
  return next;
end $$;

-- Slips for a whole class in one go: only parents who have NOT signed in yet (their old temporary password is useless anyway).
-- p_class = null means every class. Parents who already chose their own password are never touched.
create or replace function reissue_parent_slips(p_class uuid default null)
returns table(login_name text, temp_password text, parent_name text, children_names text)
language plpgsql security definer set search_path = public, auth, extensions as $$
declare r record;
begin
  if not is_admin() then raise exception 'Not allowed'; end if;
  for r in select l.login_name as un from list_logins() l
           where l.user_role = 'parent' and l.is_active and not l.first_login_done
             and (p_class is null or l.class_id = p_class)
           order by l.class_name nulls last, l.full_name
  loop
    return query select * from reset_login_random(r.un);
  end loop;
end $$;

revoke all on function list_logins() from public;
revoke all on function reset_login_random(text) from public;
revoke all on function reissue_parent_slips(uuid) from public;
grant execute on function list_logins() to authenticated;
grant execute on function reset_login_random(text) to authenticated;
grant execute on function reissue_parent_slips(uuid) to authenticated;


-- ############################################################################
-- ##  PART 7 of 13: PATCH 6
-- ############################################################################

-- PATCH 6: Pakistan-time dates, diary due date. Run once in the SQL Editor (after patches 1 to 5). Safe to run twice.

-- 1) The database used UTC "today", the app sends Pakistan "today". Between midnight and 5 am Pakistan time an expense
--    dated today was refused ("day <= current_date"). Both now use Asia/Karachi.
do $$ declare c record; begin
  for c in select conname from pg_constraint
           where conrelid = 'public.expenses'::regclass and contype = 'c' and pg_get_constraintdef(oid) ilike '%current_date%'
  loop execute format('alter table public.expenses drop constraint %I', c.conname); end loop;
end $$;
alter table expenses drop constraint if exists expenses_day_not_future;
alter table expenses add constraint expenses_day_not_future check (day <= (now() at time zone 'Asia/Karachi')::date);
alter table fees alter column day set default (now() at time zone 'Asia/Karachi')::date;

-- 2) The diary screen has a "Due date" field, but the table had no column for it, so it was lost on every save.
alter table diary add column if not exists due date;


-- ############################################################################
-- ##  PART 8 of 13: PATCH 7
-- ############################################################################

-- PATCH 7: student withdrawal (date + reason), delete students, delete logins (teacher / parent / manager) from the app.
-- Run once in the SQL Editor (after patches 1 to 6). Safe to run twice.

-- 1) a withdrawn student keeps a date and a reason
alter table students add column if not exists left_date date;
alter table students add column if not exists left_reason text;

-- 2) an old audit line must never stop a login from being deleted: the line stays, only the user link is cleared
do $$ declare c record; begin
  for c in select conname from pg_constraint
           where conrelid = 'public.audit_log'::regclass and contype = 'f' and pg_get_constraintdef(oid) ilike '%references profiles%'
  loop execute format('alter table public.audit_log drop constraint %I', c.conname); end loop;
end $$;
alter table audit_log add constraint audit_log_user_id_fkey foreign key (user_id) references profiles(id) on delete set null;

-- 3) delete students (owner only). A student with fee records is never deleted (the money history must stay): use Withdraw.
create or replace function delete_students(p_ids uuid[])
returns jsonb language plpgsql security definer set search_path = public as $$
declare d int := 0; k int := 0; r record;
begin
  if not is_owner() then raise exception 'Only the owner can delete students'; end if;
  for r in select id, name, admission_no from students where id = any(coalesce(p_ids, '{}')) loop
    if exists (select 1 from fees where student_id = r.id) then
      k := k + 1;
    else
      delete from students where id = r.id;   -- attendance and parent links go with the student
      d := d + 1;
      insert into audit_log(user_id, action, detail) values (auth.uid(), 'student.delete', r.name || ' (' || r.admission_no || ')');
    end if;
  end loop;
  return jsonb_build_object('deleted', d, 'kept', k);
end $$;

-- 4) delete a login (owner only). Someone with history (attendance, fees, diary, payroll...) is switched off instead and the history stays.
create or replace function delete_school_user(p_username text)
returns text language plpgsql security definer set search_path = public, auth as $$
declare t profiles; u text := lower(trim(p_username));
begin
  if not is_owner() then raise exception 'Only the owner can delete a login'; end if;
  select * into t from profiles where username = u;
  if t.id is null then raise exception 'No such user'; end if;
  if t.role = 'admin' then raise exception 'The owner login cannot be deleted'; end if;
  begin
    update classes set teacher_id = null where teacher_id = t.id;
    delete from auth.users where id = t.id;          -- the profile and parent links go with it
    insert into audit_log(user_id, action, detail) values (auth.uid(), 'user.delete', t.role || ' ' || u);
    return 'deleted';
  exception when foreign_key_violation then
    update classes set teacher_id = null where teacher_id = t.id;
    update profiles set active = false, class_id = null where id = t.id;
    insert into audit_log(user_id, action, detail) values (auth.uid(), 'user.disable', t.role || ' ' || u || ' (has history, switched off)');
    return 'disabled';
  end;
end $$;

revoke all on function delete_students(uuid[]) from public;
revoke all on function delete_school_user(text) from public;
grant execute on function delete_students(uuid[]) to authenticated;
grant execute on function delete_school_user(text) to authenticated;


-- ############################################################################
-- ##  PART 9 of 13: PATCH 8
-- ############################################################################

-- PATCH 8 (speed): faster loading. Run once in the SQL Editor after patch 7. Safe to run twice.
-- 1) indexes for the lookups the app does all day
create index if not exists fees_student_idx      on fees(student_id);
create index if not exists fees_created_idx      on fees(created_at);
create index if not exists attendance_day_idx    on attendance(day);
create index if not exists students_class_idx    on students(class_id);
create index if not exists ps_student_idx        on parent_students(student_id);
create index if not exists diary_class_day_idx   on diary(class_id, day);
create index if not exists notices_created_idx   on notices(created_at);
create index if not exists expenses_created_idx  on expenses(created_at);
create index if not exists payroll_teacher_idx   on payroll(teacher_id);

-- 2) the same security rules as before, written so the database works out "who is asking" ONCE per request
--    instead of once for every row (with thousands of attendance rows this was the main reason for slow loading).
--    Nothing about WHO may see or change WHAT is different; only the way it is evaluated.
drop policy if exists p_sel on profiles;
create policy p_sel on profiles for select using (id = (select auth.uid()) or (select is_admin()));
drop policy if exists p_upd on profiles;
create policy p_upd on profiles for update using ((select is_admin()) and role <> 'admin') with check ((select is_admin()) and role <> 'admin');

drop policy if exists c_sel on classes;
create policy c_sel on classes for select using ((select my_role()) is not null);
drop policy if exists c_all on classes;
create policy c_all on classes for all using ((select is_admin())) with check ((select is_admin()));

drop policy if exists s_sel on students;
create policy s_sel on students for select using ((select is_admin()) or can_see_student(id));
drop policy if exists s_ins on students;
create policy s_ins on students for insert with check ((select is_admin()));
drop policy if exists s_upd on students;
create policy s_upd on students for update using ((select is_admin())) with check ((select is_admin()));

drop policy if exists ps_sel on parent_students;
create policy ps_sel on parent_students for select using ((select is_admin()) or parent_id = (select auth.uid()));
drop policy if exists ps_all on parent_students;
create policy ps_all on parent_students for all using ((select is_admin())) with check ((select is_admin()));

drop policy if exists a_sel on attendance;
create policy a_sel on attendance for select using ((select is_admin()) or can_see_student(student_id));
drop policy if exists a_ins on attendance;
create policy a_ins on attendance for insert with check (
  (select is_admin()) or ((select my_role()) = 'teacher' and can_see_student(student_id) and not is_finalized(student_id, day)));
drop policy if exists a_upd on attendance;
create policy a_upd on attendance for update
  using ((select is_admin()) or ((select my_role()) = 'teacher' and can_see_student(student_id) and not is_finalized(student_id, day)))
  with check ((select is_admin()) or ((select my_role()) = 'teacher' and can_see_student(student_id) and not is_finalized(student_id, day)));
drop policy if exists af_sel on attendance_final;
create policy af_sel on attendance_final for select using ((select is_admin()) or class_id = (select my_class()));
drop policy if exists af_ins on attendance_final;
create policy af_ins on attendance_final for insert with check ((select is_admin()) or ((select my_role()) = 'teacher' and class_id = (select my_class())));

drop policy if exists f_sel on fees;
create policy f_sel on fees for select using ((select is_admin()) or is_my_kid(student_id));
drop policy if exists f_ins on fees;
create policy f_ins on fees for insert with check ((select is_admin()));

drop policy if exists e_sel on expenses;
create policy e_sel on expenses for select using ((select is_admin()));
drop policy if exists e_ins on expenses;
create policy e_ins on expenses for insert with check ((select is_admin()));
drop policy if exists e_upd on expenses;
create policy e_upd on expenses for update using ((select is_admin())) with check ((select is_admin()));
drop policy if exists pr_all on payroll;
create policy pr_all on payroll for all using ((select is_admin())) with check ((select is_admin()));

drop policy if exists n_sel on notices;
create policy n_sel on notices for select using (
  (select my_role()) is not null and not removed and ((select is_admin()) or class_id is null or class_id = (select my_class()) or kid_in_class(class_id)));
drop policy if exists n_ins on notices;
create policy n_ins on notices for insert with check (author_id = (select auth.uid()) and (
  (select is_admin()) or ((select my_role()) = 'teacher' and class_id is not null and class_id = (select my_class()))));
drop policy if exists n_upd on notices;
create policy n_upd on notices for update using ((select is_admin()) or author_id = (select auth.uid())) with check ((select is_admin()) or author_id = (select auth.uid()));

drop policy if exists d_sel on diary;
create policy d_sel on diary for select using ((select is_admin()) or class_id = (select my_class()) or (published and kid_in_class(class_id)));
drop policy if exists d_ins on diary;
create policy d_ins on diary for insert with check (author_id = (select auth.uid()) and ((select is_admin()) or ((select my_role()) = 'teacher' and class_id = (select my_class()))));
drop policy if exists d_upd on diary;
create policy d_upd on diary for update using ((select is_admin()) or ((select my_role()) = 'teacher' and class_id = (select my_class())))
  with check ((select is_admin()) or ((select my_role()) = 'teacher' and class_id = (select my_class())));

drop policy if exists al_ins on audit_log;
create policy al_ins on audit_log for insert with check (user_id = (select auth.uid()));
drop policy if exists al_sel on audit_log;
create policy al_sel on audit_log for select using ((select is_owner()));


-- ############################################################################
-- ##  PART 10 of 13: PATCH 9
-- ############################################################################

-- PATCH 9: phone notifications (works when the app is closed). Safe to run twice.
-- Run this in the SQL Editor. If Supabase warns "table without Row Level Security", choose "Run and enable RLS".
-- Both tables have RLS ON and NO policies: the app cannot read them; only the two functions below and the server function can.

create table if not exists push_subs(
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references profiles(id) on delete cascade,
  endpoint text unique not null,
  p256dh text not null,
  auth_key text not null,
  created_at timestamptz not null default now());
create index if not exists push_subs_user_idx on push_subs(user_id);
alter table push_subs enable row level security;

create table if not exists notif_log(
  kind text not null,
  key text not null,
  day date not null,
  created_at timestamptz not null default now(),
  primary key (kind, key, day));
alter table notif_log enable row level security;

-- a phone saves its own subscription (a shared phone moves to whoever signed in last)
create or replace function save_push_sub(p_endpoint text, p_p256dh text, p_auth text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null or not exists (select 1 from profiles where id = auth.uid() and active) then
    raise exception 'Not allowed';
  end if;
  if coalesce(p_endpoint,'') = '' or coalesce(p_p256dh,'') = '' or coalesce(p_auth,'') = '' then
    raise exception 'Bad subscription';
  end if;
  delete from push_subs where endpoint = p_endpoint;
  insert into push_subs(user_id, endpoint, p256dh, auth_key) values (auth.uid(), p_endpoint, p_p256dh, p_auth);
end $$;

create or replace function remove_push_sub(p_endpoint text)
returns void language plpgsql security definer set search_path = public as $$
begin
  delete from push_subs where endpoint = p_endpoint and user_id = auth.uid();
end $$;

revoke all on function save_push_sub(text, text, text) from public;
revoke all on function remove_push_sub(text) from public;
grant execute on function save_push_sub(text, text, text) to authenticated;
grant execute on function remove_push_sub(text) to authenticated;


-- ############################################################################
-- ##  PART 11 of 13: PATCH 10 SIMPLE LOGINS
-- ############################################################################

-- PATCH 10: simple logins.
--  * Parent username = the phone number itself (03001234567), no more "p" in front.
--  * Temporary password = ONE simple password for every new or reset login (set in _default_pw() below). Every user must replace it at first sign-in.
--  * Admin-typed temporary passwords may now be 6+ characters (the user still has to choose a strong own password at first sign-in).
-- Existing logins that start with "p" keep working and are recognised (no duplicate login is created for them).
-- Run once in the SQL Editor (after patches 1 to 5). Safe to run twice.

-- >>> THE ONE TEMPORARY PASSWORD FOR EVERY NEW OR RESET LOGIN. To use another one, change ONLY the word between the quotes below (6+ characters, no spaces).
create or replace function _default_pw() returns text language sql immutable as $$ select 'Names2026'::text $$;

-- shared rule for any temporary password typed or generated by the school
create or replace function _check_temp_pw(u text, pw text) returns void language plpgsql immutable as $$
begin
  if length(coalesce(pw,'')) < 6 then raise exception 'Temporary password needs at least 6 characters'; end if;
  if lower(pw) = u or position(u in lower(pw)) > 0 then raise exception 'Temporary password must not contain the username'; end if;
  if pw ~ '^(.)\1+$' or pw in ('123456','654321','012345','123123','password','qwerty') then raise exception 'Temporary password is too easy to guess'; end if;
end $$;

create or replace function create_school_user(
  p_username text, p_name text, p_role text, p_password text,
  p_phone text default null, p_class uuid default null, p_students uuid[] default '{}', p_salary int default null)
returns uuid language plpgsql security definer set search_path = public, auth, extensions as $$
declare uid uuid; em text; s uuid; u text := lower(trim(p_username));
begin
  if not is_admin() then raise exception 'Not allowed'; end if;
  if p_role not in ('manager','teacher','parent') then raise exception 'Role must be manager, teacher or parent'; end if;
  if p_role = 'manager' and not is_owner() then raise exception 'Only the owner can create managers'; end if;
  if u !~ '^[a-z0-9._]{3,30}$' then raise exception 'Username: 3 to 30 letters, digits, dot or underscore'; end if;
  perform _check_temp_pw(u, p_password);
  if coalesce(trim(p_name),'') = '' then raise exception 'Enter the name'; end if;
  if exists (select 1 from profiles where username = u) then raise exception 'This username is already taken'; end if;
  em := u || '@names.school'; uid := gen_random_uuid();
  insert into auth.users(instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,raw_app_meta_data,raw_user_meta_data,created_at,updated_at,confirmation_token,recovery_token,email_change_token_new,email_change)
  values ('00000000-0000-0000-0000-000000000000',uid,'authenticated','authenticated',em,crypt(p_password,gen_salt('bf')),now(),'{"provider":"email","providers":["email"]}','{}',now(),now(),'','','','');
  insert into auth.identities(id,user_id,provider_id,identity_data,provider,last_sign_in_at,created_at,updated_at)
  values (gen_random_uuid(),uid,uid::text,jsonb_build_object('sub',uid::text,'email',em,'email_verified',true),'email',now(),now(),now());
  insert into profiles(id,username,name,role,class_id,phone,salary,must_change)
  values (uid,u,trim(p_name),p_role,case when p_role='teacher' then p_class end,p_phone,p_salary,true);
  if p_role = 'teacher' and p_class is not null then
    update profiles set class_id = null where class_id = p_class and role = 'teacher' and id <> uid;
    update classes set teacher_id = uid where id = p_class;
  end if;
  if p_role = 'parent' then
    foreach s in array coalesce(p_students,'{}') loop
      insert into parent_students values (uid, s) on conflict do nothing;
    end loop;
  end if;
  insert into audit_log(user_id,action,detail) values (auth.uid(),'user.create',p_role || ' ' || u);
  return uid;
end $$;

create or replace function reset_school_password(p_username text, p_password text)
returns void language plpgsql security definer set search_path = public, auth, extensions as $$
declare t profiles; u text := lower(trim(p_username));
begin
  if not is_admin() then raise exception 'Not allowed'; end if;
  select * into t from profiles where username = u;
  if t.id is null then raise exception 'No such user'; end if;
  if t.role = 'admin' then raise exception 'The owner password cannot be reset here'; end if;
  if t.role = 'manager' and not is_owner() then raise exception 'Only the owner can reset a manager'; end if;
  perform _check_temp_pw(u, p_password);
  update auth.users set encrypted_password = crypt(p_password, gen_salt('bf')), updated_at = now() where id = t.id;
  update profiles set must_change = true where id = t.id;
  insert into audit_log(user_id,action,detail) values (auth.uid(),'user.reset_password',u);
end $$;

-- parent logins: username = phone number, temporary password = the school's one temporary password
create or replace function create_parent_logins()
returns table(login_name text, temp_password text, parent_name text, children_names text, parent_phone text)
language plpgsql security definer set search_path = public, auth, extensions as $$
declare r record; u text; pw text; pid uuid;
begin
  if not is_admin() then raise exception 'Not allowed'; end if;
  for r in
    select _norm_phone(s.phone) as d, (array_agg(s.father order by s.roll))[1] as fname,
           array_agg(s.id) as sids, string_agg(s.name, ', ' order by s.name) as names, min(s.phone) as ph
    from students s
    where s.status = 'Active' and s.phone is not null
      and length(_norm_phone(s.phone)) between 8 and 15
      and not exists (select 1 from parent_students ps where ps.student_id = s.id)
    group by _norm_phone(s.phone)
  loop
    u := r.d;
    -- a login in the new style (03001234567) or the old style (p03001234567) already exists: just link the children
    select id into pid from profiles where username in (u, 'p' || u) and role = 'parent' limit 1;
    if pid is not null then
      insert into parent_students select pid, x from unnest(r.sids) x on conflict do nothing;
      continue;
    end if;
    pw := _default_pw();
    perform create_school_user(u, r.fname, 'parent', pw, r.ph, null, r.sids);
    login_name := u; temp_password := pw; parent_name := r.fname; children_names := r.names; parent_phone := r.ph;
    return next;
  end loop;
end $$;

-- one-click reset (single login): back to the school's temporary password, user must choose their own at next sign-in
create or replace function reset_login_random(p_username text)
returns table(login_name text, temp_password text, parent_name text, children_names text)
language plpgsql security definer set search_path = public, auth, extensions as $$
declare u text := lower(trim(p_username)); pw text; t profiles;
begin
  if not is_admin() then raise exception 'Not allowed'; end if;
  select * into t from profiles where username = u;
  if t.id is null then raise exception 'No such user'; end if;
  pw := _default_pw();
  perform reset_school_password(u, pw);
  login_name := u; temp_password := pw; parent_name := t.name;
  children_names := (select string_agg(s.name, ', ' order by s.name) from parent_students ps join students s on s.id = ps.student_id where ps.parent_id = t.id);
  return next;
end $$;

revoke all on function _default_pw() from public;
revoke all on function _check_temp_pw(text,text) from public;
revoke all on function create_school_user(text,text,text,text,text,uuid,uuid[],int) from public;
revoke all on function reset_school_password(text,text) from public;
revoke all on function create_parent_logins() from public;
revoke all on function reset_login_random(text) from public;
grant execute on function create_school_user(text,text,text,text,text,uuid,uuid[],int) to authenticated;
grant execute on function reset_school_password(text,text) to authenticated;
grant execute on function create_parent_logins() to authenticated;
grant execute on function reset_login_random(text) to authenticated;


-- ############################################################################
-- ##  PART 12 of 13: PATCH 12 HARDENING + SYSTEM CHECK
-- ############################################################################


-- 0) BUG FIX: nobody could remove a notice (not even the owner). "Removing" sets removed = true, but the read rule only allowed
--    rows with removed = false, and PostgreSQL also checks the NEW row against the read rule, so the save was refused.
--    Admins and the author may now still read a removed notice (the app does not list removed notices).
drop policy if exists n_sel on notices;
create policy n_sel on notices for select using (
  (select my_role()) is not null and (
    (select is_admin()) or author_id = (select auth.uid())
    or (not removed and (class_id is null or class_id = (select my_class()) or kid_in_class(class_id)))));

-- 1) notices: a teacher may only edit/remove HIS OWN notices and cannot change the class of a notice
drop policy if exists n_upd on notices;
create policy n_upd on notices for update
  using ((select my_role()) is not null and ((select is_admin()) or author_id = (select auth.uid())))
  with check ((select my_role()) is not null and ((select is_admin()) or (
        author_id = (select auth.uid()) and (select my_role()) = 'teacher'
        and class_id is not null and class_id = (select my_class()))));

-- 2) profiles: role and username are fixed once created; a manager row can be changed by the owner (or by the person himself)
create or replace function profiles_guard() returns trigger language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is not null then          -- the SQL Editor (no signed-in user) may still repair anything
    if new.role is distinct from old.role then raise exception 'A login role cannot be changed. Create a new login instead.'; end if;
    if new.username is distinct from old.username then raise exception 'A username cannot be changed'; end if;
    if old.role = 'manager' and auth.uid() <> old.id and not is_owner() then raise exception 'Only the owner can change a manager'; end if;
  end if;
  return new;
end $$;
drop trigger if exists profiles_guard_trg on profiles;
create trigger profiles_guard_trg before update on profiles for each row execute function profiles_guard();

-- 3) patch log
create table if not exists app_patches(
  name text primary key,
  note text,
  applied_at timestamptz not null default now());
alter table app_patches enable row level security;
drop policy if exists ap_sel on app_patches;
create policy ap_sel on app_patches for select using ((select is_owner()));
insert into app_patches(name, note) values ('patch-12', 'hardening + system check') on conflict do nothing;

-- 4) System check (owner / manager): one row per check, ok = false means something needs attention
create or replace function school_health()
returns table(check_name text, ok boolean, detail text)
language plpgsql stable security definer set search_path = public as $$
declare t text; n int; f text;
begin
  if not is_admin() then raise exception 'Not allowed'; end if;

  foreach t in array array['profiles','classes','students','parent_students','attendance','attendance_final','fees','expenses','notices','diary','payroll','audit_log','push_subs','notif_log','app_patches'] loop
    check_name := 'Table ' || t;
    if to_regclass('public.' || t) is null then ok := false; detail := 'MISSING';
    else
      select c.relrowsecurity into ok from pg_class c where c.oid = to_regclass('public.' || t);
      select count(*) into n from pg_policies p where p.schemaname = 'public' and p.tablename = t;
      if t in ('push_subs','notif_log') then detail := case when ok then 'security ON (no policies on purpose)' else 'ROW SECURITY IS OFF' end;
      else ok := ok and n > 0; detail := case when not ok then 'ROW SECURITY OFF OR NO RULES' else n || ' security rules' end; end if;
    end if;
    return next;
  end loop;

  check_name := 'Diary due date column (patch 6)';
  ok := exists (select 1 from information_schema.columns where table_schema='public' and table_name='diary' and column_name='due'); detail := case when ok then 'present' else 'MISSING: run patch 6' end; return next;
  check_name := 'Student withdrawal columns (patch 7)';
  ok := exists (select 1 from information_schema.columns where table_schema='public' and table_name='students' and column_name='left_date'); detail := case when ok then 'present' else 'MISSING: run patch 7' end; return next;

  foreach f in array array['create_school_user(text,text,text,text,text,uuid,uuid[],integer)','reset_school_password(text,text)','create_parent_logins()','list_logins()','reset_login_random(text)','delete_students(uuid[])','delete_school_user(text)','save_push_sub(text,text,text)','password_changed()'] loop
    check_name := 'Function ' || split_part(f, '(', 1);
    ok := to_regprocedure('public.' || f) is not null; detail := case when ok then 'present' else 'MISSING' end; return next;
  end loop;

  check_name := 'Owner login';
  select count(*) into n from profiles where role = 'admin' and active; ok := n = 1; detail := n || ' active owner(s)'; return next;

  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    foreach t in array array['attendance','attendance_final','fees','notices','diary'] loop
      check_name := 'Live updates: ' || t;
      ok := exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = t);
      detail := case when ok then 'on' else 'OFF (screens will not refresh by themselves)' end; return next;
    end loop;
  end if;

  check_name := 'Notification clock (patch 9b)';
  begin
    if to_regclass('cron.job') is null then ok := false; detail := 'not set up (patch 9b not run): phone notifications will not be sent';
    else execute 'select count(*) from cron.job where jobname = ''school-notify''' into n; ok := n > 0;
         detail := case when ok then 'scheduled' else 'not scheduled (patch 9b not run): phone notifications will not be sent' end; end if;
  exception when others then ok := false; detail := 'could not be checked'; end;
  return next;

  check_name := 'Patches recorded';
  ok := true; select coalesce(string_agg(a.name, ', ' order by a.name), 'none') into detail from app_patches a; return next;
end $$;
revoke all on function school_health() from public;
grant execute on function school_health() to authenticated;

-- 5) (live updates are switched on in part 13 below) only "already added" is ignored; any other problem is shown as a warning
do $$ declare t text; begin
  foreach t in array array['attendance','attendance_final','fees','notices','diary'] loop
    begin execute format('alter publication supabase_realtime add table public.%I', t);
    exception when duplicate_object then null;
              when others then raise warning 'Live updates could not be switched on for %: %', t, sqlerrm; end;
  end loop;
end $$;


-- patches contained in this file
insert into app_patches(name, note) values
  ('patch-1','attendance rule'),('patch-2','create logins'),('patch-3','parent logins'),('patch-4','sign-up lock'),('patch-5','logins list'),
  ('patch-6','Pakistan dates + diary due date'),('patch-7','withdrawal + deletes'),('patch-8','speed'),('patch-9','phone notifications tables'),
  ('patch-10','simple logins'),('setup-file','all-in-one, with results')
on conflict do nothing;


-- ############################################################################
-- ##  PART 13 of 15: LIVE UPDATES (attendance, fees, notices and diary appear on phones without refresh)
-- ############################################################################
do $$ declare t text; begin
  foreach t in array array['attendance','attendance_final','fees','notices','diary'] loop
    begin execute format('alter publication supabase_realtime add table public.%I', t);
    exception when duplicate_object then null;
              when others then raise warning 'Live updates could not be switched on for %: %', t, sqlerrm; end;
  end loop;
end $$;

-- ############################################################################
-- ##  PART 14 of 15: TESTS & RESULTS (patch 11)
-- ############################################################################
-- PATCH 11: Tests and Results.
create table if not exists exams(
  id uuid primary key default gen_random_uuid(),
  class_id uuid not null references classes(id) on delete cascade,
  name text not null check (length(trim(name)) between 1 and 80),
  subject text not null check (length(trim(subject)) between 1 and 60),
  total_marks numeric(7,2) not null check (total_marks > 0 and total_marks <= 1000),
  exam_date date not null,
  published boolean not null default false,
  created_by uuid references profiles(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now());
create index if not exists exams_class_idx on exams(class_id, exam_date);

create table if not exists exam_marks(
  exam_id uuid not null references exams(id) on delete cascade,
  student_id uuid not null references students(id) on delete cascade,
  marks numeric(7,2) check (marks >= 0),
  absent boolean not null default false,
  entered_by uuid references profiles(id),
  updated_at timestamptz not null default now(),
  primary key (exam_id, student_id),
  check (not (absent and marks is not null)),
  check (absent or marks is not null));
create index if not exists exam_marks_student_idx on exam_marks(student_id);

alter table exams enable row level security;
alter table exam_marks enable row level security;

create or replace function exam_class(eid uuid) returns uuid language sql stable security definer set search_path = public as
$$ select class_id from exams where id = eid $$;
create or replace function exam_is_published(eid uuid) returns boolean language sql stable security definer set search_path = public as
$$ select coalesce((select published from exams where id = eid), false) $$;
create or replace function exam_has_my_kid(eid uuid) returns boolean language sql stable security definer set search_path = public as
$$ select my_role() = 'parent' and exists(select 1 from exam_marks m where m.exam_id = eid and is_my_kid(m.student_id)) $$;

drop policy if exists ex_sel on exams;
create policy ex_sel on exams for select using (
  is_admin() or (my_role() = 'teacher' and class_id = my_class()) or (published and exam_has_my_kid(id)));
drop policy if exists ex_ins on exams;
create policy ex_ins on exams for insert with check (
  created_by = auth.uid() and (is_admin() or (my_role() = 'teacher' and class_id = my_class())));
drop policy if exists ex_upd on exams;
create policy ex_upd on exams for update
  using (is_admin() or (my_role() = 'teacher' and class_id = my_class()))
  with check (is_admin() or (my_role() = 'teacher' and class_id = my_class()));
drop policy if exists ex_del on exams;
create policy ex_del on exams for delete using (
  is_admin() or (my_role() = 'teacher' and class_id = my_class() and not published));

drop policy if exists em_sel on exam_marks;
create policy em_sel on exam_marks for select using (
  is_admin() or (my_role() = 'teacher' and exam_class(exam_id) = my_class())
  or (is_my_kid(student_id) and exam_is_published(exam_id)));
drop policy if exists em_ins on exam_marks;
create policy em_ins on exam_marks for insert with check (
  entered_by = auth.uid() and (is_admin() or (my_role() = 'teacher' and exam_class(exam_id) = my_class())));
drop policy if exists em_upd on exam_marks;
create policy em_upd on exam_marks for update
  using (is_admin() or (my_role() = 'teacher' and exam_class(exam_id) = my_class()))
  with check (is_admin() or (my_role() = 'teacher' and exam_class(exam_id) = my_class()));
drop policy if exists em_del on exam_marks;
create policy em_del on exam_marks for delete using (
  is_admin() or (my_role() = 'teacher' and exam_class(exam_id) = my_class()));

create or replace function check_exam_marks() returns trigger language plpgsql security definer set search_path = public as $$
declare t numeric; c uuid; sc uuid;
begin
  select total_marks, class_id into t, c from exams where id = new.exam_id;
  select class_id into sc from students where id = new.student_id;
  if sc is distinct from c then raise exception 'This student is not in the class of this test'; end if;
  if new.marks is not null and new.marks > t then raise exception 'Marks (%) cannot be more than the total marks (%)', new.marks, t; end if;
  new.updated_at := now();
  return new;
end $$;
drop trigger if exists exam_marks_check on exam_marks;
create trigger exam_marks_check before insert or update on exam_marks for each row execute function check_exam_marks();

create or replace function check_exam_change() returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.total_marks < old.total_marks and exists (select 1 from exam_marks where exam_id = new.id and marks > new.total_marks) then
    raise exception 'Some students already have more marks than the new total. Correct their marks first.';
  end if;
  if new.class_id <> old.class_id and exists (select 1 from exam_marks where exam_id = new.id) then
    raise exception 'The class of a test with marks cannot be changed';
  end if;
  new.updated_at := now();
  return new;
end $$;
drop trigger if exists exams_change on exams;
create trigger exams_change before update on exams for each row execute function check_exam_change();

do $$ declare t text; begin
  foreach t in array array['exams','exam_marks'] loop
    begin execute format('alter publication supabase_realtime add table public.%I', t);
    exception when others then null; end;
  end loop;
end $$;
insert into app_patches(name, note) values ('patch-11','tests and results') on conflict do nothing;

-- ############################################################################
-- ##  PART 15: SECURITY HARDENING (patch 13)
-- ############################################################################
-- ============================================================================
-- PATCH 13: SECURITY HARDENING. Run once in the SQL Editor (safe to run twice). Take a backup first.
-- Fixes:
--  1) No more shared temporary password: every new / reset login gets its OWN random password (shown once on the slip).
--  2) A login that still has a temporary password ("must change") can read and write NOTHING until the user has chosen his own password
--     (before, this was only checked on the screen).
--  3) Private helper functions are no longer callable by the public / anonymous key.
--  4) The database itself now writes audit lines (db.*) for money, salary, status and marks changes: they cannot be skipped by calling the API directly.
--  5) An expense can no longer be edited (only voided); nobody can un-void it.
--  6) A manager can no longer change his own salary / status / class, and only the owner can change a manager's salary.
--  7) A teacher can mark attendance only for today (and yesterday for the clock edge), and only in his own name.
--  8) A teacher can no longer change or delete marks of a PUBLISHED test (hide it from parents first; every change is logged).
--  9) A manager can no longer reset a teacher password (only the owner). A manager can still reset parents.
-- 10) System check knows about the new rules.
-- ============================================================================

-- ---------- 1) random temporary passwords ----------
create or replace function _random_pw() returns text language sql volatile security definer set search_path = public, extensions as
$$ select _rnd('ABCDEFGHJKMNPQRSTUVWXYZ', 2) || _rnd('abcdefghjkmnpqrstuvwxyz', 6) || _rnd('23456789', 3) $$;

create or replace function create_parent_logins()
returns table(login_name text, temp_password text, parent_name text, children_names text, parent_phone text)
language plpgsql security definer set search_path = public, auth, extensions as $$
declare r record; u text; pw text; pid uuid;
begin
  if not is_admin() then raise exception 'Not allowed'; end if;
  for r in
    select _norm_phone(s.phone) as d, (array_agg(s.father order by s.roll))[1] as fname,
           array_agg(s.id) as sids, string_agg(s.name, ', ' order by s.name) as names, min(s.phone) as ph
    from students s
    where s.status = 'Active' and s.phone is not null
      and length(_norm_phone(s.phone)) between 8 and 15
      and not exists (select 1 from parent_students ps where ps.student_id = s.id)
    group by _norm_phone(s.phone)
  loop
    u := r.d;
    select id into pid from profiles where username in (u, 'p' || u) and role = 'parent' limit 1;
    if pid is not null then
      insert into parent_students select pid, x from unnest(r.sids) x on conflict do nothing;
      continue;
    end if;
    pw := _random_pw();
    perform create_school_user(u, r.fname, 'parent', pw, r.ph, null, r.sids);
    login_name := u; temp_password := pw; parent_name := r.fname; children_names := r.names; parent_phone := r.ph;
    return next;
  end loop;
end $$;

create or replace function reset_login_random(p_username text)
returns table(login_name text, temp_password text, parent_name text, children_names text)
language plpgsql security definer set search_path = public, auth, extensions as $$
declare u text := lower(trim(p_username)); pw text; t profiles; tries int := 0; ok boolean := false;
begin
  if not is_admin() then raise exception 'Not allowed'; end if;
  select * into t from profiles where username = u;
  if t.id is null then raise exception 'No such user'; end if;
  while not ok loop
    tries := tries + 1;
    pw := _random_pw();
    begin
      perform reset_school_password(u, pw); ok := true;
    exception when others then
      -- only a password that happens to contain the username is worth retrying; permission errors must surface
      if sqlerrm not like 'Temporary password%' or tries >= 8 then raise; end if;
    end;
  end loop;
  login_name := u; temp_password := pw; parent_name := t.name;
  children_names := (select string_agg(s.name, ', ' order by s.name) from parent_students ps join students s on s.id = ps.student_id where ps.parent_id = t.id);
  return next;
end $$;

-- 9) password reset: owner for everyone; a manager only for parents
create or replace function reset_school_password(p_username text, p_password text)
returns void language plpgsql security definer set search_path = public, auth, extensions as $$
declare t profiles; u text := lower(trim(p_username));
begin
  if not is_admin() then raise exception 'Not allowed'; end if;
  select * into t from profiles where username = u;
  if t.id is null then raise exception 'No such user'; end if;
  if t.role = 'admin' then raise exception 'The owner password cannot be reset here'; end if;
  if t.role = 'manager' and not is_owner() then raise exception 'Only the owner can reset a manager'; end if;
  if t.role = 'teacher' and not is_owner() then raise exception 'Only the owner can reset a teacher password'; end if;
  perform _check_temp_pw(u, p_password);
  update auth.users set encrypted_password = crypt(p_password, gen_salt('bf')), updated_at = now() where id = t.id;
  update profiles set must_change = true where id = t.id;
  insert into audit_log(user_id,action,detail) values (auth.uid(),'user.reset_password',u);
end $$;

drop function if exists _default_pw();

-- ---------- 2) "must change password" is enforced by the database ----------
create or replace function my_role() returns text language sql stable security definer set search_path = public as
$$ select role from profiles where id = auth.uid() and active and not must_change $$;
create or replace function my_class() returns uuid language sql stable security definer set search_path = public as
$$ select class_id from profiles where id = auth.uid() and active and not must_change $$;

-- ---------- 3) private helpers are not callable from outside ----------
do $$ declare f text; begin
  foreach f in array array['_rnd(text,integer)','_random_pw()','_check_temp_pw(text,text)'] loop
    execute format('revoke all on function %s from public, anon, authenticated', f);
  end loop;
  foreach f in array array['is_finalized(uuid,date)','exam_class(uuid)','exam_is_published(uuid)','exam_has_my_kid(uuid)'] loop
    execute format('revoke all on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated', f);
  end loop;
  begin
    execute 'alter default privileges in schema public revoke execute on functions from anon';
  exception when others then raise notice 'default privileges not changed: %', sqlerrm; end;
end $$;

-- ---------- 4) database-written audit lines ----------
create or replace function audit_db() returns trigger language plpgsql security definer set search_path = public as $$
declare a text; d text;
begin
  if auth.uid() is null then if tg_op = 'DELETE' then return old; end if; return new; end if;
  if tg_table_name = 'expenses' then
    if tg_op = 'INSERT' then a := 'db.expense.add'; d := new.category || ' ' || new.amount || ' ' || new.day;
    elsif new.voided and not old.voided then a := 'db.expense.void'; d := old.category || ' ' || old.amount || ' | ' || coalesce(new.void_reason, '');
    else return new; end if;
  elsif tg_table_name = 'fees' then
    a := 'db.fee.' || new.kind; d := new.receipt || ' ' || new.amount || ' ' || new.month || ' student ' || new.student_id;
  elsif tg_table_name = 'students' then
    if new.monthly_fee is distinct from old.monthly_fee then a := 'db.student.fee'; d := old.name || ' ' || old.monthly_fee || ' -> ' || new.monthly_fee;
    elsif new.status is distinct from old.status then a := 'db.student.status'; d := old.name || ' ' || old.status || ' -> ' || new.status;
    else return new; end if;
  elsif tg_table_name = 'profiles' then
    if new.salary is distinct from old.salary then a := 'db.user.salary'; d := old.username || ' ' || coalesce(old.salary::text, '-') || ' -> ' || coalesce(new.salary::text, '-');
    elsif new.active is distinct from old.active then a := 'db.user.active'; d := old.username || ' ' || old.active || ' -> ' || new.active;
    else return new; end if;
  elsif tg_table_name = 'payroll' then
    if tg_op = 'DELETE' then a := 'db.payroll.delete'; d := old.month || ' teacher ' || old.teacher_id || ' basic ' || old.basic;
    else a := 'db.payroll.' || lower(tg_op); d := new.month || ' teacher ' || new.teacher_id || ' basic ' || new.basic || ' bonus ' || new.bonus || ' deduction ' || new.deduction || ' ' || new.status; end if;
  elsif tg_table_name = 'exams' then
    if new.published is distinct from old.published then
      a := case when new.published then 'db.exam.publish' else 'db.exam.unpublish' end; d := new.subject || ' ' || new.name;
    else return new; end if;
  elsif tg_table_name = 'exam_marks' then
    if tg_op = 'DELETE' then
      if exam_is_published(old.exam_id) then a := 'db.marks.delete'; d := 'exam ' || old.exam_id || ' student ' || old.student_id || ' was ' || coalesce(old.marks::text, 'absent');
      else return old; end if;
    else
      if new.marks is not distinct from old.marks and new.absent is not distinct from old.absent then return new; end if;
      if exam_is_published(new.exam_id) then
        a := 'db.marks.change';
        d := 'exam ' || new.exam_id || ' student ' || new.student_id || ' ' || coalesce(old.marks::text, case when old.absent then 'absent' else '-' end) || ' -> ' || coalesce(new.marks::text, case when new.absent then 'absent' else '-' end);
      else return new; end if;
    end if;
  else
    if tg_op = 'DELETE' then return old; end if; return new;
  end if;
  insert into audit_log(user_id, action, detail) values (auth.uid(), a, left(d, 400));
  if tg_op = 'DELETE' then return old; end if;
  return new;
end $$;
revoke all on function audit_db() from public, anon, authenticated;

drop trigger if exists audit_expenses on expenses;
create trigger audit_expenses after insert or update on expenses for each row execute function audit_db();
drop trigger if exists audit_fees on fees;
create trigger audit_fees after insert on fees for each row execute function audit_db();
drop trigger if exists audit_students on students;
create trigger audit_students after update on students for each row execute function audit_db();
drop trigger if exists audit_profiles on profiles;
create trigger audit_profiles after update on profiles for each row execute function audit_db();
drop trigger if exists audit_payroll on payroll;
create trigger audit_payroll after insert or update or delete on payroll for each row execute function audit_db();
do $$ begin
  if to_regclass('public.exams') is not null then
    execute 'drop trigger if exists audit_exams on exams';
    execute 'create trigger audit_exams after update on exams for each row execute function audit_db()';
    execute 'drop trigger if exists audit_exam_marks on exam_marks';
    execute 'create trigger audit_exam_marks after update or delete on exam_marks for each row execute function audit_db()';
  end if;
end $$;

-- ---------- 5) expenses cannot be edited, only voided ----------
create or replace function expenses_guard() returns trigger language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is not null then
    if new.amount is distinct from old.amount or new.day is distinct from old.day or new.category is distinct from old.category
       or new.payee is distinct from old.payee or new.method is distinct from old.method or new.ref is distinct from old.ref then
      raise exception 'An expense cannot be edited. Void it (with a reason) and add a new one.';
    end if;
    if old.voided and not new.voided then raise exception 'A voided expense cannot be brought back. Add a new one.'; end if;
  end if;
  return new;
end $$;
revoke all on function expenses_guard() from public, anon, authenticated;
drop trigger if exists expenses_guard_trg on expenses;
create trigger expenses_guard_trg before update on expenses for each row execute function expenses_guard();

-- ---------- 6) profile guard: no self-promotion, flag can only be cleared by the person himself ----------
create or replace function profiles_guard() returns trigger language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is not null then          -- the SQL Editor (no signed-in user) may still repair anything
    if new.role is distinct from old.role then raise exception 'A login role cannot be changed. Create a new login instead.'; end if;
    if new.username is distinct from old.username then raise exception 'A username cannot be changed'; end if;
    if old.role = 'manager' and auth.uid() <> old.id and not is_owner() then raise exception 'Only the owner can change a manager'; end if;
    if old.role = 'manager' and new.salary is distinct from old.salary and not is_owner() then raise exception 'Only the owner can change a manager salary'; end if;
    if old.id = auth.uid() and not is_owner()
       and (new.salary is distinct from old.salary or new.active is distinct from old.active or new.class_id is distinct from old.class_id) then
      raise exception 'You cannot change your own salary, status or class';
    end if;
    if old.must_change and not new.must_change and old.id <> auth.uid() then
      raise exception 'Only the person himself can finish the password change';
    end if;
  end if;
  return new;
end $$;

-- ---------- 7) teacher attendance: only today, only in his own name ----------
create or replace function pk_today() returns date language sql stable as $$ select (now() at time zone 'Asia/Karachi')::date $$;
drop policy if exists a_ins on attendance;
create policy a_ins on attendance for insert with check (
  (select is_admin()) or ((select my_role()) = 'teacher' and can_see_student(student_id) and not is_finalized(student_id, day)
    and day between pk_today() - 1 and pk_today() and marked_by = (select auth.uid())));
drop policy if exists a_upd on attendance;
create policy a_upd on attendance for update
  using ((select is_admin()) or ((select my_role()) = 'teacher' and can_see_student(student_id) and not is_finalized(student_id, day)
    and day between pk_today() - 1 and pk_today()))
  with check ((select is_admin()) or ((select my_role()) = 'teacher' and can_see_student(student_id) and not is_finalized(student_id, day)
    and day between pk_today() - 1 and pk_today() and marked_by = (select auth.uid())));

-- ---------- 8) marks of a published test are locked for teachers ----------
do $$ begin
  if to_regclass('public.exam_marks') is not null then
    execute 'drop policy if exists em_ins on exam_marks';
    execute $p$create policy em_ins on exam_marks for insert with check (
      entered_by = (select auth.uid()) and ((select is_admin()) or ((select my_role()) = 'teacher' and exam_class(exam_id) = (select my_class()) and not exam_is_published(exam_id))))$p$;
    execute 'drop policy if exists em_upd on exam_marks';
    execute $p$create policy em_upd on exam_marks for update
      using ((select is_admin()) or ((select my_role()) = 'teacher' and exam_class(exam_id) = (select my_class()) and not exam_is_published(exam_id)))
      with check ((select is_admin()) or ((select my_role()) = 'teacher' and exam_class(exam_id) = (select my_class()) and not exam_is_published(exam_id)))$p$;
    execute 'drop policy if exists em_del on exam_marks';
    execute $p$create policy em_del on exam_marks for delete using (
      (select is_admin()) or ((select my_role()) = 'teacher' and exam_class(exam_id) = (select my_class()) and not exam_is_published(exam_id)))$p$;
  end if;
end $$;

-- ---------- 10) System check (owner / manager) ----------
create or replace function school_health()
returns table(check_name text, ok boolean, detail text)
language plpgsql stable security definer set search_path = public as $$
declare t text; n int; f text;
begin
  if not is_admin() then raise exception 'Not allowed'; end if;

  foreach t in array array['profiles','classes','students','parent_students','attendance','attendance_final','fees','expenses','notices','diary','payroll','audit_log','push_subs','notif_log','app_patches','exams','exam_marks'] loop
    check_name := 'Table ' || t;
    if to_regclass('public.' || t) is null then ok := false; detail := case when t in ('exams','exam_marks') then 'MISSING: run patch 11 (results)' else 'MISSING' end;
    else
      select c.relrowsecurity into ok from pg_class c where c.oid = to_regclass('public.' || t);
      select count(*) into n from pg_policies p where p.schemaname = 'public' and p.tablename = t;
      if t in ('push_subs','notif_log') then detail := case when ok then 'security ON (no policies on purpose)' else 'ROW SECURITY IS OFF' end;
      else ok := ok and n > 0; detail := case when not ok then 'ROW SECURITY OFF OR NO RULES' else n || ' security rules' end; end if;
    end if;
    return next;
  end loop;

  check_name := 'Diary due date column (patch 6)';
  ok := exists (select 1 from information_schema.columns where table_schema='public' and table_name='diary' and column_name='due'); detail := case when ok then 'present' else 'MISSING: run patch 6' end; return next;
  check_name := 'Student withdrawal columns (patch 7)';
  ok := exists (select 1 from information_schema.columns where table_schema='public' and table_name='students' and column_name='left_date'); detail := case when ok then 'present' else 'MISSING: run patch 7' end; return next;

  foreach f in array array['create_school_user(text,text,text,text,text,uuid,uuid[],integer)','reset_school_password(text,text)','create_parent_logins()','list_logins()','reset_login_random(text)','delete_students(uuid[])','delete_school_user(text)','save_push_sub(text,text,text)','remove_push_sub(text)','password_changed()','school_health()','audit_db()','pk_today()'] loop
    check_name := 'Function ' || split_part(f, '(', 1);
    ok := to_regprocedure('public.' || f) is not null; detail := case when ok then 'present' else 'MISSING' end; return next;
  end loop;

  check_name := 'Owner login';
  select count(*) into n from profiles where role = 'admin' and active; ok := n = 1; detail := n || ' active owner(s)'; return next;

  check_name := 'No shared temporary password (patch 13)';
  ok := to_regprocedure('public._default_pw()') is null; detail := case when ok then 'every login gets its own random password' else 'STILL SHARED: run patch 13' end; return next;
  check_name := 'Password change enforced by database (patch 13)';
  ok := position('must_change' in coalesce((select prosrc from pg_proc where proname = 'my_role' and pronamespace = 'public'::regnamespace limit 1), '')) > 0;
  detail := case when ok then 'on' else 'OFF: run patch 13' end; return next;
  check_name := 'Private functions closed to the public key (patch 13)';
  begin
    ok := not has_function_privilege('anon', 'public.is_finalized(uuid,date)', 'execute');
    detail := case when ok then 'closed' else 'OPEN: run patch 13' end;
  exception when others then ok := true; detail := 'could not be checked'; end;
  return next;
  check_name := 'Database audit lines (patch 13)';
  ok := exists (select 1 from pg_trigger where tgname = 'audit_expenses' and not tgisinternal); detail := case when ok then 'on' else 'OFF: run patch 13' end; return next;

  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    foreach t in array array['attendance','attendance_final','fees','notices','diary'] loop
      check_name := 'Live updates: ' || t;
      ok := exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = t);
      detail := case when ok then 'on' else 'OFF (screens will not refresh by themselves)' end; return next;
    end loop;
  end if;

  check_name := 'Notification clock (patch 9b)';
  begin
    if to_regclass('cron.job') is null then ok := false; detail := 'not set up (patch 9b not run): phone notifications will not be sent';
    else execute 'select count(*) from cron.job where jobname = ''school-notify''' into n; ok := n > 0;
         detail := case when ok then 'scheduled' else 'not scheduled (patch 9b not run): phone notifications will not be sent' end; end if;
  exception when others then ok := false; detail := 'could not be checked'; end;
  return next;

  check_name := 'Patches recorded';
  ok := true; select coalesce(string_agg(a.name, ', ' order by a.name), 'none') into detail from app_patches a; return next;
end $$;
revoke all on function school_health() from public;
grant execute on function school_health() to authenticated;

insert into app_patches(name, note) values ('patch-13', 'security hardening') on conflict do nothing;

-- Done. Next: run OWNER-first-login.sql, then turn OFF "Allow new users to sign up" in Authentication.
-- Then open the app as the owner and press "System check" (Backup page): every line should say OK.


-- ############################################################################
-- PATCH 14: RESULTS: Term for every test (First Term / Second Term / Final Term)
-- ############################################################################
alter table exams add column if not exists term text
  check (term is null or term in ('First Term','Second Term','Final Term'));
create index if not exists exams_class_term_idx on exams(class_id, term);
insert into app_patches(name, note) values ('patch-14','results term') on conflict do nothing;

-- ############################################################################
-- FINAL CHECK (read the result table at the bottom)
-- ############################################################################
select
  (select count(*) from pg_tables where schemaname='public')                                  as tables,
  (select count(*) from pg_tables where schemaname='public' and rowsecurity)                  as tables_with_rls,
  (select count(*) from pg_policies where schemaname='public')                                as policies,
  (select count(*) from information_schema.columns where table_schema='public' and table_name='exams' and column_name='term') as exams_term_column,
  (select string_agg(name, ', ' order by name) from app_patches)                              as patches_recorded;
-- Expected: tables = tables_with_rls, exams_term_column = 1, patches include patch-14.
