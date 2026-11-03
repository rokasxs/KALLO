-- Kallo Klubams — database schema (Supabase / Postgres 15+)
--
-- Every table carries club_id. Row-level security lets a signed-in user see
-- only the clubs they belong to; coaches see only their own groups.
-- Money is stored in cents. One "charge" = one member's fee for one month.
--
-- Run in the Supabase SQL editor of an EU-region project.

create extension if not exists pgcrypto;

-- ---------------------------------------------------------------------------
-- Types
-- ---------------------------------------------------------------------------
create type club_role      as enum ('owner', 'admin', 'coach');
create type charge_status  as enum ('requested', 'paid', 'late', 'cancelled');
create type pay_source     as enum ('paysera', 'montonio', 'bank_import', 'cash', 'manual');
create type msg_kind       as enum ('request', 'reminder', 'broadcast');
create type msg_channel    as enum ('sms', 'email');
create type delivery_state as enum ('queued', 'sent', 'delivered', 'failed');

-- ---------------------------------------------------------------------------
-- Clubs and people who run them
-- ---------------------------------------------------------------------------
create table clubs (
  id           uuid primary key default gen_random_uuid(),
  name         text not null,
  city         text,
  legal_name   text,
  company_code text,
  plan         text not null default 'trial' check (plan in ('trial', 'burelis', 'klubas', 'akademija')),
  founder      boolean not null default false,          -- founders offer: -20 % for life
  trial_ends   date not null default (current_date + 14),
  due_day      smallint not null default 10 check (due_day between 1 and 28),
  pay_method   text not null default 'paysera' check (pay_method in ('paysera', 'montonio', 'bank')),
  iban         text,                                     -- club's own account; Kallo never holds money
  reminders    jsonb not null default '{"day1": true, "day7": true, "day14": true, "sms": true, "email": true}',
  created_at   timestamptz not null default now()
);

create table club_users (
  club_id    uuid not null references clubs(id) on delete cascade,
  user_id    uuid not null references auth.users(id) on delete cascade,
  role       club_role not null,
  name       text not null,
  phone      text,
  created_at timestamptz not null default now(),
  primary key (club_id, user_id)
);

-- ---------------------------------------------------------------------------
-- Groups, members (usually children) and guardians (parents)
-- ---------------------------------------------------------------------------
create table groups (
  id         uuid primary key default gen_random_uuid(),
  club_id    uuid not null references clubs(id) on delete cascade,
  name       text not null,
  fee_cents  integer not null check (fee_cents >= 0),
  coach_id   uuid references auth.users(id) on delete set null,
  schedule   text,                                       -- e.g. "Pr., Tr. 17:00"
  archived   boolean not null default false,
  created_at timestamptz not null default now()
);

create table members (
  id             uuid primary key default gen_random_uuid(),
  club_id        uuid not null references clubs(id) on delete cascade,
  group_id       uuid references groups(id) on delete set null,
  first_name     text not null,
  last_name      text not null,
  fee_cents      integer check (fee_cents >= 0),         -- null = group fee
  discount_note  text,
  joined_on      date not null default current_date,
  active         boolean not null default true,          -- inactive members get no charges
  notes          text check (char_length(notes) <= 500), -- no ID codes or health data (see terms)
  created_at     timestamptz not null default now()
);

create table guardians (
  id         uuid primary key default gen_random_uuid(),
  club_id    uuid not null references clubs(id) on delete cascade,
  name       text not null,
  phone      text,
  email      text,
  sms_ok     boolean not null default true,
  email_ok   boolean not null default true,
  created_at timestamptz not null default now(),
  check (phone is not null or email is not null)
);

create table member_guardians (
  member_id   uuid not null references members(id) on delete cascade,
  guardian_id uuid not null references guardians(id) on delete cascade,
  is_primary  boolean not null default true,
  primary key (member_id, guardian_id)
);

