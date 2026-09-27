-- ============================================================================
-- GymOS — Schéma PostgreSQL complet (Supabase)
-- Exécuter en entier dans le SQL Editor. Idempotent (IF NOT EXISTS / OR REPLACE).
-- ============================================================================
create extension if not exists pgcrypto;

-- ----------------------------------------------------------------------------
-- 1. TABLES
-- ----------------------------------------------------------------------------
create table if not exists organizations (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  settings jsonb not null default '{
    "expiry_alert_days": 7,
    "inactive_days": 14,
    "attendance_cooldown_seconds": 10,
    "language": "fr"
  }'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists branches (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references organizations(id) on delete cascade,
  name text not null,
  address text,
  phone text,
  active boolean not null default true,
  created_at timestamptz not null default now()
);

create table if not exists profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  org_id uuid not null references organizations(id) on delete cascade,
  branch_id uuid references branches(id) on delete set null,
  full_name text not null,
  role text not null default 'receptionist'
    check (role in ('owner','manager','receptionist','accountant','trainer')),
  phone text,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists staff_roles (
  org_id uuid not null references organizations(id) on delete cascade,
  role text not null check (role in ('owner','manager','receptionist','accountant','trainer')),
  permissions jsonb not null default '[]'::jsonb,
  primary key (org_id, role)
);

create table if not exists devices (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references organizations(id) on delete cascade,
  branch_id uuid references branches(id) on delete set null,
  name text not null,
  type text not null default 'tablet' check (type in ('tablet','kiosk','phone','other')),
  device_token text not null unique default ('DEV-' || upper(encode(gen_random_bytes(12), 'hex'))),
  status text not null default 'online',
  last_seen timestamptz,
  active boolean not null default true,
  created_at timestamptz not null default now()
);

create table if not exists membership_plans (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references organizations(id) on delete cascade,
  name text not null,
  price numeric(10,2) not null default 0,
  duration_days int not null default 30,
  description text,
  active boolean not null default true,
  created_at timestamptz not null default now()
);

