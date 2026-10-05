-- =====================================================================
--  restaurant_qr_ordering.sql
--  ترحيل إضافي (Additive-only) لدعم «طلب QR من الطاولة» في تطبيق
--  «متتبع المبيعات اليومية» — وحدة المطعم (Phase 7A).
--
--  ✅ آمن للتشغيل على قاعدة موجودة:
--     - لا يحذف أي جدول/عمود/سياسة موجودة (لا DROP نهائيًا).
--     - كل الجداول والدوال جديدة ومُسماة بأسماء خاصة بهذه الميزة.
--     - IF NOT EXISTS / CREATE OR REPLACE في كل مكان — قابل لإعادة التشغيل.
--
--  🔐 نموذج الأمان:
--     - RLS مفعّلة على كل الجداول الجديدة ولا تُعطَّل أبدًا.
--     - التاجر (صاحب المتجر) يصل عبر جلسة Supabase Auth الحقيقية:
--       auth.uid() = store_id  (نفس نمط الجداول الموجودة).
--     - الزبون (صفحة restaurant-order.html) يستخدم مفتاح anon فقط ولا يقرأ
--       أي جدول مباشرة — يمرّ حصرًا عبر دوال SECURITY DEFINER أدناه تُرجع
--       الحد الأدنى من المعلومات المرتبطة برمز QR غير القابل للتخمين.
--     - لا يظهر service_role في أي ملف واجهة إطلاقًا.
--     - الأسعار تُحسب في الخادم من qr_menu_items ولا تُؤخذ من المتصفح أبدًا.
--     - لا تُرجع أي دالة عامة SQLERRM أو تفاصيل قاعدة البيانات — رموز خطأ ثابتة فقط.
--
--  التشغيل: انسخ كامل الملف إلى Supabase Dashboard → SQL Editor → Run.
-- =====================================================================

begin;

-- ---------------------------------------------------------------------
-- 1) رموز QR للطاولات
--    الصف الواحد = طاولة واحدة لدى متجر واحد. إعادة التوليد = إنشاء صف
--    جديد بـ token جديد وتعليم القديم revoked = true (لا حذف).
-- ---------------------------------------------------------------------
create table if not exists public.restaurant_table_qr (
  id           uuid primary key default gen_random_uuid(),
  store_id     uuid not null,
  table_ref    text not null,              -- معرّف الطاولة المحلي في التطبيق
  table_name   text not null default '',
  table_number integer not null default 0,
  token        text not null unique,       -- رمز عشوائي قوي (≥ 128bit)
  revoked      boolean not null default false,
  created_at   timestamptz not null default now(),
  constraint restaurant_table_qr_store_table_key unique (store_id, table_ref)
);

create index if not exists restaurant_table_qr_store_idx  on public.restaurant_table_qr (store_id);
create index if not exists restaurant_table_qr_token_idx  on public.restaurant_table_qr (token) where not revoked;

alter table public.restaurant_table_qr enable row level security;

-- التاجر يدير رموز متجره فقط
drop policy if exists "restaurant_table_qr_owner_all" on public.restaurant_table_qr;
create policy "restaurant_table_qr_owner_all"
  on public.restaurant_table_qr for all
  using (auth.uid() = store_id)
  with check (auth.uid() = store_id);

-- ---------------------------------------------------------------------
-- 2) مرآة قائمة الطعام (Menu mirror)
--    التاجر يدفع منتجاته (الاسم/السعر/الصورة/الوصف/التوفر) إلى هنا.
--    مصدر الحقيقة للأسعار في طلبات QR — لا نثق بأي سعر من المتصفح.
-- ---------------------------------------------------------------------
create table if not exists public.qr_menu_items (
  store_id    uuid not null,
  product_id  text not null,               -- معرّف المنتج المحلي في التطبيق
  name        text not null,
  price       numeric(12,2) not null check (price >= 0),
  category    text not null default '',
  description text not null default '',
  image_url   text not null default '',
  available   boolean not null default true,
  sort_order  integer not null default 0,
  updated_at  timestamptz not null default now(),
  constraint qr_menu_items_pkey primary key (store_id, product_id)
);