-- ---------------------------------------------------------------------------
-- Money: monthly charges, incoming payments
-- ---------------------------------------------------------------------------
create table charges (
  id           uuid primary key default gen_random_uuid(),
  club_id      uuid not null references clubs(id) on delete cascade,
  member_id    uuid not null references members(id) on delete cascade,
  period       date not null check (extract(day from period) = 1),  -- first day of the month
  amount_cents integer not null check (amount_cents >= 0),
  due_date     date not null,
  status       charge_status not null default 'requested',
  -- short code parents put in the bank transfer, e.g. "KS-7F3Q2"; used to match bank lines
  pay_ref      text not null unique default ('KS-' || upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 5))),
  paid_at      timestamptz,
  paid_via     pay_source,
  created_at   timestamptz not null default now(),
  unique (member_id, period)
);

create table payments (
  id           uuid primary key default gen_random_uuid(),
  club_id      uuid not null references clubs(id) on delete cascade,
  charge_id    uuid references charges(id) on delete set null,  -- null until matched
  amount_cents integer not null,
  received_at  timestamptz not null,
  source       pay_source not null,
  payer_name   text,
  reference    text,                                    -- payment purpose from the bank line
  raw          jsonb,                                   -- provider webhook or statement row
  matched_by   text check (matched_by in ('pay_ref', 'amount_name', 'manual')),
  created_at   timestamptz not null default now()
);

-- ---------------------------------------------------------------------------
-- Attendance
-- ---------------------------------------------------------------------------
create table sessions (
  id         uuid primary key default gen_random_uuid(),
  club_id    uuid not null references clubs(id) on delete cascade,
  group_id   uuid not null references groups(id) on delete cascade,
  held_on    date not null,
  marked_by  uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  unique (group_id, held_on)
);

create table attendance (
  session_id uuid not null references sessions(id) on delete cascade,
  member_id  uuid not null references members(id) on delete cascade,
  club_id    uuid not null references clubs(id) on delete cascade,
  present    boolean not null,
  primary key (session_id, member_id)
);

-- ---------------------------------------------------------------------------
-- Messages to parents and per-recipient delivery
-- ---------------------------------------------------------------------------
create table messages (
  id         uuid primary key default gen_random_uuid(),
  club_id    uuid not null references clubs(id) on delete cascade,
  kind       msg_kind not null,
  audience   text not null,                             -- 'all' | 'unpaid' | group id
  body       text not null,
  created_by uuid references auth.users(id) on delete set null,  -- null = automatic
  created_at timestamptz not null default now()
);

create table deliveries (
  id           uuid primary key default gen_random_uuid(),
  club_id      uuid not null references clubs(id) on delete cascade,
  message_id   uuid not null references messages(id) on delete cascade,
  guardian_id  uuid references guardians(id) on delete set null,
  charge_id    uuid references charges(id) on delete set null,
  channel      msg_channel not null,
  state        delivery_state not null default 'queued',
  provider_id  text,
  cost_cents   integer,
  sent_at      timestamptz,
  created_at   timestamptz not null default now()
);

