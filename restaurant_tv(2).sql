-- =====================================================================
--  restaurant_tv.sql
--  ترحيل إضافي (Additive-only) — شاشة عرض TV لطلبات QR (Phase 8).
--
--  ✅ لا يحذف/يعدّل أي جدول موجود. قابل لإعادة التشغيل.
--  🔐 التاجر عبر auth.uid() = store_id فقط. شاشة TV تمرّ حصرًا عبر
--     دالتَي RPC عامتين (SECURITY DEFINER) لا تُرجعان أي بيانات مالية
--     أو شخصية — رقم طلب عام + طاولة + أصناف + كميات + حالة فقط.
--  التشغيل: Supabase Dashboard → SQL Editor → Run.
-- =====================================================================

begin;

-- ---------------------------------------------------------------------
-- 1) شاشات العرض (رموز TV) — منفصلة تمامًا عن رموز طاولات QR
-- ---------------------------------------------------------------------
create table if not exists public.restaurant_tv_displays (
  id           uuid primary key default gen_random_uuid(),
  store_id     uuid not null,
  display_ref  text not null,              -- معرّف محلي في تطبيق التاجر
  name         text not null default '',
  token        text not null unique,       -- ≥ 256bit عشوائي
  active       boolean not null default true,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  last_seen_at timestamptz,
  constraint restaurant_tv_displays_store_ref_key unique (store_id, display_ref)
);

create index if not exists restaurant_tv_displays_store_idx on public.restaurant_tv_displays (store_id);
create index if not exists restaurant_tv_displays_token_idx on public.restaurant_tv_displays (token) where active;

alter table public.restaurant_tv_displays enable row level security;

drop policy if exists "restaurant_tv_displays_owner_all" on public.restaurant_tv_displays;
create policy "restaurant_tv_displays_owner_all"
  on public.restaurant_tv_displays for all
  using (auth.uid() = store_id)
  with check (auth.uid() = store_id);

-- ---------------------------------------------------------------------
-- 2) resolve_tv_display: يتحقق من رمز TV ويُرجع اسمًا عامًا آمنًا فقط
--    (اسم الشاشة + اسم المطعم). يحدّث last_seen_at كأثر جانبي آمن.
-- ---------------------------------------------------------------------
create or replace function public.resolve_tv_display(p_token text)
returns table (display_name text, store_name text)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_display public.restaurant_tv_displays%rowtype;
  v_store_name text := '';
begin
  if p_token is null or length(p_token) < 16 or length(p_token) > 128 then
    return;
  end if;
  select * into v_display from public.restaurant_tv_displays d
  where d.token = p_token and d.active
  limit 1;
  if not found then return; end if;
  update public.restaurant_tv_displays set last_seen_at = now() where id = v_display.id;
  begin
    select coalesce(s.store_name, '') into v_store_name
    from public.stores s where s.id = v_display.store_id;
  exception when others then
    v_store_name := ''; -- اسم المتجر تجميلي فقط — لا نفشل بسببه
  end;
  return query select v_display.name, v_store_name;
end;
$$;

-- ---------------------------------------------------------------------
-- 3) get_tv_orders: الطلبات النشطة لمتجر مالك الرمز — بيانات عرض فقط.
--    🚫 لا أسعار، لا إجماليات، لا دفع، لا هواتف، لا أسماء زبائن، لا معرّفات داخلية.
--    المرجع العام = أول 4 أحرف من order_token (مثل #A82F).
--    يشمل المكتملة/الملغاة لآخر 90 ثانية فقط كي تعرض الشاشة انتقالًا ثم تُزيلها.
-- ---------------------------------------------------------------------
create or replace function public.get_tv_orders(p_token text)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_store uuid;
  v_result jsonb;
begin
  if p_token is null or length(p_token) < 16 or length(p_token) > 128 then
    return jsonb_build_object('ok', false, 'error', 'invalid_token');
  end if;
  select d.store_id into v_store from public.restaurant_tv_displays d
  where d.token = p_token and d.active
  limit 1;
  if v_store is null then
    return jsonb_build_object('ok', false, 'error', 'invalid_token');
  end if;

  select coalesce(jsonb_agg(ord ORDER BY ord->>'created_at'), '[]'::jsonb)
    into v_result
  from (
    select jsonb_build_object(
      'ref', upper(substr(o.order_token, 1, 4)),
      'table_number', o.table_number,
      'status', o.status,
      'created_at', o.created_at,
      'updated_at', o.updated_at,
      'items', (
        select coalesce(jsonb_agg(jsonb_build_object(
                 'name', i.name, 'quantity', i.quantity, 'notes', i.notes)
                 order by i.created_at), '[]'::jsonb)
        from public.qr_order_items i
        where i.order_id = o.id
      )
    ) as ord
    from public.qr_orders o
    where o.store_id = v_store
      and (
        o.status in ('PLACED', 'CONFIRMED', 'PREPARING', 'READY')
        or o.updated_at > now() - interval '90 seconds'
      )
  ) t;

  return jsonb_build_object('ok', true, 'orders', v_result);

exception when others then
  -- لا تفاصيل قاعدة بيانات للشاشة العامة إطلاقًا
  return jsonb_build_object('ok', false, 'error', 'server_error');
end;
$$;

grant execute on function public.resolve_tv_display(text) to anon, authenticated;
grant execute on function public.get_tv_orders(text) to anon, authenticated;

commit;

-- ✅ تحقق سريع: select public.get_tv_orders('رمز-شاشة-حقيقي');
