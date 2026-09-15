-- ============================================================================
-- منصة متابعة مكاتب الاقتراع — المخطط الكامل (PostgreSQL / Supabase)
-- يشمل: الجداول العشرون، العزل متعدد المستأجرين، RLS كامل، Triggers
-- ============================================================================

create extension if not exists "pgcrypto";
create extension if not exists "postgis";
create extension if not exists "uuid-ossp";

-- ---------------------------------------------------------------------------
-- 0) Helpers مشتركة
-- ---------------------------------------------------------------------------
create or replace function public.set_updated_at()
returns trigger language plpgsql as $$
begin
  new.updated_at = now();
  return new;
end $$;

-- ---------------------------------------------------------------------------
-- 1) المرجعيات المركزية (لا تخص مستأجراً)
-- ---------------------------------------------------------------------------

create table public.election_years (
  id uuid primary key default gen_random_uuid(),
  year int not null unique,
  label_ar text not null,
  label_fr text not null,
  starts_on date,
  ends_on date,
  is_active boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.election_types (
  id uuid primary key default gen_random_uuid(),
  code text not null unique,           -- legislative | regional | communal | ...
  label_ar text not null,
  label_fr text not null,
  created_at timestamptz not null default now()
);

-- ---------------------------------------------------------------------------
-- 2) الأحزاب والدومينات
-- ---------------------------------------------------------------------------

create table public.parties (
  id uuid primary key default gen_random_uuid(),
  name_ar text not null,
  name_fr text,
  slug text not null unique,
  logo_path text,                       -- مسار في Supabase Storage
  colors jsonb not null default '{"primary":"#1d4ed8","secondary":"#f59e0b"}'::jsonb,
  status text not null default 'pending' check (status in ('pending','active','suspended')),
  profile jsonb not null default '{}'::jsonb,
  data_retention_days int not null default 30,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.party_domains (
  id uuid primary key default gen_random_uuid(),
  party_id uuid not null references public.parties(id) on delete cascade,
  domain text not null unique,
  is_primary boolean not null default false,
  wildcard boolean not null default false,          -- يقبل *.domain
  verification_token text not null,
  verified_at timestamptz,
  ssl_status text not null default 'pending' check (ssl_status in ('pending','issued','failed')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (party_id, is_primary) deferrable initially deferred
);

-- ---------------------------------------------------------------------------
-- 3) المستخدمون والأدوار والصلاحيات
-- ---------------------------------------------------------------------------

create table public.roles (
  id uuid primary key default gen_random_uuid(),
  key text not null unique,             -- superadmin | party_admin | observer | assistant
  label_ar text not null,
  label_fr text not null,
  is_system boolean not null default false,
  created_at timestamptz not null default now()
);

create table public.permissions (
  id uuid primary key default gen_random_uuid(),
  key text not null unique,             -- stations.manage | reports.review | assistants.manage ...
  label_ar text not null,
  label_fr text not null,
  created_at timestamptz not null default now()
);

-- party_members: امتداد مستأجر لـ auth.users
create table public.party_members (
  id uuid primary key default gen_random_uuid(),
  party_id uuid references public.parties(id) on delete cascade,  -- null للـ superadmin فقط
  user_id uuid not null references auth.users(id) on delete cascade,
  role_id uuid not null references public.roles(id),
  permissions jsonb not null default '[]'::jsonb,  -- تجاوزات دقيقة (array of permission keys)
  full_name text not null,
  phone text,
  status text not null default 'active' check (status in ('active','suspended','pending')),
  last_login_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (party_id, user_id)
);

-- ---------------------------------------------------------------------------
-- 4) المراقبون والمساعدون
-- ---------------------------------------------------------------------------

