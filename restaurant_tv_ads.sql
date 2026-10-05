-- =====================================================================
--  restaurant_tv_ads.sql
--  ترحيل إضافي (Additive-only) — إعلانات وعروض شاشة TV (Phase 9).
--
--  ✅ لا يحذف/يعدّل أي جدول أو دالة أو سياسة موجودة (Phase 7/8 تبقى كما هي).
--  ✅ قابل لإعادة التشغيل (IF NOT EXISTS / CREATE OR REPLACE / drop policy if exists).
--
--  🔐 نموذج الأمان:
--     - التاجر يدير إعلانات متجره فقط عبر auth.uid() = store_id (RLS).
--     - شاشة TV (anon) لا تقرأ الجدول مباشرة — تمرّ حصرًا عبر
--       get_tv_ads(p_token) التي تشتق store_id من رمز TV نفسه.
--     - لا service_role في أي متصفح. لا سياسات anon على الجدول.
--     - الصور في bucket عام القراءة (قراءة فقط) — الكتابة للمالك فقط
--       داخل مجلد متجره {store_id}/...
--  التشغيل: Supabase Dashboard → SQL Editor → Run.
-- =====================================================================

begin;

-- ---------------------------------------------------------------------
-- 1) جدول الإعلانات — مرتبط بالمتجر (لا بنسخة شاشة معيّنة):
--    كل شاشات TV للمطعم تعرض نفس الإعلانات.
-- ---------------------------------------------------------------------
create table if not exists public.restaurant_tv_ads (
  id              uuid primary key default gen_random_uuid(),
  store_id        uuid not null,
  title           text not null default '',
  description     text not null default '',
  image_url       text not null,
  active          boolean not null default true,
  sort_order      integer not null default 0,
  display_seconds integer not null default 8
                  check (display_seconds between 3 and 30),  -- 3..30 ثانية
  starts_at       timestamptz,                               -- اختياري: نافذة عرض
  ends_at         timestamptz,                               -- اختياري
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now()
);

create index if not exists restaurant_tv_ads_store_idx
  on public.restaurant_tv_ads (store_id, active, sort_order);

alter table public.restaurant_tv_ads enable row level security;

-- التاجر: كل العمليات على إعلانات متجره فقط — لا وصول لـ anon إطلاقًا
drop policy if exists "restaurant_tv_ads_owner_all" on public.restaurant_tv_ads;
create policy "restaurant_tv_ads_owner_all"
  on public.restaurant_tv_ads for all
  using (auth.uid() = store_id)
  with check (auth.uid() = store_id);

-- ---------------------------------------------------------------------
-- 2) get_tv_ads(p_token): مصدر الإعلانات الوحيد لشاشة TV.
--    يتحقق من رمز TV (شاشة فعّالة)، يشتق store_id منه، ويُرجع الإعلانات
--    الفعّالة ضمن نافذة العرض فقط — حقول آمنة بلا أي بيانات مالية/شخصية.
-- ---------------------------------------------------------------------
create or replace function public.get_tv_ads(p_token text)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_display public.restaurant_tv_displays%rowtype;
  v_ads     jsonb;
begin
  if p_token is null or length(p_token) < 16 or length(p_token) > 128 then
    return jsonb_build_object('ok', false, 'error', 'invalid_token');
  end if;

  select * into v_display from public.restaurant_tv_displays d
  where d.token = p_token and d.active
  limit 1;
  if not found then
    return jsonb_build_object('ok', false, 'error', 'invalid_token');
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
           'id', a.id,
           'title', a.title,
           'description', a.description,
           'image_url', a.image_url,
           'sort_order', a.sort_order,
           'display_seconds', a.display_seconds)
         order by a.sort_order, a.created_at), '[]'::jsonb)
    into v_ads
  from public.restaurant_tv_ads a
  where a.store_id = v_display.store_id
    and a.active
    and (a.starts_at is null or a.starts_at <= now())
    and (a.ends_at   is null or a.ends_at   >= now());

  return jsonb_build_object('ok', true, 'ads', v_ads);

exception when others then
  -- لا SQLERRM للزائر المجهول إطلاقًا
  return jsonb_build_object('ok', false, 'error', 'server_error');
end;
$$;

grant execute on function public.get_tv_ads(text) to anon, authenticated;

-- ---------------------------------------------------------------------
-- 3) مخزن الصور: bucket عام القراءة (لتعمل الشاشة بلا روابط موقّتة
--    تنتهي صلاحيتها)، والكتابة للمالك فقط داخل مجلد متجره.
--    المسار المطلوب: {store_id}/{ad_id}/image.webp
-- ---------------------------------------------------------------------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('restaurant-tv-ads', 'restaurant-tv-ads', true, 10485760,  -- 10MB حد أقصى
        array['image/jpeg','image/png','image/webp'])
on conflict (id) do nothing;

-- قراءة عامة (التلفزيون/الزوار) — قراءة فقط
drop policy if exists "tv_ads_public_read" on storage.objects;
create policy "tv_ads_public_read"
  on storage.objects for select
  using (bucket_id = 'restaurant-tv-ads');

-- رفع: مستخدم موثَّق، داخل مجلد باسم معرّفه فقط (store_id = auth.uid())
drop policy if exists "tv_ads_owner_insert" on storage.objects;
create policy "tv_ads_owner_insert"
  on storage.objects for insert to authenticated
  with check (bucket_id = 'restaurant-tv-ads'
              and (storage.foldername(name))[1] = auth.uid()::text);

drop policy if exists "tv_ads_owner_update" on storage.objects;
create policy "tv_ads_owner_update"
  on storage.objects for update to authenticated
  using (bucket_id = 'restaurant-tv-ads'
         and (storage.foldername(name))[1] = auth.uid()::text)
  with check (bucket_id = 'restaurant-tv-ads'
              and (storage.foldername(name))[1] = auth.uid()::text);

drop policy if exists "tv_ads_owner_delete" on storage.objects;
create policy "tv_ads_owner_delete"
  on storage.objects for delete to authenticated
  using (bucket_id = 'restaurant-tv-ads'
         and (storage.foldername(name))[1] = auth.uid()::text);

commit;

-- ✅ انتهى. تحقق سريع:
--   select public.get_tv_ads('TV_TOKEN_حقيقي');  -- {ok:true, ads:[...]}
--   select public.get_tv_ads('wrong');           -- {ok:false, error:"invalid_token"}
