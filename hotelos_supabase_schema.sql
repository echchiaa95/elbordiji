-- HotelOS — Supabase production schema
-- Generated to match the uploaded HotelOS frontend domain types.
-- Run in a NEW Supabase project.
-- IMPORTANT: never put service_role in the frontend.

create extension if not exists pgcrypto;
create extension if not exists btree_gist;

do $$ begin
  create type public.room_status as enum (
    'available','reserved','occupied','cleaning','maintenance','out_of_service'
  );
exception when duplicate_object then null; end $$;

do $$ begin
  create type public.reservation_status as enum (
    'pending','confirmed','checked_in','checked_out','cancelled','no_show'
  );
exception when duplicate_object then null; end $$;

do $$ begin
  create type public.reservation_source as enum (
    'direct','booking_com','expedia','airbnb','phone','whatsapp','walk_in','other'
  );
exception when duplicate_object then null; end $$;

do $$ begin
  create type public.payment_method as enum (
    'cash','card','bank_transfer','online','other'
  );
exception when duplicate_object then null; end $$;

do $$ begin
  create type public.payment_status as enum (
    'pending','paid','refunded','failed','cancelled'
  );
exception when duplicate_object then null; end $$;

do $$ begin
  create type public.user_role as enum (
    'owner','manager','receptionist','housekeeping','accountant'
  );
exception when duplicate_object then null; end $$;

do $$ begin
  create type public.housekeeping_status as enum (
    'pending','in_progress','completed'
  );
exception when duplicate_object then null; end $$;

do $$ begin
  create type public.task_type as enum (
    'cleaning','maintenance','inspection','other'
  );
exception when duplicate_object then null; end $$;

do $$ begin
  create type public.document_type as enum (
    'passport','national_id','driver_license','other'
  );
exception when duplicate_object then null; end $$;