create index if not exists qr_menu_items_store_idx on public.qr_menu_items (store_id);

alter table public.qr_menu_items enable row level security;

drop policy if exists "qr_menu_items_owner_all" on public.qr_menu_items;
create policy "qr_menu_items_owner_all"
  on public.qr_menu_items for all
  using (auth.uid() = store_id)
  with check (auth.uid() = store_id);

-- ---------------------------------------------------------------------
-- 3) طلبات QR الواردة من الزبائن
--    ملخص وارد فقط؛ الطلب التشغيلي الحقيقي يعيش في التطبيق
--    (st_restaurant_orders) ويُستورد من هذا الجدول. لا خصم مخزون هنا.
-- ---------------------------------------------------------------------
create table if not exists public.qr_orders (
  id           uuid primary key default gen_random_uuid(),
  store_id     uuid not null,
  table_ref    text not null,
  table_name   text not null default '',
  table_number integer not null default 0,
  client_ref   text not null,              -- مفتاح عدم التكرار من الزبون
  order_token  text not null unique,       -- رمز متابعة غير قابل للتخمين
  status       text not null default 'PLACED'
               check (status in ('PLACED','CONFIRMED','PREPARING','READY','COMPLETED','CANCELLED')),
  notes        text not null default '',
  total        numeric(12,2) not null default 0,
  currency     text not null default 'MAD',
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  constraint qr_orders_store_clientref_key unique (store_id, client_ref)
);

create index if not exists qr_orders_store_idx    on public.qr_orders (store_id, created_at desc);
create index if not exists qr_orders_status_idx   on public.qr_orders (store_id, status);

alter table public.qr_orders enable row level security;

drop policy if exists "qr_orders_owner_all" on public.qr_orders;
create policy "qr_orders_owner_all"
  on public.qr_orders for all
  using (auth.uid() = store_id)
  with check (auth.uid() = store_id);

create table if not exists public.qr_order_items (
  id          uuid primary key default gen_random_uuid(),
  order_id    uuid not null references public.qr_orders(id) on delete cascade,
  store_id    uuid not null,
  product_id  text not null,
  name        text not null,
  unit_price  numeric(12,2) not null check (unit_price >= 0),
  quantity    integer not null check (quantity >= 1 and quantity <= 99),
  notes       text not null default '',
  created_at  timestamptz not null default now()
);

create index if not exists qr_order_items_order_idx on public.qr_order_items (order_id);
create index if not exists qr_order_items_store_idx on public.qr_order_items (store_id);

alter table public.qr_order_items enable row level security;

drop policy if exists "qr_order_items_owner_all" on public.qr_order_items;
create policy "qr_order_items_owner_all"
  on public.qr_order_items for all
  using (auth.uid() = store_id)
  with check (auth.uid() = store_id);

-- =====================================================================
-- 4) دوال عامة آمنة لصفحة الزبون (anon عبر SECURITY DEFINER)
--    كل دالة: تتحقق من الرمز، لا تُرجع إلا الحد الأدنى، وتعزل المتاجر
--    تلقائيًا لأن كل شيء مشتق من token الطاولة نفسه.
-- =====================================================================

-- 4.1 حلّ رمز الطاولة: معلومات عامة آمنة فقط (لا بيانات تاجر حساسة)
create or replace function public.resolve_restaurant_table_by_token(p_token text)
returns table (store_id uuid, table_ref text, table_name text, table_number integer)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if p_token is null or length(p_token) < 16 or length(p_token) > 128 then
    return; -- رمز غير صالح شكلًا = غير موجود
  end if;
  return query
    select q.store_id, q.table_ref, q.table_name, q.table_number
    from public.restaurant_table_qr q
    where q.token = p_token and not q.revoked
    limit 1;
end;
$$;

