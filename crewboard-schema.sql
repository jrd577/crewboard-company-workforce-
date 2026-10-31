-- =====================================================================================
-- Crewboard: full database schema (Supabase / Postgres)
-- Rebuilt from the Crewboard page code plus the payments setup. Safe to run more than once.
--
-- IMPORTANT: your original tables were created before this file existed, so the column
-- types below are a best reconstruction. Do not run it over your live database expecting
-- it to change existing columns: every statement is "if not exists", so it only fills gaps.
-- Row-level security rules for workers, suppliers, projects, positions, assignments and
-- supplies are NOT included, because I cannot see them. Export yours and add them here:
--   select schemaname, tablename, policyname, cmd, roles, qual, with_check
--   from pg_policies where schemaname = 'public' order by tablename, policyname;
-- =====================================================================================

-- Part 1: core tables -------------------------------------------------------------------

-- managers: users allowed to see the manager dashboard and payments
create table if not exists public.managers (
  user_id uuid primary key
);

-- workers: id is the person's sign-in user id
create table if not exists public.workers (
  id          uuid primary key,
  name        text,
  dept        text,
  title       text,
  phone       text,
  years       numeric,
  rate        numeric,
  rate_unit   text,          -- hour | day | week | month
  area        text,
  skills      text,
  available   boolean default true,
  updated_at  timestamptz,
  created_at  timestamptz default now()
);

-- suppliers: id is the supplier's sign-in user id
create table if not exists public.suppliers (
  id          uuid primary key,
  company     text,
  contact     text,
  phone       text,
  category    text,
  area        text,
  items       jsonb,         -- list of {name, unit, price}
  updated_at  timestamptz,
  created_at  timestamptz default now()
);

create table if not exists public.projects (
  id          uuid primary key default gen_random_uuid(),
  name        text,
  client      text,
  site        text,
  source      text,
  start_date  date,
  end_date    date,
  status      text,          -- active | done
  created_at  timestamptz default now()
);

-- positions: custom departments and level overrides; ids can be text such as "lvl-engineers"
create table if not exists public.positions (
  id          text primary key,
  kind        text,
  dept        text,
  name        text,
  hint        text,
  division    text,
  level       integer,
  created_at  timestamptz default now()
);

-- assignments: a worker on a project. Released rows are kept (released_at) so the days
-- worked can still be paid.
create table if not exists public.assignments (
  id          uuid primary key default gen_random_uuid(),
  worker_id   uuid not null,
  project_id  uuid not null,
  since       timestamptz,
  assigned_by uuid,
  released_at timestamptz
);

-- supplier orders. delivered_at is set when the order is marked Delivered.
create table if not exists public.supplies (
  id          uuid primary key default gen_random_uuid(),
  supplier_id uuid,
  project_id  uuid,
  amount      numeric,
  deliver     text,
  due         date,
  status      text,          -- ordered | delivered
  assigned_by uuid,
  created_at  timestamptz default now(),
  delivered_at timestamptz
);

-- Part 2: payments (identical to payments.sql) ---------------------------------------------

-- Crewboard payments setup. Run ONCE in Supabase: SQL Editor > New query > paste all > Run.
-- Run this BEFORE opening the new manager page. It is safe to run again.

-- 1. Assignments keep a record when someone is released -------------------------------
alter table public.assignments add column if not exists id uuid default gen_random_uuid();
update public.assignments set id = gen_random_uuid() where id is null;
alter table public.assignments alter column id set not null;
alter table public.assignments add column if not exists released_at timestamptz;

do $$
declare pk text;
begin
  select conname into pk from pg_constraint
   where conrelid = 'public.assignments'::regclass and contype = 'p';
  if pk is not null then
    execute format('alter table public.assignments drop constraint %I', pk);
  end if;
  if not exists (select 1 from pg_constraint where conrelid = 'public.assignments'::regclass and contype = 'p') then
    alter table public.assignments add primary key (id);
  end if;
end $$;

-- a worker can be on a project once at a time, but can be re-assigned after release
create unique index if not exists assignments_one_active
  on public.assignments (worker_id, project_id) where released_at is null;

-- 2. Supplier orders record the delivery date ------------------------------------------
alter table public.supplies add column if not exists delivered_at timestamptz;

-- 3. Hours entered by the manager for hourly workers ----------------------------------
create table if not exists public.work_hours (
  worker_id  uuid not null,
  work_date  date not null,
  hours      numeric not null check (hours >= 0 and hours <= 24),
  updated_at timestamptz default now(),
  primary key (worker_id, work_date)
);

-- 4. Saved payment batches and their lines ---------------------------------------------
create table if not exists public.pay_batches (
  id         uuid primary key default gen_random_uuid(),
  kind       text not null check (kind in ('worker','supplier')),
  number     text not null,
  scope      text,
  as_of      date,
  total      numeric not null default 0,
  line_count integer not null default 0,
  created_by uuid,
  created_at timestamptz default now()
);
create unique index if not exists pay_batches_number_uq on public.pay_batches (number);

create table if not exists public.pay_lines (
  id            uuid primary key default gen_random_uuid(),
  batch_id      uuid not null,
  kind          text not null check (kind in ('worker','supplier')),
  worker_id     uuid,
  supplier_id   uuid,
  project_id    uuid,
  supply_id     uuid,
  name          text,
  phone         text,
  dept_name     text,
  category      text,
  title         text,
  project_names text,
  items_text    text,
  rate          numeric,
  unit          text,
  period_from   date,
  period_to     date,
  units         numeric,
  amount        numeric not null default 0,
  line_type     text,
  note          text,
  delivered_on  date,
  detail        jsonb,
  created_at    timestamptz default now()
);
create index if not exists pay_lines_batch_idx  on public.pay_lines (batch_id);
create index if not exists pay_lines_worker_idx on public.pay_lines (worker_id);
-- these two stop the same supplier order or the same worker period being paid twice
create unique index if not exists pay_lines_supply_once
  on public.pay_lines (supply_id) where supply_id is not null;
create unique index if not exists pay_lines_worker_period_once
  on public.pay_lines (worker_id, period_from, period_to, line_type) where kind = 'worker';

-- 5. Managers only ----------------------------------------------------------------------
alter table public.work_hours  enable row level security;
alter table public.pay_batches enable row level security;
alter table public.pay_lines   enable row level security;

drop policy if exists managers_all on public.work_hours;
drop policy if exists managers_all on public.pay_batches;
drop policy if exists managers_all on public.pay_lines;

create policy managers_all on public.work_hours for all
  using (exists (select 1 from public.managers m where m.user_id = auth.uid()))
  with check (exists (select 1 from public.managers m where m.user_id = auth.uid()));
create policy managers_all on public.pay_batches for all
  using (exists (select 1 from public.managers m where m.user_id = auth.uid()))
  with check (exists (select 1 from public.managers m where m.user_id = auth.uid()));
create policy managers_all on public.pay_lines for all
  using (exists (select 1 from public.managers m where m.user_id = auth.uid()))
  with check (exists (select 1 from public.managers m where m.user_id = auth.uid()));

-- 6. Live updates -----------------------------------------------------------------------
do $$
declare t text;
begin
  foreach t in array array['work_hours','pay_batches','pay_lines'] loop
    begin
      execute format('alter publication supabase_realtime add table public.%I', t);
    exception when others then null;  -- already added
    end;
  end loop;
end $$;

-- 7. Make the API see the new tables and columns straight away ------------------------
notify pgrst, 'reload schema';