-- who changed what (also needed to answer parents' data requests)
create table audit_log (
  id        bigserial primary key,
  club_id   uuid not null references clubs(id) on delete cascade,
  user_id   uuid references auth.users(id) on delete set null,
  action    text not null,
  entity    text not null,
  entity_id uuid,
  data      jsonb,
  at        timestamptz not null default now()
);

-- ---------------------------------------------------------------------------
-- Indexes
-- ---------------------------------------------------------------------------
create index on club_users (user_id);
create index on groups (club_id);
create index on members (club_id, group_id) where active;
create index on guardians (club_id);
create index on charges (club_id, period, status);
create index on payments (club_id, charge_id);
create index on sessions (club_id, group_id, held_on desc);
create index on attendance (member_id);
create index on deliveries (club_id, state);
create index on audit_log (club_id, at desc);

-- ---------------------------------------------------------------------------
-- Access helpers
-- ---------------------------------------------------------------------------
create or replace function is_club_user(c uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from club_users where club_id = c and user_id = auth.uid());
$$;

create or replace function is_club_admin(c uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from club_users where club_id = c and user_id = auth.uid() and role in ('owner', 'admin'));
$$;

-- coaches may only see members of the groups they coach
create or replace function can_see_group(g uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from groups gr join club_users cu on cu.club_id = gr.club_id and cu.user_id = auth.uid()
    where gr.id = g and (cu.role in ('owner', 'admin') or gr.coach_id = auth.uid())
  );
$$;

-- ---------------------------------------------------------------------------
-- Row-level security
-- ---------------------------------------------------------------------------
alter table clubs            enable row level security;
alter table club_users       enable row level security;
alter table groups           enable row level security;
alter table members          enable row level security;
alter table guardians        enable row level security;
alter table member_guardians enable row level security;
alter table charges          enable row level security;
alter table payments         enable row level security;
alter table sessions         enable row level security;
alter table attendance       enable row level security;
alter table messages         enable row level security;
alter table deliveries       enable row level security;
alter table audit_log        enable row level security;

create policy club_read   on clubs      for select using (is_club_user(id));
create policy club_write  on clubs      for update using (is_club_admin(id));

create policy cu_read     on club_users for select using (is_club_user(club_id));
create policy cu_write    on club_users for all    using (is_club_admin(club_id)) with check (is_club_admin(club_id));

create policy grp_read    on groups     for select using (is_club_user(club_id));
create policy grp_write   on groups     for all    using (is_club_admin(club_id)) with check (is_club_admin(club_id));

create policy mem_read    on members    for select using (is_club_admin(club_id) or (group_id is not null and can_see_group(group_id)));
create policy mem_write   on members    for all    using (is_club_admin(club_id)) with check (is_club_admin(club_id));

create policy gdn_rw      on guardians  for all    using (is_club_admin(club_id)) with check (is_club_admin(club_id));
create policy mg_rw       on member_guardians for all
  using (exists (select 1 from members m where m.id = member_id and is_club_admin(m.club_id)))
  with check (exists (select 1 from members m where m.id = member_id and is_club_admin(m.club_id)));

-- money and messages: owners and admins only
create policy chg_rw      on charges    for all    using (is_club_admin(club_id)) with check (is_club_admin(club_id));
create policy pay_rw      on payments   for all    using (is_club_admin(club_id)) with check (is_club_admin(club_id));
create policy msg_rw      on messages   for all    using (is_club_admin(club_id)) with check (is_club_admin(club_id));
create policy dlv_read    on deliveries for select using (is_club_admin(club_id));
create policy audit_read  on audit_log  for select using (is_club_admin(club_id));

-- attendance: admins, plus the coach of that group
create policy ses_read    on sessions   for select using (can_see_group(group_id));
create policy ses_write   on sessions   for all    using (can_see_group(group_id)) with check (can_see_group(group_id));
create policy att_read    on attendance for select using (exists (select 1 from sessions s where s.id = session_id and can_see_group(s.group_id)));
create policy att_write   on attendance for all
  using (exists (select 1 from sessions s where s.id = session_id and can_see_group(s.group_id)))
  with check (exists (select 1 from sessions s where s.id = session_id and can_see_group(s.group_id)));

-- ---------------------------------------------------------------------------
-- Billing helper: active members for a month = members with a non-cancelled charge
-- ---------------------------------------------------------------------------
create or replace function active_member_count(c uuid, p date) returns integer
language sql stable as $$
  select count(distinct member_id)::int from charges
  where club_id = c and period = date_trunc('month', p)::date and status <> 'cancelled';
$$;

-- Creates this month's charges for every active member (called by the day-1 job).
-- Safe to run twice: existing charges are left alone.
create or replace function create_monthly_charges(c uuid, p date default date_trunc('month', current_date)::date) returns integer
language plpgsql security definer set search_path = public as $$
declare n integer;
begin
  insert into charges (club_id, member_id, period, amount_cents, due_date)
  select m.club_id, m.id, p, coalesce(m.fee_cents, g.fee_cents),
         (p + ((select due_day from clubs where id = c) - 1))::date
  from members m join groups g on g.id = m.group_id
  where m.club_id = c and m.active and not g.archived
  on conflict (member_id, period) do nothing;
  get diagnostics n = row_count;
  return n;
end $$;