create table public.observers (
  id uuid primary key default gen_random_uuid(),
  party_id uuid not null references public.parties(id) on delete cascade,
  user_id uuid unique references auth.users(id) on delete set null, -- null = مسودة قبل إرسال الدعوة
  full_name text not null,
  phone text,
  national_id bytea,                    -- مشفر عبر pgcrypto (مفتاح تطبيقي)
  status text not null default 'active' check (status in ('active','inactive')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.assistants (
  id uuid primary key default gen_random_uuid(),
  party_id uuid not null references public.parties(id) on delete cascade,
  user_id uuid unique references auth.users(id) on delete set null, -- حساب اختياري
  full_name text not null,
  phone text,
  national_id bytea,                    -- فقط مع أساس قانوني واضح
  voting_place text,                    -- مكان التصويت — إداري فقط، ممنوع استنتاج النية
  city text,
  region text,
  status text not null default 'active' check (status in ('active','inactive')),
  admin_notes text,                     -- ملاحظات إدارية غير سياسية
  added_by uuid references public.party_members(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- ---------------------------------------------------------------------------
-- 5) مكاتب الاقتراع والتعيينات والمواقع
-- ---------------------------------------------------------------------------

create table public.polling_stations (
  id uuid primary key default gen_random_uuid(),
  party_id uuid not null references public.parties(id) on delete cascade,
  station_number text not null,
  name_ar text not null,
  name_fr text,
  address text,
  city text,
  region text,
  location geography(Point, 4326),
  status text not null default 'planned' check (status in ('planned','open','counting','closed','report_received')),
  election_year_id uuid references public.election_years(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (party_id, station_number)
);

create index polling_stations_location_gix on public.polling_stations using gist (location);
create index polling_stations_party_status_idx on public.polling_stations (party_id, status);

create table public.observer_assignments (
  id uuid primary key default gen_random_uuid(),
  party_id uuid not null references public.parties(id) on delete cascade,
  observer_id uuid not null references public.observers(id) on delete cascade,
  polling_station_id uuid not null references public.polling_stations(id) on delete cascade,
  election_year_id uuid not null references public.election_years(id),
  assigned_by uuid references public.party_members(id),
  assigned_at timestamptz not null default now(),
  unique (observer_id, election_year_id)
);

create index observer_assignments_station_idx on public.observer_assignments (party_id, polling_station_id);

create table public.observer_locations (
  id uuid primary key default gen_random_uuid(),
  party_id uuid not null references public.parties(id) on delete cascade,
  observer_id uuid not null references public.observers(id) on delete cascade,
  session_id uuid,                      -- count_sessions
  location geography(Point, 4326) not null,
  accuracy_m float,
  recorded_at timestamptz not null default now(),
  expires_at timestamptz not null        -- TTL: حذف تلقائي بعد انتهاء الوردية + retention
);

create index observer_locations_gix on public.observer_locations using gist (location);
create index observer_locations_observer_idx on public.observer_locations (party_id, observer_id, recorded_at desc);

-- ---------------------------------------------------------------------------
-- 6) جلسات الفرز والإدخالات والمؤشرات المساندة
-- ---------------------------------------------------------------------------

create table public.count_sessions (
  id uuid primary key default gen_random_uuid(),
  party_id uuid not null references public.parties(id) on delete cascade,
  observer_id uuid not null references public.observers(id) on delete cascade,
  polling_station_id uuid not null references public.polling_stations(id),
  election_year_id uuid references public.election_years(id),
  started_at timestamptz not null default now(),
  ended_at timestamptz,
  status text not null default 'open' check (status in ('open','submitted','validated','returned')),
  totals jsonb not null default '{}'::jsonb,   -- {candidate_id: n} — تقديري/مساند فقط
  submitted_at timestamptz,
  reviewed_by uuid references public.party_members(id),
  reviewed_at timestamptz,
  review_note text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index count_sessions_observer_idx on public.count_sessions (party_id, observer_id, started_at desc);

create table public.vote_entries (
  id uuid primary key default gen_random_uuid(),
  party_id uuid not null references public.parties(id) on delete cascade,
  session_id uuid not null references public.count_sessions(id) on delete cascade,
  candidate_code text not null,         -- من القائمة المعتمدة للحزب في تلك السنة
  client_id uuid not null,              -- idempotency key من العميل
  action text not null default 'add' check (action in ('add','revert')),
  created_at timestamptz not null default now(),
  unique (session_id, client_id)        -- منع التكرار عند إعادة الإرسال
);

create table public.support_metrics (
  id uuid primary key default gen_random_uuid(),
  party_id uuid not null references public.parties(id) on delete cascade,
  election_year_id uuid not null references public.election_years(id),
  polling_station_id uuid references public.polling_stations(id) on delete set null,
  metric_type text not null check (metric_type in ('observer_support_count','coverage_estimate')),
  value numeric not null,
  source_type text not null default 'estimate' check (source_type in ('official','entered','estimate','under_review')),
  recorded_at timestamptz not null default now(),
  unique (party_id, election_year_id, polling_station_id, metric_type)
);

-- ---------------------------------------------------------------------------
-- 7) النتائج الرسمية والتقارير
-- ---------------------------------------------------------------------------

create table public.official_results (
  id uuid primary key default gen_random_uuid(),
  election_year_id uuid not null references public.election_years(id),
  election_type_id uuid not null references public.election_types(id),
  polling_station_id uuid references public.polling_stations(id) on delete set null,
  list_code text,
  candidate_name text,
  votes int not null check (votes >= 0),
  source text not null,                 -- مصدر رسمي موثق
  source_url text,
  recorded_at timestamptz not null default now(),
  unique (election_year_id, polling_station_id, list_code, candidate_name)
);

create table public.reports (
  id uuid primary key default gen_random_uuid(),
  party_id uuid not null references public.parties(id) on delete cascade,
  author_type text not null check (author_type in ('observer','party_admin','assistant')),
  author_id uuid not null,
  observer_id uuid references public.observers(id) on delete set null,
  polling_station_id uuid references public.polling_stations(id) on delete set null,
  session_id uuid references public.count_sessions(id) on delete set null,
  kind text not null default 'field_report' check (kind in ('field_report','count_minutes','incident')),
  body text not null,
  status text not null default 'submitted' check (status in ('draft','submitted','reviewed','flagged')),
  submitted_at timestamptz not null default now(),
  reviewed_by uuid references public.party_members(id),
  reviewed_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index reports_party_status_idx on public.reports (party_id, status);

-- ---------------------------------------------------------------------------
-- 8) التدقيق والموافقات
-- ---------------------------------------------------------------------------

create table public.audit_logs (
  id uuid primary key default gen_random_uuid(),
  party_id uuid references public.parties(id) on delete set null,   -- null = حدث مركزي
  actor_id uuid references auth.users(id),
  actor_role text,
  action text not null,                 -- station.create | member.suspend | report.review ...
  entity text not null,
  entity_id uuid,
  metadata jsonb not null default '{}'::jsonb,
  ip inet,
  user_agent text,
  created_at timestamptz not null default now()
);

create table public.consent_records (
  id uuid primary key default gen_random_uuid(),
  party_id uuid references public.parties(id) on delete cascade,
  user_id uuid references auth.users(id) on delete cascade,
  subject_type text not null check (subject_type in ('user','observer')),
  subject_id uuid not null,
  consent_type text not null check (consent_type in ('location_tracking','data_processing','national_id')),
  granted boolean not null,
  consent_text_version text not null,
  granted_at timestamptz not null default now(),
  revoked_at timestamptz,
  context jsonb not null default '{}'::jsonb
);

-- ---------------------------------------------------------------------------
-- 9) Triggers updated_at
-- ---------------------------------------------------------------------------
do $$
declare t text;
begin
  foreach t in array array[
    'election_years','parties','party_domains','party_members',
    'observers','assistants','polling_stations','count_sessions','reports'
  ] loop
    execute format(
      'create trigger trg_%I_updated before update on public.%I
       for each row execute function public.set_updated_at()', t, t);
  end loop;
end $$;

-- ---------------------------------------------------------------------------
-- 10) دوال الأدوار (تُستخدم داخل كل سياسات RLS)
-- ---------------------------------------------------------------------------
create or replace function public.is_superadmin()
returns boolean language sql stable as $$
  select exists (
    select 1 from public.party_members pm
    join public.roles r on r.id = pm.role_id
    where pm.user_id = auth.uid() and r.key = 'superadmin' and pm.status = 'active'
  );
$$;

create or replace function public.my_party_id()
returns uuid language sql stable as $$
  select coalesce(
    (auth.jwt() ->> 'party_id')::uuid,
    (select pm.party_id from public.party_members pm
      where pm.user_id = auth.uid() and pm.party_id is not null limit 1)
  );
$$;

create or replace function public.my_role_key()
returns text language sql stable as $$
  select r.key from public.party_members pm
  join public.roles r on r.id = pm.role_id
  where pm.user_id = auth.uid() and pm.status = 'active'
  order by case r.key when 'superadmin' then 0 when 'party_admin' then 1 else 2 end
  limit 1;
$$;

create or replace function public.my_member_id()
returns uuid language sql stable as $$
  select pm.id from public.party_members pm
  where pm.user_id = auth.uid() and pm.status = 'active' limit 1;
$$;

-- مراقب حالي: observer_id المرتبط بالمستخدم داخل حزبه
create or replace function public.my_observer_id()
returns uuid language sql stable as $$
  select o.id from public.observers o
  where o.user_id = auth.uid() and o.party_id = public.my_party_id() limit 1;
$$;

-- صلاحية دقيقة (للمساعدين والمستخدمين الفرعيين)
create or replace function public.has_permission(p_key text)
returns boolean language sql stable as $$
  select public.my_role_key() in ('superadmin','party_admin')
    or exists (
      select 1 from public.party_members pm
      where pm.user_id = auth.uid() and pm.status = 'active'
        and pm.permissions ? p_key
    );
$$;

-- كتابة سجل تدقيق (security definer — الجدول append-only)
create or replace function public.log_audit(
  p_action text, p_entity text, p_entity_id uuid, p_metadata jsonb default '{}'::jsonb
) returns void language plpgsql security definer set search_path = public as $$
begin
  insert into public.audit_logs (party_id, actor_id, actor_role, action, entity, entity_id, metadata)
  values (public.my_party_id(), auth.uid(), public.my_role_key(), p_action, p_entity, p_entity_id, p_metadata);
end $$;

-- منع أي تعديل/حذف على audit_logs و consent_records
create or replace function public.block_mutation()
returns trigger language plpgsql as $$
begin
  raise exception 'append-only table: % not allowed', TG_OP;
end $$;

-- ============================================================================
-- 11) Row Level Security — العزل الصارم حسب الحزب
-- ============================================================================
alter table public.election_years   enable row level security;
alter table public.election_types   enable row level security;
alter table public.parties          enable row level security;
alter table public.party_domains    enable row level security;
alter table public.roles            enable row level security;
alter table public.permissions      enable row level security;
alter table public.party_members    enable row level security;
alter table public.observers        enable row level security;
alter table public.assistants       enable row level security;
alter table public.polling_stations enable row level security;
alter table public.observer_assignments enable row level security;
alter table public.observer_locations enable row level security;
alter table public.count_sessions   enable row level security;
alter table public.vote_entries     enable row level security;
alter table public.support_metrics  enable row level security;
alter table public.official_results enable row level security;
alter table public.reports          enable row level security;
alter table public.audit_logs       enable row level security;
alter table public.consent_records  enable row level security;

-- تفعيل Realtime على جداول المتابعة المباشرة
alter publication supabase_realtime add table public.observer_locations;
alter publication supabase_realtime add table public.count_sessions;
alter publication supabase_realtime add table public.reports;
alter publication supabase_realtime add table public.support_metrics;

-- ---------------------------------------------------------------------------
-- election_years / election_types — قراءة للجميع، كتابة Superadmin فقط
-- ---------------------------------------------------------------------------
create policy ey_select on public.election_years for select using (true);
create policy ey_write  on public.election_years for all
  using (public.is_superadmin()) with check (public.is_superadmin());

create policy et_select on public.election_types for select using (true);
create policy et_write  on public.election_types for all
  using (public.is_superadmin()) with check (public.is_superadmin());

-- ---------------------------------------------------------------------------
-- parties
-- ---------------------------------------------------------------------------
create policy parties_select on public.parties for select using (true); -- الاسم/الهوية معلنة
create policy parties_insert on public.parties for insert
  with check (public.is_superadmin());
create policy parties_update on public.parties for update
  using (public.is_superadmin()
    or (id = public.my_party_id() and public.my_role_key() = 'party_admin'));

-- ---------------------------------------------------------------------------
-- party_domains — حصري Superadmin (رئيس الحزب لا يرى التوكن ولا يعدّل)
-- ---------------------------------------------------------------------------
create policy domains_select on public.party_domains for select
  using (public.is_superadmin()
    or (party_id = public.my_party_id() and public.my_role_key() = 'party_admin'));
create policy domains_write on public.party_domains for all
  using (public.is_superadmin()) with check (public.is_superadmin());

-- ---------------------------------------------------------------------------
-- roles / permissions — مرجعية للقراءة، كتابة مركزية
-- ---------------------------------------------------------------------------
create policy roles_select on public.roles for select using (true);
create policy roles_write  on public.roles for all
  using (public.is_superadmin()) with check (public.is_superadmin());
create policy perms_select on public.permissions for select using (true);
create policy perms_write  on public.permissions for all
  using (public.is_superadmin()) with check (public.is_superadmin());

-- ---------------------------------------------------------------------------
-- party_members
-- ---------------------------------------------------------------------------
create policy members_select on public.party_members for select using (
  public.is_superadmin()
  or user_id = auth.uid()                                   -- نفسه
  or (party_id = public.my_party_id() and public.my_role_key() = 'party_admin')
);
create policy members_insert on public.party_members for insert with check (
  public.is_superadmin()
  or (party_id = public.my_party_id() and public.my_role_key() = 'party_admin')
);
create policy members_update on public.party_members for update using (
  public.is_superadmin()
  or (party_id = public.my_party_id() and public.my_role_key() = 'party_admin')
) with check (
  public.is_superadmin()
  or (party_id = public.my_party_id() and public.my_role_key() = 'party_admin')
);
create policy members_delete on public.party_members for delete using (
  public.is_superadmin()
  or (party_id = public.my_party_id() and public.my_role_key() = 'party_admin')
);
-- حظر رفع أي مستخدم إلى superadmin من داخل حزب
create policy members_no_privesc on public.party_members for update using (
  public.is_superadmin()
  or not exists (
    select 1 from public.roles r where r.id = (
      select role_id from public.party_members where id = (
        select pm2.id from public.party_members pm2 where pm2.user_id = auth.uid() limit 1))
      and r.key = 'superadmin'
  )
);

-- ---------------------------------------------------------------------------
-- observers
-- ---------------------------------------------------------------------------
create policy observers_select on public.observers for select using (
  public.is_superadmin()
  or (party_id = public.my_party_id() and public.my_role_key() in ('party_admin','assistant'))
  or id = public.my_observer_id()                            -- المراقب يرى سجله فقط
);
create policy observers_write on public.observers for all using (
  public.is_superadmin()
  or (party_id = public.my_party_id() and public.my_role_key() = 'party_admin')
) with check (
  public.is_superadmin()
  or (party_id = public.my_party_id() and public.my_role_key() = 'party_admin')
);

-- ---------------------------------------------------------------------------
-- assistants — رئيس الحزب، والمساعد صلاحية assistants.manage
-- ---------------------------------------------------------------------------
create policy assistants_select on public.assistants for select using (
  public.is_superadmin()
  or (party_id = public.my_party_id() and public.my_role_key() = 'party_admin')
  or (party_id = public.my_party_id() and public.has_permission('assistants.read'))
);
create policy assistants_insert on public.assistants for insert with check (
  (party_id = public.my_party_id() and public.my_role_key() = 'party_admin')
  or public.has_permission('assistants.manage')
);
create policy assistants_update on public.assistants for update using (
  (party_id = public.my_party_id() and public.my_role_key() = 'party_admin')
  or public.has_permission('assistants.manage')
) with check (
  (party_id = public.my_party_id() and public.my_role_key() = 'party_admin')
  or public.has_permission('assistants.manage')
);
create policy assistants_delete on public.assistants for delete using (
  (party_id = public.my_party_id() and public.my_role_key() = 'party_admin')
  or public.has_permission('assistants.manage')
);

-- ---------------------------------------------------------------------------
-- polling_stations — قراءة لأعضاء الحزب، كتابة رئيس الحزب، مراقب: مكتبه فقط
-- ---------------------------------------------------------------------------
create policy stations_select on public.polling_stations for select using (
  public.is_superadmin()
  or party_id = public.my_party_id()
);
create policy stations_write on public.polling_stations for all using (
  public.is_superadmin()
  or (party_id = public.my_party_id() and public.my_role_key() = 'party_admin')
) with check (
  public.is_superadmin()
  or (party_id = public.my_party_id() and public.my_role_key() = 'party_admin')
);

-- ---------------------------------------------------------------------------
-- observer_assignments — المراقب يرى تعيينه فقط
-- ---------------------------------------------------------------------------
create policy assign_select on public.observer_assignments for select using (
  public.is_superadmin()
  or (party_id = public.my_party_id() and public.my_role_key() = 'party_admin')
  or observer_id = public.my_observer_id()
);
create policy assign_write on public.observer_assignments for all using (
  public.is_superadmin()
  or (party_id = public.my_party_id() and public.my_role_key() = 'party_admin')
) with check (
  public.is_superadmin()
  or (party_id = public.my_party_id() and public.my_role_key() = 'party_admin')
);

-- ---------------------------------------------------------------------------
-- observer_locations — المراقب يكتب موقعه فقط وبموافقة سارية
-- ---------------------------------------------------------------------------
create policy locations_select on public.observer_locations for select using (
  public.is_superadmin()
  or (party_id = public.my_party_id() and public.my_role_key() = 'party_admin')
);
create policy locations_insert on public.observer_locations for insert with check (
  party_id = public.my_party_id()
  and observer_id = public.my_observer_id()
  and exists (
    select 1 from public.consent_records c
    where c.subject_id = observer_id and c.consent_type = 'location_tracking'
      and c.granted = true and c.revoked_at is null
  )
);
create policy locations_no_update on public.observer_locations for update using (false);
create policy locations_delete on public.observer_locations for delete using (
  public.is_superadmin()   -- الحذف عبر وظيفة التنظيف المجدول فقط
);

-- ---------------------------------------------------------------------------
-- count_sessions — المراقب: جلساته فقط
-- ---------------------------------------------------------------------------
create policy sessions_select on public.count_sessions for select using (
  public.is_superadmin()
  or (party_id = public.my_party_id() and public.my_role_key() = 'party_admin')
  or observer_id = public.my_observer_id()
);
create policy sessions_insert on public.count_sessions for insert with check (
  party_id = public.my_party_id() and observer_id = public.my_observer_id()
);
create policy sessions_update_own on public.count_sessions for update using (
  (party_id = public.my_party_id() and observer_id = public.my_observer_id()
   and status in ('open','submitted'))
) with check (
  (party_id = public.my_party_id() and observer_id = public.my_observer_id()
   and status in ('open','submitted'))
);
-- رئيس الحزب يراجع: validated / returned فقط، ولا يعدّل totals
create policy sessions_review on public.count_sessions for update using (
  (party_id = public.my_party_id() and public.my_role_key() = 'party_admin'
   and status = 'submitted')
) with check (
  (party_id = public.my_party_id() and public.my_role_key() = 'party_admin'
   and status in ('validated','returned'))
);

-- ---------------------------------------------------------------------------
-- vote_entries — إدخال/تراجع المراقب في جلسته المفتوحة فقط
-- ---------------------------------------------------------------------------
create policy entries_select on public.vote_entries for select using (
  public.is_superadmin()
  or (party_id = public.my_party_id() and public.my_role_key() = 'party_admin')
  or exists (
    select 1 from public.count_sessions s
    where s.id = session_id and s.observer_id = public.my_observer_id()
  )
);
create policy entries_insert on public.vote_entries for insert with check (
  party_id = public.my_party_id()
  and action in ('add','revert')
  and exists (
    select 1 from public.count_sessions s
    where s.id = session_id and s.observer_id = public.my_observer_id()
      and s.status = 'open'
  )
);
create policy entries_no_mutate on public.vote_entries for update using (false);
create policy entries_no_delete on public.vote_entries for delete using (false);

-- ---------------------------------------------------------------------------
-- support_metrics — كتابة رئيس الحزب/المراقب (تقديري)، قراءة أعضاء الحزب
-- ---------------------------------------------------------------------------
create policy metrics_select on public.support_metrics for select using (
  public.is_superadmin() or party_id = public.my_party_id()
);
create policy metrics_write on public.support_metrics for all using (
  public.is_superadmin()
  or (party_id = public.my_party_id() and public.my_role_key() in ('party_admin','observer'))
) with check (
  public.is_superadmin()
  or (party_id = public.my_party_id() and public.my_role_key() in ('party_admin','observer'))
);

-- ---------------------------------------------------------------------------
-- official_results — قراءة للجميع، كتابة Superadmin فقط (مصدر رسمي)
-- ---------------------------------------------------------------------------
create policy results_select on public.official_results for select using (true);
create policy results_write on public.official_results for all
  using (public.is_superadmin()) with check (public.is_superadmin());

-- ---------------------------------------------------------------------------
-- reports — المؤلف يكتب، رئيس الحزب يراجع
-- ---------------------------------------------------------------------------
create policy reports_select on public.reports for select using (
  public.is_superadmin()
  or (party_id = public.my_party_id() and public.my_role_key() = 'party_admin')
  or (author_type = 'observer' and author_id = public.my_observer_id())
);
create policy reports_insert on public.reports for insert with check (
  party_id = public.my_party_id()
  and ((author_type = 'observer' and author_id = public.my_observer_id())
       or public.has_permission('reports.create'))
);
create policy reports_update_author on public.reports for update using (
  author_type = 'observer' and author_id = public.my_observer_id()
  and status in ('draft','submitted')
) with check (
  author_type = 'observer' and author_id = public.my_observer_id()
  and status in ('draft','submitted')
);
create policy reports_review on public.reports for update using (
  party_id = public.my_party_id() and public.my_role_key() = 'party_admin'
  and status in ('submitted','flagged')
) with check (
  party_id = public.my_party_id() and public.my_role_key() = 'party_admin'
  and status in ('reviewed','flagged')
);

-- ---------------------------------------------------------------------------
-- audit_logs — قراءة حسب النطاق، الكتابة عبر log_audit فقط (definer)
-- ---------------------------------------------------------------------------
create policy audit_select on public.audit_logs for select using (
  public.is_superadmin()
  or (party_id = public.my_party_id() and public.my_role_key() = 'party_admin')
);
create trigger trg_audit_block_update before update on public.audit_logs
  for each row execute function public.block_mutation();
create trigger trg_audit_block_delete before delete on public.audit_logs
  for each statement execute function public.block_mutation();

-- ---------------------------------------------------------------------------
-- consent_records — الموافقات (append-only)
-- ---------------------------------------------------------------------------
create policy consent_select on public.consent_records for select using (
  public.is_superadmin()
  or (party_id = public.my_party_id() and public.my_role_key() = 'party_admin')
  or user_id = auth.uid()
);
create policy consent_insert on public.consent_records for insert with check (
  (party_id = public.my_party_id() and user_id = auth.uid())
  or public.is_superadmin()
);
create trigger trg_consent_block_update before update on public.consent_records
  for each row execute function public.block_mutation();
create trigger trg_consent_block_delete before delete on public.consent_records
  for each statement execute function public.block_mutation();
-- السحب = إدراج سجل جديد granted=false (لا تعديل للتاريخ)

-- ---------------------------------------------------------------------------
-- 12) Trigger: تحديث totals في count_sessions عند كل vote_entry
-- ---------------------------------------------------------------------------
create or replace function public.apply_vote_entry()
returns trigger language plpgsql security definer set search_path = public as $$
declare cur int;
begin
  select coalesce((new.totals ->> new.candidate_code)::int, 0) into cur
  from public.count_sessions where id = new.session_id for update;

  update public.count_sessions
  set totals = jsonb_set(
         totals,
         array[new.candidate_code],
         to_jsonb(greatest(0, cur + case when new.action = 'add' then 1 else -1 end))
       )
  where id = new.session_id;

  return new;
end $$;

create trigger trg_vote_entry_apply
  after insert on public.vote_entries
  for each row execute function public.apply_vote_entry();

-- ---------------------------------------------------------------------------
-- 13) تنظيف المواقع المنتهية الصلاحية (يشغّل pg_cron كل 10 دقائق)
-- ---------------------------------------------------------------------------
create or replace function public.purge_expired_locations()
returns void language plpgsql security definer set search_path = public as $$
begin
  delete from public.observer_locations where expires_at < now();
end $$;