-- 4.2 قائمة الطعام لرمز طاولة (المتاح فقط)
create or replace function public.get_qr_menu(p_token text)
returns table (product_id text, name text, price numeric, category text,
               description text, image_url text, sort_order integer)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_store uuid;
begin
  select q.store_id into v_store
  from public.restaurant_table_qr q
  where q.token = p_token and not q.revoked
  limit 1;
  if v_store is null then return; end if;
  return query
    select m.product_id, m.name, m.price, m.category, m.description, m.image_url, m.sort_order
    from public.qr_menu_items m
    where m.store_id = v_store and m.available
    order by m.sort_order, m.category, m.name;
end;
$$;

-- 4.3 إنشاء طلب QR — تحقق كامل في الخادم:
--     * الرمز صالح وغير ملغى
--     * client_ref يمنع التكرار (إعادة الإرسال تُرجع الطلب نفسه)
--     * الكميات 1..99 وعدد البنود ≤ 50
--     * الأسعار تُقرأ من qr_menu_items فقط — أي سعر من المتصفح يُتجاهَل
--     * المنتج غير المتاح/غير الموجود يُرفَض
create or replace function public.create_qr_order(
  p_token      text,
  p_client_ref text,
  p_items      jsonb,           -- [{"product_id":"…","quantity":2,"notes":"…"}]
  p_notes      text default ''
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_table   public.restaurant_table_qr%rowtype;
  v_existing public.qr_orders%rowtype;
  v_item    jsonb;
  v_menu    public.qr_menu_items%rowtype;
  v_total   numeric(12,2) := 0;
  v_order   public.qr_orders%rowtype;
  v_pid     text;
  v_qty     integer;
  v_notes   text;
  v_count   integer := 0;
begin
  -- الرمز
  select * into v_table from public.restaurant_table_qr q
  where q.token = p_token and not q.revoked limit 1;
  if not found then
    return jsonb_build_object('ok', false, 'error', 'invalid_token');
  end if;

  -- عدم التكرار
  if p_client_ref is null or length(p_client_ref) < 8 or length(p_client_ref) > 128 then
    return jsonb_build_object('ok', false, 'error', 'invalid_client_ref');
  end if;
  select * into v_existing from public.qr_orders o
  where o.store_id = v_table.store_id and o.client_ref = p_client_ref limit 1;
  if found then
    return jsonb_build_object('ok', true, 'duplicate', true,
      'order_token', v_existing.order_token, 'status', v_existing.status,
      'total', v_existing.total, 'currency', v_existing.currency,
      'created_at', v_existing.created_at);
  end if;

  -- بنود صالحة؟
  if p_items is null or jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 then
    return jsonb_build_object('ok', false, 'error', 'empty_items');
  end if;
  if jsonb_array_length(p_items) > 50 then
    return jsonb_build_object('ok', false, 'error', 'too_many_items');
  end if;

  -- إنشاء الطلب أولًا (client_ref unique يحمي من السباق المزدوج)
  insert into public.qr_orders (store_id, table_ref, table_name, table_number,
                                client_ref, order_token, status, notes, total)
  values (v_table.store_id, v_table.table_ref, v_table.table_name, v_table.table_number,
          p_client_ref, replace(gen_random_uuid()::text, '-', '') || replace(gen_random_uuid()::text, '-', ''),
          'PLACED', left(coalesce(p_notes, ''), 500), 0)
  returning * into v_order;

  -- البنود: السعر من قاعدة البيانات حصرًا
  for v_item in select * from jsonb_array_elements(p_items)
  loop
    v_count := v_count + 1;
    v_pid   := coalesce(v_item->>'product_id', '');
    v_qty   := coalesce((v_item->>'quantity')::integer, 0);
    v_notes := left(coalesce(v_item->>'notes', ''), 200);
    if v_qty < 1 or v_qty > 99 then
      raise exception 'bad_quantity' using errcode = 'P0001';
    end if;
    select * into v_menu from public.qr_menu_items m
    where m.store_id = v_table.store_id and m.product_id = v_pid and m.available
    limit 1;
    if not found then
      raise exception 'unavailable_product' using errcode = 'P0001';
    end if;
    insert into public.qr_order_items (order_id, store_id, product_id, name, unit_price, quantity, notes)
    values (v_order.id, v_table.store_id, v_menu.product_id, v_menu.name, v_menu.price, v_qty, v_notes);
    v_total := v_total + v_menu.price * v_qty;
  end loop;

  update public.qr_orders set total = v_total, updated_at = now() where id = v_order.id;

  return jsonb_build_object('ok', true, 'duplicate', false,
    'order_token', v_order.order_token, 'status', 'PLACED',
    'total', v_total, 'currency', v_order.currency,
    'created_at', v_order.created_at);

exception when others then
  -- التراجع تلقائي: أي فشل في بند يلغي الطلب كله (لا طلب جزئي).
  -- لا نُرجع SQLERRM/تفاصيل PostgreSQL للزائر المجهول إطلاقًا:
  -- نُمرّر فقط رموز أعمال معروفة مرفوعة عمدًا، وأي شيء آخر = server_error.
  if sqlerrm = 'bad_quantity' then
    return jsonb_build_object('ok', false, 'error', 'bad_quantity');
  elsif sqlerrm = 'unavailable_product' then
    return jsonb_build_object('ok', false, 'error', 'unavailable_product');
  end if;
  return jsonb_build_object('ok', false, 'error', 'server_error');
end;
$$;

-- 4.4 متابعة حالة الطلب برمز المتابعة فقط (بدون جلسة)
create or replace function public.get_qr_order_status(p_order_token text)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_order public.qr_orders%rowtype;
  v_items jsonb;
begin
  if p_order_token is null or length(p_order_token) < 32 or length(p_order_token) > 128 then
    return jsonb_build_object('ok', false, 'error', 'invalid_order_token');
  end if;
  select * into v_order from public.qr_orders o where o.order_token = p_order_token limit 1;
  if not found then
    return jsonb_build_object('ok', false, 'error', 'not_found');
  end if;
  select coalesce(jsonb_agg(jsonb_build_object(
           'name', i.name, 'quantity', i.quantity,
           'unit_price', i.unit_price, 'notes', i.notes) order by i.created_at), '[]'::jsonb)
    into v_items
  from public.qr_order_items i where i.order_id = v_order.id;
  return jsonb_build_object(
    'ok', true, 'status', v_order.status, 'total', v_order.total,
    'currency', v_order.currency, 'table_name', v_order.table_name,
    'notes', v_order.notes, 'items', v_items,
    'created_at', v_order.created_at, 'updated_at', v_order.updated_at);
end;
$$;

-- صلاحيات التنفيذ للدور العام (anon) والموثَّق (authenticated) — الدوال نفسها
-- تفرض الأمان؛ الجداول تبقى محمية بـ RLS ولا وصول مباشر لـ anon عليها.
grant execute on function public.resolve_restaurant_table_by_token(text) to anon, authenticated;
grant execute on function public.get_qr_menu(text) to anon, authenticated;
grant execute on function public.create_qr_order(text, text, jsonb, text) to anon, authenticated;
grant execute on function public.get_qr_order_status(text) to anon, authenticated;

-- =====================================================================
-- 5) تفعيل Realtime على qr_orders حتى تصل الطلبات الجديدة فورًا للتاجر
--    (آمن إن كان المنشور موجودًا؛ التكرار يُتجاهَل عبر الاستثناء)
-- =====================================================================
do $$
begin
  alter publication supabase_realtime add table public.qr_orders;
exception
  when duplicate_object then null;
  when undefined_object then null; -- لا يوجد publication في بعض المشاريع — التطبيق يعود للـ polling تلقائيًا
end $$;

commit;

-- ✅ انتهى. تحقق سريع بعد التشغيل:
--   select * from public.resolve_restaurant_table_by_token('رمز-طاولة-حقيقي');
--   يجب أن يُرجع صفًا واحدًا (أو لا شيء إن كان الرمز خاطئًا).