create table if not exists public.hotels (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  slug text not null unique,
  description jsonb not null default '{}'::jsonb,
  address text not null default '',
  city text not null default '',
  country text not null default '',
  phone text not null default '',
  email text not null default '',
  logo_url text,
  cover_url text,
  currency text not null default 'MAD',
  timezone text not null default 'Africa/Casablanca',
  default_language text not null default 'fr' check (default_language in ('fr','ar','en')),
  enabled_languages text[] not null default array['fr','ar','en'],
  check_in_time time not null default '15:00',
  check_out_time time not null default '12:00',
  status text not null default 'active',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  hotel_id uuid not null references public.hotels(id) on delete cascade,
  email text not null default '',
  first_name text not null default '',
  last_name text not null default '',
  phone text not null default '',
  avatar_url text,
  avatar_color text not null default '#64748b',
  role public.user_role not null default 'receptionist',
  preferred_language text not null default 'fr' check (preferred_language in ('fr','ar','en')),
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.room_types (
  id uuid primary key default gen_random_uuid(),
  hotel_id uuid not null references public.hotels(id) on delete cascade,
  name jsonb not null default '{"fr":"","ar":"","en":""}'::jsonb,
  description jsonb not null default '{"fr":"","ar":"","en":""}'::jsonb,
  base_price numeric(12,2) not null default 0 check (base_price >= 0),
  max_guests integer not null default 1 check (max_guests > 0),
  beds jsonb not null default '[]'::jsonb,
  size_sqm numeric(10,2) not null default 0 check (size_sqm >= 0),
  amenities jsonb not null default '[]'::jsonb,
  images jsonb not null default '[]'::jsonb,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.rooms (
  id uuid primary key default gen_random_uuid(),
  hotel_id uuid not null references public.hotels(id) on delete cascade,
  room_type_id uuid not null references public.room_types(id) on delete restrict,
  room_number text not null,
  floor integer not null default 0,
  status public.room_status not null default 'available',
  notes text not null default '',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(hotel_id, room_number)
);

create table if not exists public.guests (
  id uuid primary key default gen_random_uuid(),
  hotel_id uuid not null references public.hotels(id) on delete cascade,
  first_name text not null,
  last_name text not null,
  email text not null default '',
  phone text not null default '',
  nationality text not null default '',
  document_type public.document_type not null default 'other',
  document_number text not null default '',
  date_of_birth date,
  notes text not null default '',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.reservations (
  id uuid primary key default gen_random_uuid(),
  hotel_id uuid not null references public.hotels(id) on delete cascade,
  booking_reference text not null unique,
  guest_id uuid not null references public.guests(id) on delete restrict,
  room_id uuid not null references public.rooms(id) on delete restrict,
  check_in date not null,
  check_out date not null,
  adults integer not null default 1 check (adults >= 1),
  children integer not null default 0 check (children >= 0),
  status public.reservation_status not null default 'pending',
  source public.reservation_source not null default 'direct',
  total_amount numeric(12,2) not null default 0 check (total_amount >= 0),
  paid_amount numeric(12,2) not null default 0 check (paid_amount >= 0 and paid_amount <= total_amount),
  currency text not null default 'MAD',
  special_requests text not null default '',
  external_reference text,
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (check_out > check_in)
);

alter table public.reservations
  drop constraint if exists reservations_no_double_booking;

alter table public.reservations
  add constraint reservations_no_double_booking
  exclude using gist (
    room_id with =,
    daterange(check_in, check_out, '[)') with &&
  )
  where (status in ('pending','confirmed','checked_in'));

create table if not exists public.services (
  id uuid primary key default gen_random_uuid(),
  hotel_id uuid not null references public.hotels(id) on delete cascade,
  name jsonb not null default '{"fr":"","ar":"","en":""}'::jsonb,
  description jsonb not null default '{"fr":"","ar":"","en":""}'::jsonb,
  price numeric(12,2) not null default 0 check (price >= 0),
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.reservation_services (
  id uuid primary key default gen_random_uuid(),
  hotel_id uuid not null references public.hotels(id) on delete cascade,
  reservation_id uuid not null references public.reservations(id) on delete cascade,
  service_id uuid not null references public.services(id) on delete restrict,
  quantity integer not null default 1 check (quantity > 0),
  unit_price numeric(12,2) not null default 0 check (unit_price >= 0),
  notes text not null default '',
  created_at timestamptz not null default now()
);

create table if not exists public.payments (
  id uuid primary key default gen_random_uuid(),
  hotel_id uuid not null references public.hotels(id) on delete cascade,
  reservation_id uuid not null references public.reservations(id) on delete cascade,
  amount numeric(12,2) not null check (amount > 0),
  method public.payment_method not null default 'cash',
  status public.payment_status not null default 'paid',
  transaction_reference text not null default '',
  notes text not null default '',
  paid_at timestamptz not null default now(),
  created_at timestamptz not null default now()
);

create table if not exists public.housekeeping_tasks (
  id uuid primary key default gen_random_uuid(),
  hotel_id uuid not null references public.hotels(id) on delete cascade,
  room_id uuid not null references public.rooms(id) on delete cascade,
  assigned_to uuid references public.profiles(id) on delete set null,
  task_type public.task_type not null default 'cleaning',
  status public.housekeeping_status not null default 'pending',
  notes text not null default '',
  completed_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.room_status_history (
  id uuid primary key default gen_random_uuid(),
  hotel_id uuid not null references public.hotels(id) on delete cascade,
  room_id uuid not null references public.rooms(id) on delete cascade,
  from_status public.room_status,
  to_status public.room_status not null,
  changed_by uuid references auth.users(id) on delete set null,
  reason text not null default '',
  changed_at timestamptz not null default now()
);

create index if not exists idx_profiles_hotel on public.profiles(hotel_id);
create index if not exists idx_room_types_hotel on public.room_types(hotel_id);
create index if not exists idx_rooms_hotel on public.rooms(hotel_id);
create index if not exists idx_rooms_type on public.rooms(room_type_id);
create index if not exists idx_guests_hotel on public.guests(hotel_id);
create index if not exists idx_reservations_hotel_dates on public.reservations(hotel_id, check_in, check_out);
create index if not exists idx_reservations_room_dates on public.reservations(room_id, check_in, check_out);
create index if not exists idx_payments_hotel_paid_at on public.payments(hotel_id, paid_at);
create index if not exists idx_housekeeping_hotel_status on public.housekeeping_tasks(hotel_id, status);
create index if not exists idx_room_history_room on public.room_status_history(room_id, changed_at desc);

create or replace function public.get_my_hotel_id()
returns uuid
language sql
stable
security definer
set search_path = public
as $$
  select hotel_id from public.profiles where id = auth.uid() limit 1;
$$;

create or replace function public.get_my_role()
returns public.user_role
language sql
stable
security definer
set search_path = public
as $$
  select role from public.profiles where id = auth.uid() limit 1;
$$;

create or replace function public.is_hotel_member(p_hotel_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.profiles
    where id = auth.uid()
      and hotel_id = p_hotel_id
      and active = true
  );
$$;

create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_hotel_id uuid;
begin
  v_hotel_id := nullif(new.raw_user_meta_data->>'hotel_id','')::uuid;

  if v_hotel_id is not null then
    insert into public.profiles (
      id, hotel_id, email, first_name, last_name, role, preferred_language
    )
    values (
      new.id,
      v_hotel_id,
      coalesce(new.email,''),
      coalesce(new.raw_user_meta_data->>'first_name',''),
      coalesce(new.raw_user_meta_data->>'last_name',''),
      coalesce((new.raw_user_meta_data->>'role')::public.user_role, 'receptionist'),
      coalesce(new.raw_user_meta_data->>'preferred_language','fr')
    )
    on conflict (id) do nothing;
  end if;

  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
after insert on auth.users
for each row execute procedure public.handle_new_user();

create or replace function public.touch_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

drop trigger if exists trg_hotels_updated on public.hotels;
create trigger trg_hotels_updated before update on public.hotels for each row execute procedure public.touch_updated_at();

drop trigger if exists trg_profiles_updated on public.profiles;
create trigger trg_profiles_updated before update on public.profiles for each row execute procedure public.touch_updated_at();

drop trigger if exists trg_room_types_updated on public.room_types;
create trigger trg_room_types_updated before update on public.room_types for each row execute procedure public.touch_updated_at();

drop trigger if exists trg_rooms_updated on public.rooms;
create trigger trg_rooms_updated before update on public.rooms for each row execute procedure public.touch_updated_at();

drop trigger if exists trg_guests_updated on public.guests;
create trigger trg_guests_updated before update on public.guests for each row execute procedure public.touch_updated_at();

drop trigger if exists trg_reservations_updated on public.reservations;
create trigger trg_reservations_updated before update on public.reservations for each row execute procedure public.touch_updated_at();

drop trigger if exists trg_services_updated on public.services;
create trigger trg_services_updated before update on public.services for each row execute procedure public.touch_updated_at();

drop trigger if exists trg_housekeeping_updated on public.housekeeping_tasks;
create trigger trg_housekeeping_updated before update on public.housekeeping_tasks for each row execute procedure public.touch_updated_at();

create or replace function public.log_room_status_change()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if old.status is distinct from new.status then
    insert into public.room_status_history (
      hotel_id, room_id, from_status, to_status, changed_by, reason
    )
    values (
      new.hotel_id, new.id, old.status, new.status, auth.uid(), 'status changed'
    );
  end if;
  return new;
end;
$$;

drop trigger if exists trg_room_status_history on public.rooms;
create trigger trg_room_status_history
after update of status on public.rooms
for each row execute procedure public.log_room_status_change();

create or replace function public.generate_booking_reference()
returns text
language plpgsql
as $$
declare
  v_ref text;
begin
  loop
    v_ref := 'HOS-' || extract(year from now())::int || '-' ||
      upper(substr(encode(gen_random_bytes(4),'hex'),1,6));
    exit when not exists (
      select 1 from public.reservations where booking_reference = v_ref
    );
  end loop;
  return v_ref;
end;
$$;

create or replace function public.set_reservation_reference()
returns trigger
language plpgsql
as $$
begin
  if new.booking_reference is null or new.booking_reference = '' then
    new.booking_reference := public.generate_booking_reference();
  end if;
  return new;
end;
$$;

drop trigger if exists trg_reservation_reference on public.reservations;
create trigger trg_reservation_reference
before insert on public.reservations
for each row execute procedure public.set_reservation_reference();

create or replace function public.search_available_rooms(
  p_hotel_id uuid,
  p_check_in date,
  p_check_out date,
  p_guests integer
)
returns table (
  room_id uuid,
  room_number text,
  room_type_id uuid,
  room_type jsonb,
  total_price numeric,
  nights integer
)
language sql
stable
security definer
set search_path = public
as $$
  select
    r.id,
    r.room_number,
    r.room_type_id,
    to_jsonb(rt),
    (rt.base_price * (p_check_out - p_check_in))::numeric,
    (p_check_out - p_check_in)
  from public.rooms r
  join public.room_types rt on rt.id = r.room_type_id
  where r.hotel_id = p_hotel_id
    and rt.hotel_id = p_hotel_id
    and rt.active = true
    and rt.max_guests >= p_guests
    and r.status <> 'out_of_service'
    and not exists (
      select 1
      from public.reservations x
      where x.room_id = r.id
        and x.status in ('pending','confirmed','checked_in')
        and daterange(x.check_in,x.check_out,'[)')
            && daterange(p_check_in,p_check_out,'[)')
    )
  order by rt.base_price, r.room_number;
$$;

-- RLS
alter table public.hotels enable row level security;
alter table public.profiles enable row level security;
alter table public.room_types enable row level security;
alter table public.rooms enable row level security;
alter table public.guests enable row level security;
alter table public.reservations enable row level security;
alter table public.services enable row level security;
alter table public.reservation_services enable row level security;
alter table public.payments enable row level security;
alter table public.housekeeping_tasks enable row level security;
alter table public.room_status_history enable row level security;

drop policy if exists hotels_select_member on public.hotels;
create policy hotels_select_member on public.hotels
for select to authenticated
using (public.is_hotel_member(id));

drop policy if exists hotels_update_manager on public.hotels;
create policy hotels_update_manager on public.hotels
for update to authenticated
using (public.is_hotel_member(id) and public.get_my_role() in ('owner','manager'))
with check (public.is_hotel_member(id));

drop policy if exists profiles_select_member on public.profiles;
create policy profiles_select_member on public.profiles
for select to authenticated
using (public.is_hotel_member(hotel_id));

drop policy if exists profiles_update_self_or_manager on public.profiles;
create policy profiles_update_self_or_manager on public.profiles
for update to authenticated
using (
  id = auth.uid()
  or (public.is_hotel_member(hotel_id) and public.get_my_role() in ('owner','manager'))
)
with check (
  id = auth.uid()
  or (public.is_hotel_member(hotel_id) and public.get_my_role() in ('owner','manager'))
);

drop policy if exists room_types_all_member on public.room_types;
create policy room_types_all_member on public.room_types
for all to authenticated
using (public.is_hotel_member(hotel_id))
with check (public.is_hotel_member(hotel_id));

drop policy if exists rooms_all_member on public.rooms;
create policy rooms_all_member on public.rooms
for all to authenticated
using (public.is_hotel_member(hotel_id))
with check (public.is_hotel_member(hotel_id));

drop policy if exists guests_all_member on public.guests;
create policy guests_all_member on public.guests
for all to authenticated
using (public.is_hotel_member(hotel_id))
with check (public.is_hotel_member(hotel_id));

drop policy if exists reservations_all_member on public.reservations;
create policy reservations_all_member on public.reservations
for all to authenticated
using (public.is_hotel_member(hotel_id))
with check (public.is_hotel_member(hotel_id));

drop policy if exists services_all_member on public.services;
create policy services_all_member on public.services
for all to authenticated
using (public.is_hotel_member(hotel_id))
with check (public.is_hotel_member(hotel_id));

drop policy if exists reservation_services_all_member on public.reservation_services;
create policy reservation_services_all_member on public.reservation_services
for all to authenticated
using (public.is_hotel_member(hotel_id))
with check (public.is_hotel_member(hotel_id));

drop policy if exists payments_all_member on public.payments;
create policy payments_all_member on public.payments
for all to authenticated
using (public.is_hotel_member(hotel_id))
with check (public.is_hotel_member(hotel_id));

drop policy if exists housekeeping_all_member on public.housekeeping_tasks;
create policy housekeeping_all_member on public.housekeeping_tasks
for all to authenticated
using (public.is_hotel_member(hotel_id))
with check (public.is_hotel_member(hotel_id));

drop policy if exists room_history_select_member on public.room_status_history;
create policy room_history_select_member on public.room_status_history
for select to authenticated
using (public.is_hotel_member(hotel_id));

grant execute on function public.search_available_rooms(uuid,date,date,integer) to anon, authenticated;
grant execute on function public.get_my_hotel_id() to authenticated;
grant execute on function public.get_my_role() to authenticated;
grant execute on function public.is_hotel_member(uuid) to authenticated;

-- Public booking portal: availability only.
-- Do NOT grant anon INSERT/UPDATE/DELETE on hotel tables.