create table if not exists members (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references organizations(id) on delete cascade,
  branch_id uuid references branches(id) on delete set null,
  full_name text not null,
  phone text not null,
  gender text,
  dob date,
  address text,
  emergency_contact text,
  notes text,
  photo_url text,
  status text not null default 'active' check (status in ('active','archived')),
  -- Identité QR PERMANENTE : jamais régénérée (sauf révocation explicite)
  qr_token text not null unique
    default ('GYM-MEMBER-' || upper(encode(gen_random_bytes(16), 'hex'))),
  created_by uuid references profiles(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists idx_members_org on members(org_id, status);
create index if not exists idx_members_phone on members(org_id, phone);

create table if not exists memberships (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references organizations(id) on delete cascade,
  member_id uuid not null references members(id) on delete cascade,
  plan_id uuid references membership_plans(id) on delete set null,
  plan_name text not null,
  price numeric(10,2) not null default 0,
  start_date date not null,
  end_date date not null,
  status text not null default 'active' check (status in ('active','frozen','expired','cancelled')),
  created_by uuid references profiles(id),
  created_at timestamptz not null default now()
);
create index if not exists idx_memberships_member on memberships(member_id, created_at desc);
create index if not exists idx_memberships_end on memberships(org_id, end_date);

create table if not exists membership_freezes (
  id uuid primary key default gen_random_uuid(),
  membership_id uuid not null references memberships(id) on delete cascade,
  start_date date not null,
  end_date date not null,
  reason text,
  created_by uuid references profiles(id),
  created_at timestamptz not null default now()
);

-- Un membre = au plus UNE session ouverte (peu importe la branche).
create table if not exists attendance (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references organizations(id) on delete cascade,
  branch_id uuid references branches(id) on delete set null,
  device_id uuid references devices(id) on delete set null,
  member_id uuid not null references members(id) on delete cascade,
  check_in_at timestamptz not null default now(),
  check_out_at timestamptz,
  duration_seconds int,
  status text not null default 'open' check (status in ('open','closed')),
  client_event_id uuid unique,          -- déduplication synchro hors ligne
  created_at timestamptz not null default now()
);
create unique index if not exists uq_attendance_open
  on attendance(member_id) where check_out_at is null;
create index if not exists idx_attendance_branch_time on attendance(branch_id, check_in_at desc);
create index if not exists idx_attendance_member on attendance(member_id, check_in_at desc);

create table if not exists payments (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references organizations(id) on delete cascade,
  branch_id uuid references branches(id) on delete set null,
  member_id uuid references members(id) on delete set null,
  type text not null default 'membership'
    check (type in ('membership','personal_training','class','product_sale','other')),
  amount numeric(10,2) not null check (amount >= 0),
  method text not null default 'cash' check (method in ('cash','card','other')),
  date date not null default current_date,
  note text,
  sale_id uuid,
  created_by uuid references profiles(id),
  created_at timestamptz not null default now()
);
create index if not exists idx_payments_org_date on payments(org_id, date desc);

create table if not exists expenses (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references organizations(id) on delete cascade,
  branch_id uuid references branches(id) on delete set null,
  category text not null
    check (category in ('rent','electricity','water','salaries','maintenance','equipment','marketing','other')),
  amount numeric(10,2) not null check (amount >= 0),
  method text not null default 'cash' check (method in ('cash','card','other')),
  date date not null default current_date,
  note text,
  attachment_url text,
  created_by uuid references profiles(id),
  created_at timestamptz not null default now()
);
create index if not exists idx_expenses_org_date on expenses(org_id, date desc);

create table if not exists cash_registers (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references organizations(id) on delete cascade,
  branch_id uuid references branches(id) on delete set null,
  date date not null default current_date,
  opening_balance numeric(10,2) not null default 0,
  actual_closing numeric(10,2),
  closed boolean not null default false,
  closed_by uuid references profiles(id),
  closed_at timestamptz,
  created_at timestamptz not null default now(),
  unique(branch_id, date)
);

create table if not exists trainers (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references organizations(id) on delete cascade,
  branch_id uuid references branches(id) on delete set null,
  name text not null,
  phone text,
  specialization text,
  status text not null default 'active' check (status in ('active','inactive')),
  notes text,
  created_at timestamptz not null default now()
);

create table if not exists trainer_clients (
  id uuid primary key default gen_random_uuid(),
  trainer_id uuid not null references trainers(id) on delete cascade,
  member_id uuid not null references members(id) on delete cascade,
  since date not null default current_date,
  notes text,
  unique(trainer_id, member_id)
);

create table if not exists product_categories (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references organizations(id) on delete cascade,
  name text not null
);

create table if not exists products (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references organizations(id) on delete cascade,
  category_id uuid references product_categories(id) on delete set null,
  name text not null,
  sku text,
  purchase_price numeric(10,2) not null default 0,
  selling_price numeric(10,2) not null default 0,
  stock int not null default 0 check (stock >= 0),
  min_stock int not null default 0,
  active boolean not null default true,
  created_at timestamptz not null default now()
);
create index if not exists idx_products_org on products(org_id, active);

create table if not exists inventory_movements (
  id uuid primary key default gen_random_uuid(),
  product_id uuid not null references products(id) on delete cascade,
  type text not null check (type in ('purchase','sale','adjustment','return')),
  qty int not null,
  unit_price numeric(10,2) default 0,
  note text,
  created_by uuid references profiles(id),
  created_at timestamptz not null default now()
);

create table if not exists sales (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references organizations(id) on delete cascade,
  branch_id uuid references branches(id) on delete set null,
  member_id uuid references members(id) on delete set null,
  total numeric(10,2) not null,
  method text not null default 'cash' check (method in ('cash','card','other')),
  created_by uuid references profiles(id),
  created_at timestamptz not null default now()
);

create table if not exists sale_items (
  id uuid primary key default gen_random_uuid(),
  sale_id uuid not null references sales(id) on delete cascade,
  product_id uuid references products(id) on delete set null,
  name text not null,
  qty int not null check (qty > 0),
  unit_price numeric(10,2) not null
);

create table if not exists leads (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references organizations(id) on delete cascade,
  name text not null,
  phone text,
  plan_id uuid references membership_plans(id) on delete set null,
  source text,
  status text not null default 'new'
    check (status in ('new','contacted','trial','converted','lost')),
  notes text,
  created_at timestamptz not null default now()
);

create table if not exists notifications (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references organizations(id) on delete cascade,
  type text not null,
  message text not null,
  entity text,
  entity_id uuid,
  read boolean not null default false,
  created_at timestamptz not null default now()
);

create table if not exists member_cards (
  id uuid primary key default gen_random_uuid(),
  member_id uuid not null references members(id) on delete cascade,
  file_url text,
  validity_label text,
  created_by uuid references profiles(id),
  created_at timestamptz not null default now()
);

create table if not exists audit_logs (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references organizations(id) on delete cascade,
  user_id uuid,
  user_name text,
  action text not null,
  entity text not null,
  entity_id uuid,
  meta jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);
create index if not exists idx_audit_org_time on audit_logs(org_id, created_at desc);

-- ----------------------------------------------------------------------------
-- 2. FONCTIONS & TRIGGERS
-- ----------------------------------------------------------------------------

-- Profil auto à la création d'un utilisateur auth
create or replace function public.handle_new_user()
returns trigger
language plpgsql security definer set search_path = public
as $$
begin
  insert into public.profiles (id, org_id, branch_id, full_name, role)
  values (
    new.id,
    coalesce((new.raw_user_meta_data->>'org_id')::uuid, (select id from organizations limit 1)),
    (new.raw_user_meta_data->>'branch_id')::uuid,
    coalesce(new.raw_user_meta_data->>'full_name', split_part(new.email,'@',1)),
    coalesce(new.raw_user_meta_data->>'role', 'receptionist')
  ) on conflict (id) do nothing;
  return new;
end $$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- QR token : PERMANENT. Toute modification directe est bloquée.
create or replace function public.protect_qr_token()
returns trigger language plpgsql as $$
begin
  if old.qr_token is distinct from new.qr_token
     and current_setting('gymos.allow_qr_rotation', true) <> 'on' then
    raise exception 'QR_TOKEN_IMMUTABLE: use revoke_member_qr() for explicit revocation';
  end if;
  return new;
end $$;

drop trigger if exists trg_protect_qr on members;
create trigger trg_protect_qr before update on members
  for each row execute function public.protect_qr_token();

-- Révocation explicite (admin) — remplace le token, marque l'ancien en audit
create or replace function public.revoke_member_qr(p_member_id uuid)
returns text
language plpgsql security definer set search_path = public
as $$
declare v_new text;
begin
  if not exists (select 1 from members where id = p_member_id and org_id = auth_org()) then
    raise exception 'FORBIDDEN';
  end if;
  v_new := 'GYM-MEMBER-' || upper(encode(gen_random_bytes(16), 'hex'));
  perform set_config('gymos.allow_qr_rotation', 'on', true);
  update members set qr_token = v_new where id = p_member_id;
  perform set_config('gymos.allow_qr_rotation', 'off', true);
  insert into audit_logs (org_id, user_id, user_name, action, entity, entity_id, meta)
  values (auth_org(), auth.uid(), auth_name(), 'qr_revoked', 'member', p_member_id,
          jsonb_build_object('new_token_prefix', left(v_new, 20)));
  return v_new;
end $$;

-- Helpers auth (utilisés par RLS)
create or replace function public.auth_org() returns uuid
language sql stable security definer set search_path = public
as $$ select org_id from profiles where id = auth.uid() $$;

create or replace function public.auth_role() returns text
language sql stable security definer set search_path = public
as $$ select role from profiles where id = auth.uid() $$;

create or replace function public.auth_name() returns text
language sql stable security definer set search_path = public
as $$ select full_name from profiles where id = auth.uid() $$;

create or replace function public.has_any_role(roles text[])
returns boolean language sql stable security definer set search_path = public
as $$ select auth_role() = any(roles) $$;

-- Audit générique
create or replace function public.audit_row()
returns trigger language plpgsql security definer set search_path = public
as $$
begin
  insert into audit_logs (org_id, user_id, user_name, action, entity, entity_id, meta)
  values (auth_org(), auth.uid(), auth_name(),
          TG_OP || '_' || TG_TABLE_NAME,
          TG_TABLE_NAME,
          coalesce((to_jsonb(NEW)->>'id')::uuid, (to_jsonb(OLD)->>'id')::uuid),
          jsonb_build_object('old', case when TG_OP = 'DELETE' then to_jsonb(OLD) else null end,
                             'new', case when TG_OP in ('INSERT','UPDATE') then to_jsonb(NEW) else null end));
  return coalesce(NEW, OLD);
end $$;

drop trigger if exists audit_members on members;
create trigger audit_members after insert or update or delete on members
  for each row execute function public.audit_row();
drop trigger if exists audit_memberships on memberships;
create trigger audit_memberships after insert or update or delete on memberships
  for each row execute function public.audit_row();
drop trigger if exists audit_payments on payments;
create trigger audit_payments after insert or update or delete on payments
  for each row execute function public.audit_row();
drop trigger if exists audit_expenses on expenses;
create trigger audit_expenses after insert or update or delete on expenses
  for each row execute function public.audit_row();

-- Offline sync idempotency: one server result per client event.
create table if not exists processed_events (
  id uuid primary key default gen_random_uuid(),
  client_event_id uuid not null unique,
  org_id uuid not null references organizations(id) on delete cascade,
  device_id uuid references devices(id) on delete set null,
  result jsonb not null,
  created_at timestamptz not null default now()
);
create index if not exists idx_processed_events_org_created
  on processed_events(org_id, created_at desc);

-- ----------------------------------------------------------------------------

-- -----------------------------------------------------------------------------
-- Atomic member onboarding / renewal
-- -----------------------------------------------------------------------------
create or replace function public.create_member_with_membership(
  p_branch_id uuid,
  p_full_name text,
  p_phone text,
  p_plan_id uuid,
  p_start_date date,
  p_price numeric,
  p_method text default 'cash',
  p_gender text default null,
  p_dob date default null,
  p_address text default null,
  p_emergency_contact text default null,
  p_notes text default null,
  p_photo_url text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_org uuid := auth_org();
  v_role text := auth_role();
  v_plan membership_plans%rowtype;
  v_member members%rowtype;
  v_membership memberships%rowtype;
  v_payment payments%rowtype;
  v_end date;
begin
  if v_org is null or v_role not in ('owner','manager','receptionist') then
    raise exception 'FORBIDDEN';
  end if;
  if p_full_name is null or btrim(p_full_name) = '' or p_phone is null or btrim(p_phone) = '' then
    raise exception 'INVALID_MEMBER';
  end if;
  if p_price < 0 then raise exception 'INVALID_PRICE'; end if;
  if p_method not in ('cash','card','other') then raise exception 'INVALID_PAYMENT_METHOD'; end if;

  select * into v_plan from membership_plans
   where id = p_plan_id and org_id = v_org and active = true;
  if not found then raise exception 'PLAN_NOT_FOUND'; end if;

  if p_branch_id is not null and not exists (
    select 1 from branches where id = p_branch_id and org_id = v_org and active = true
  ) then raise exception 'BRANCH_NOT_FOUND'; end if;

  v_end := p_start_date + greatest(v_plan.duration_days,1) - 1;

  insert into members(
    org_id, branch_id, full_name, phone, gender, dob, address,
    emergency_contact, notes, photo_url, status, created_by
  ) values (
    v_org, p_branch_id, btrim(p_full_name), btrim(p_phone), p_gender, p_dob, p_address,
    p_emergency_contact, p_notes, p_photo_url, 'active', auth.uid()
  ) returning * into v_member;

  insert into memberships(
    org_id, member_id, plan_id, plan_name, price, start_date, end_date, status, created_by
  ) values (
    v_org, v_member.id, v_plan.id, v_plan.name, p_price, p_start_date, v_end, 'active', auth.uid()
  ) returning * into v_membership;

  if p_price > 0 then
    insert into payments(
      org_id, branch_id, member_id, type, amount, method, date, note, created_by
    ) values (
      v_org, p_branch_id, v_member.id, 'membership', p_price, p_method, p_start_date, null, auth.uid()
    ) returning * into v_payment;
  end if;

  return jsonb_build_object(
    'member', to_jsonb(v_member),
    'membership', to_jsonb(v_membership),
    'payment', case when p_price > 0 then to_jsonb(v_payment) else null end
  );
end $$;

create or replace function public.renew_membership_atomic(
  p_member_id uuid,
  p_plan_id uuid,
  p_start_date date,
  p_price numeric,
  p_method text default 'cash'
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_org uuid := auth_org();
  v_role text := auth_role();
  v_member members%rowtype;
  v_plan membership_plans%rowtype;
  v_current memberships%rowtype;
  v_membership memberships%rowtype;
  v_payment payments%rowtype;
  v_actual_start date := p_start_date;
  v_end date;
begin
  if v_org is null or v_role not in ('owner','manager','receptionist') then
    raise exception 'FORBIDDEN';
  end if;
  if p_price < 0 then raise exception 'INVALID_PRICE'; end if;
  if p_method not in ('cash','card','other') then raise exception 'INVALID_PAYMENT_METHOD'; end if;

  select * into v_member from members where id = p_member_id and org_id = v_org for update;
  if not found then raise exception 'MEMBER_NOT_FOUND'; end if;
  select * into v_plan from membership_plans where id = p_plan_id and org_id = v_org and active = true;
  if not found then raise exception 'PLAN_NOT_FOUND'; end if;

  -- Lock the latest non-cancelled membership so two simultaneous renewals cannot overlap.
  select * into v_current from memberships
   where member_id = p_member_id and org_id = v_org and status <> 'cancelled'
   order by end_date desc, created_at desc limit 1 for update;

  if found and v_current.end_date >= p_start_date then
    v_actual_start := v_current.end_date + 1;
  end if;
  v_end := v_actual_start + greatest(v_plan.duration_days,1) - 1;

  -- IMPORTANT: never update the historical membership. Always append a new record.
  insert into memberships(
    org_id, member_id, plan_id, plan_name, price, start_date, end_date, status, created_by
  ) values (
    v_org, p_member_id, v_plan.id, v_plan.name, p_price, v_actual_start, v_end, 'active', auth.uid()
  ) returning * into v_membership;

  if p_price > 0 then
    insert into payments(
      org_id, branch_id, member_id, type, amount, method, date, note, created_by
    ) values (
      v_org, v_member.branch_id, p_member_id, 'membership', p_price, p_method, current_date, 'membership renewal', auth.uid()
    ) returning * into v_payment;
  end if;

  return jsonb_build_object(
    'membership', to_jsonb(v_membership),
    'payment', case when p_price > 0 then to_jsonb(v_payment) else null end,
    'previous_membership_id', case when found then v_current.id else null end,
    'effective_start_date', v_actual_start
  );
end $$;

-- 3. check_attendance : SOURCE DE VÉRITÉ (security definer)
--    Le client ne fait JAMAIS confiance à un statut local.
-- ----------------------------------------------------------------------------
create or replace function public.check_attendance(
  p_qr_token text,
  p_device_token text,
  p_client_event uuid default null
)
returns jsonb
language plpgsql security definer set search_path = public
as $$
declare
  v_device devices%rowtype;
  v_member members%rowtype;
  v_membership memberships%rowtype;
  v_freeze membership_freezes%rowtype;
  v_open attendance%rowtype;
  v_cooldown int;
  v_last attendance%rowtype;
  v_now timestamptz := now();
  v_result jsonb;
begin
  -- Déduplication synchro hors ligne : rejeu idempotent (même résultat, aucun effet)
  if p_client_event is not null then
    declare v_prev jsonb;
    begin
      select result into v_prev from processed_events where client_event_id = p_client_event;
      if found then
        return v_prev || jsonb_build_object('replayed', true);
      end if;
    end;
  end if;

  select * into v_device from devices
   where device_token = p_device_token and active = true;
  if not found then
    return jsonb_build_object('ok', false, 'reason', 'device_not_found');
  end if;
  update devices set last_seen = v_now, status = 'online' where id = v_device.id;

  select * into v_member from members where qr_token = p_qr_token;
  if not found then
    return jsonb_build_object('ok', false, 'reason', 'member_not_found');
  end if;
  if v_member.org_id <> v_device.org_id then
    return jsonb_build_object('ok', false, 'reason', 'member_not_found');
  end if;
  if v_device.branch_id is not null
     and v_member.branch_id is not null
     and v_member.branch_id <> v_device.branch_id then
    return jsonb_build_object('ok', false, 'reason', 'member_not_found');
  end if;
  if v_member.status <> 'active' then
    return jsonb_build_object('ok', false, 'reason', 'member_not_found');
  end if;

  -- Adhésion courante (la plus récente non annulée)
  select * into v_membership from memberships
   where member_id = v_member.id and status <> 'cancelled'
     and start_date <= current_date
   order by end_date desc, created_at desc limit 1;
  if not found then
    return jsonb_build_object('ok', false, 'reason', 'no_membership');
  end if;
  if v_membership.status = 'cancelled' then
    return jsonb_build_object('ok', false, 'reason', 'membership_cancelled');
  end if;
  if v_membership.status = 'frozen'
     or exists (select 1 from membership_freezes
                 where membership_id = v_membership.id
                   and current_date between start_date and end_date) then
    return jsonb_build_object('ok', false, 'reason', 'membership_frozen');
  end if;
  if v_membership.end_date < current_date then
    return jsonb_build_object('ok', false, 'reason', 'membership_expired');
  end if;

  -- Cooldown anti double-scan
  select coalesce((settings->>'attendance_cooldown_seconds')::int, 10)
    into v_cooldown from organizations where id = v_member.org_id;
  select * into v_last from attendance
   where member_id = v_member.id
   order by created_at desc limit 1;
  if found and extract(epoch from (v_now - v_last.created_at)) < v_cooldown then
    return jsonb_build_object('ok', false, 'reason', 'cooldown',
                              'member', jsonb_build_object('name', v_member.full_name));
  end if;

  -- Bascule check-in / check-out (index partiel unique = garantie anti-doublon)
  select * into v_open from attendance
   where member_id = v_member.id and check_out_at is null;
  if found then
    update attendance
       set check_out_at = v_now,
           duration_seconds = extract(epoch from (v_now - check_in_at))::int,
           status = 'closed'
     where id = v_open.id;
    v_result := jsonb_build_object(
      'ok', true, 'action', 'check_out',
      'member', jsonb_build_object('id', v_member.id, 'name', v_member.full_name,
                                   'plan', v_membership.plan_name,
                                   'valid_until', v_membership.end_date),
      'check_in_at', v_open.check_in_at, 'check_out_at', v_now,
      'duration_seconds', extract(epoch from (v_now - v_open.check_in_at))::int);
  else
    insert into attendance (org_id, branch_id, device_id, member_id, client_event_id)
    values (v_device.org_id, v_device.branch_id, v_device.id, v_member.id, p_client_event);
    v_result := jsonb_build_object(
      'ok', true, 'action', 'check_in',
      'member', jsonb_build_object('id', v_member.id, 'name', v_member.full_name,
                                   'plan', v_membership.plan_name,
                                   'valid_until', v_membership.end_date),
      'check_in_at', v_now);
  end if;
  if p_client_event is not null then
    insert into processed_events(client_event_id, org_id, device_id, result)
    values (p_client_event, v_device.org_id, v_device.id, v_result)
    on conflict (client_event_id) do nothing;
  end if;
  return v_result;
end $$;

-- Minimal member cache for offline entry terminals.
-- Access is granted by the terminal device token, not by a staff session.
create or replace function public.get_entry_cache(p_device_token text)
returns table(
  member_id uuid,
  qr_token text,
  full_name text,
  plan_name text,
  end_date date,
  state text
)
language sql security definer set search_path = public
as $$
  select m.id,
         m.qr_token,
         m.full_name,
         coalesce(ms.plan_name, ''),
         ms.end_date,
         case
           when m.status <> 'active' then 'archived'
           when ms.id is null then 'none'
           when ms.status = 'frozen' then 'frozen'
           when exists (
             select 1 from membership_freezes mf
             where mf.membership_id = ms.id
               and current_date between mf.start_date and mf.end_date
           ) then 'frozen'
           when ms.end_date < current_date then 'expired'
           else 'active'
         end
  from devices d
  join members m on m.org_id = d.org_id
    and (d.branch_id is null or m.branch_id is null or m.branch_id = d.branch_id)
  left join lateral (
    select x.*
    from memberships x
    where x.member_id = m.id
      and x.status <> 'cancelled'
      and x.start_date <= current_date
    order by x.end_date desc, x.created_at desc
    limit 1
  ) ms on true
  where d.device_token = p_device_token
    and d.active = true;
$$;

-- Minimal live statistics for an unauthenticated entry terminal.
create or replace function public.get_entry_snapshot(p_device_token text)
returns jsonb
language sql security definer set search_path = public
as $$
  with d as (
    select id, org_id, branch_id
    from devices
    where device_token = p_device_token and active = true
    limit 1
  ),
  open_sessions as (
    select a.id, a.check_in_at, m.full_name
    from attendance a
    join d on d.org_id = a.org_id
      and (d.branch_id is null or a.branch_id = d.branch_id)
    join members m on m.id = a.member_id
    where a.check_out_at is null
  ),
  today_visits as (
    select count(*)::int as visits
    from attendance a
    join d on d.org_id = a.org_id
      and (d.branch_id is null or a.branch_id = d.branch_id)
    where a.check_in_at >= current_date
      and a.check_in_at < current_date + interval '1 day'
  )
  select jsonb_build_object(
    'inside', coalesce((select jsonb_agg(jsonb_build_object(
      'id', id, 'full_name', full_name, 'check_in_at', check_in_at
    ) order by check_in_at) from open_sessions), '[]'::jsonb),
    'visits', coalesce((select visits from today_visits), 0)
  );
$$;

-- ----------------------------------------------------------------------------
-- 4. RLS
-- ----------------------------------------------------------------------------
alter table organizations enable row level security;
alter table processed_events enable row level security; -- aucune policy : écriture réservée aux fonctions
alter table branches enable row level security;
alter table profiles enable row level security;
alter table staff_roles enable row level security;
alter table devices enable row level security;
alter table membership_plans enable row level security;
alter table members enable row level security;
alter table memberships enable row level security;
alter table membership_freezes enable row level security;
alter table attendance enable row level security;
alter table payments enable row level security;
alter table expenses enable row level security;
alter table cash_registers enable row level security;
alter table trainers enable row level security;
alter table trainer_clients enable row level security;
alter table product_categories enable row level security;
alter table products enable row level security;
alter table inventory_movements enable row level security;
alter table sales enable row level security;
alter table sale_items enable row level security;
alter table leads enable row level security;
alter table notifications enable row level security;
alter table member_cards enable row level security;
alter table audit_logs enable row level security;
create policy p_read_processed_events on processed_events for select
  using (org_id = auth_org() and has_any_role('{owner,manager}'));



-- Tout staff authentifié lit les données de son organisation.
create policy p_read_org on members for select
  using (org_id = auth_org() and has_any_role('{owner,manager,receptionist,accountant,trainer}'));
create policy p_write_members on members for all
  using (org_id = auth_org() and has_any_role('{owner,manager,receptionist}'))
  with check (org_id = auth_org() and has_any_role('{owner,manager,receptionist}'));

create policy p_read_plans on membership_plans for select using (org_id = auth_org());
create policy p_write_plans on membership_plans for all
  using (org_id = auth_org() and has_any_role('{owner,manager}'))
  with check (org_id = auth_org() and has_any_role('{owner,manager}'));

create policy p_read_ms on memberships for select using (org_id = auth_org());
create policy p_write_ms on memberships for all
  using (org_id = auth_org() and has_any_role('{owner,manager,receptionist}'))
  with check (org_id = auth_org() and has_any_role('{owner,manager,receptionist}'));

create policy p_read_fr on membership_freezes for select using (
  exists (select 1 from memberships m where m.id = membership_id and m.org_id = auth_org()));
create policy p_write_fr on membership_freezes for all
  using (has_any_role('{owner,manager,receptionist}'))
  with check (has_any_role('{owner,manager,receptionist}'));

create policy p_read_att on attendance for select
  using (org_id = auth_org() and has_any_role('{owner,manager,receptionist,trainer}'));
create policy p_write_att on attendance for insert
  with check (false); -- écriture UNIQUEMENT via check_attendance() (security definer)
create policy p_update_att on attendance for update
  using (org_id = auth_org() and has_any_role('{owner,manager}'))
  with check (org_id = auth_org() and has_any_role('{owner,manager}'));

create policy p_read_pay on payments for select using (org_id = auth_org());
create policy p_write_pay on payments for all
  using (org_id = auth_org() and has_any_role('{owner,manager,receptionist,accountant}'))
  with check (org_id = auth_org() and has_any_role('{owner,manager,receptionist,accountant}'));

create policy p_read_exp on expenses for select using (org_id = auth_org());
create policy p_write_exp on expenses for all
  using (org_id = auth_org() and has_any_role('{owner,manager,accountant}'))
  with check (org_id = auth_org() and has_any_role('{owner,manager,accountant}'));

create policy p_read_cash on cash_registers for select using (org_id = auth_org());
create policy p_write_cash on cash_registers for all
  using (org_id = auth_org() and has_any_role('{owner,manager,accountant}'))
  with check (org_id = auth_org() and has_any_role('{owner,manager,accountant}'));

create policy p_read_trainers on trainers for select
  using (org_id = auth_org() and has_any_role('{owner,manager,trainer,receptionist}'));
create policy p_write_trainers on trainers for all
  using (org_id = auth_org() and has_any_role('{owner,manager}'))
  with check (org_id = auth_org() and has_any_role('{owner,manager}'));

create policy p_read_tc on trainer_clients for select using (
  exists (select 1 from trainers t where t.id = trainer_id and t.org_id = auth_org()));
create policy p_write_tc on trainer_clients for all
  using (has_any_role('{owner,manager,trainer}'))
  with check (has_any_role('{owner,manager,trainer}'));

create policy p_read_prod on products for select using (org_id = auth_org());
create policy p_write_prod on products for all
  using (org_id = auth_org() and has_any_role('{owner,manager,receptionist}'))
  with check (org_id = auth_org() and has_any_role('{owner,manager,receptionist}'));
create policy p_read_pc on product_categories for select using (org_id = auth_org());
create policy p_write_pc on product_categories for all
  using (org_id = auth_org() and has_any_role('{owner,manager}'))
  with check (org_id = auth_org() and has_any_role('{owner,manager}'));
create policy p_write_im on inventory_movements for insert
  with check (has_any_role('{owner,manager,receptionist}'));

create policy p_read_sales on sales for select using (org_id = auth_org());
create policy p_write_sales on sales for all
  using (org_id = auth_org() and has_any_role('{owner,manager,receptionist}'))
  with check (org_id = auth_org() and has_any_role('{owner,manager,receptionist}'));
create policy p_read_si on sale_items for select using (
  exists (select 1 from sales s where s.id = sale_id and s.org_id = auth_org()));
create policy p_write_si on sale_items for insert
  with check (has_any_role('{owner,manager,receptionist}'));

create policy p_read_leads on leads for select
  using (org_id = auth_org() and has_any_role('{owner,manager,receptionist}'));
create policy p_write_leads on leads for all
  using (org_id = auth_org() and has_any_role('{owner,manager,receptionist}'))
  with check (org_id = auth_org() and has_any_role('{owner,manager,receptionist}'));

create policy p_read_dev on devices for select
  using (org_id = auth_org() and has_any_role('{owner,manager}'));
create policy p_write_dev on devices for all
  using (org_id = auth_org() and has_any_role('{owner,manager}'))
  with check (org_id = auth_org() and has_any_role('{owner,manager}'));

create policy p_read_notif on notifications for select using (org_id = auth_org());
create policy p_write_notif on notifications for all
  using (org_id = auth_org() and has_any_role('{owner,manager}'))
  with check (org_id = auth_org() and has_any_role('{owner,manager}'));

create policy p_read_cards on member_cards for select using (
  exists (select 1 from members m where m.id = member_id and m.org_id = auth_org()));
create policy p_write_cards on member_cards for insert
  with check (has_any_role('{owner,manager,receptionist}'));

create policy p_read_audit on audit_logs for select
  using (org_id = auth_org() and has_any_role('{owner,manager}'));
-- pas d'insert policy = audit_logs en écriture réservée aux fonctions security definer

create policy p_read_branches on branches for select using (
  org_id = auth_org() and has_any_role('{owner,manager,receptionist,accountant,trainer}'));
create policy p_write_branches on branches for all
  using (org_id = auth_org() and has_any_role('{owner,manager}'))
  with check (org_id = auth_org() and has_any_role('{owner,manager}'));

create policy p_read_org_tbl on organizations for select using (
  id = auth_org() and has_any_role('{owner,manager,receptionist,accountant,trainer}'));
create policy p_write_org_tbl on organizations for update
  using (id = auth_org() and auth_role() = 'owner')
  with check (id = auth_org() and auth_role() = 'owner');

create policy p_read_profiles on profiles for select using (
  id = auth.uid() or (org_id = auth_org() and has_any_role('{owner,manager}')));
create policy p_write_profiles on profiles for update
  using (id = auth.uid() or (org_id = auth_org() and auth_role() = 'owner'))
  with check (id = auth.uid() or (org_id = auth_org() and auth_role() = 'owner'));

create policy p_read_staff_roles on staff_roles for select using (org_id = auth_org());
create policy p_write_staff_roles on staff_roles for all
  using (org_id = auth_org() and auth_role() = 'owner')
  with check (org_id = auth_org() and auth_role() = 'owner');

-- ----------------------------------------------------------------------------
-- 5. GRANTS & REALTIME
-- ----------------------------------------------------------------------------
revoke execute on function public.check_attendance(text, text, uuid) from public;
grant execute on function public.check_attendance(text, text, uuid) to anon, authenticated;
revoke execute on function public.get_entry_cache(text) from public;
revoke execute on function public.get_entry_snapshot(text) from public;
grant execute on function public.get_entry_cache(text) to anon, authenticated;
grant execute on function public.get_entry_snapshot(text) to anon, authenticated;
revoke execute on function public.revoke_member_qr(uuid) from public;
grant execute on function public.revoke_member_qr(uuid) to authenticated;
revoke execute on function public.create_member_with_membership(uuid,text,text,uuid,date,numeric,text,text,date,text,text,text,text) from public;
grant execute on function public.create_member_with_membership(uuid,text,text,uuid,date,numeric,text,text,date,text,text,text,text) to authenticated;
revoke execute on function public.renew_membership_atomic(uuid,uuid,date,numeric,text) from public;
grant execute on function public.renew_membership_atomic(uuid,uuid,date,numeric,text) to authenticated;

alter publication supabase_realtime add table attendance;
alter publication supabase_realtime add table members;

-- ----------------------------------------------------------------------------
-- 6. VUE OCCUPANCY (pratique pour les dashboards)
-- ----------------------------------------------------------------------------
create or replace view public.current_occupancy as
select org_id, branch_id, count(*) as inside
  from attendance
 where check_out_at is null
 group by org_id, branch_id;

-- Fin du schéma GymOS
