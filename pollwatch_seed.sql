-- ============================================================================
-- بيانات اختبارية للتطوير (تشغيل: supabase db reset ثم هذا الملف)
-- ============================================================================

-- الأدوار
insert into public.roles (key, label_ar, label_fr, is_system) values
  ('superadmin',  'المدير المركزي',        'Superadmin',        true),
  ('party_admin', 'رئيس الحزب',            'Chef de parti',     false),
  ('observer',    'المراقب',               'Observateur',       false),
  ('assistant',   'المساعد',               'Assistant',         false);

-- الصلاحيات الدقيقة
insert into public.permissions (key, label_ar, label_fr) values
  ('assistants.read',   'قراءة المساعدين',        'Lecture assistants'),
  ('assistants.manage', 'إدارة المساعدين',        'Gestion assistants'),
  ('reports.create',    'إنشاء تقارير',           'Créer rapports'),
  ('reports.review',    'مراجعة التقارير',        'Réviser rapports'),
  ('stations.read',     'قراءة مكاتب الاقتراع',   'Lire bureaux');

-- أنواع الانتخابات
insert into public.election_types (code, label_ar, label_fr) values
  ('legislative', 'تشريعية', 'Législatives'),
  ('regional',    'جهوية',   'Régionales'),
  ('communal',    'جماعية',  'Communales');

-- سنتان انتخابيتان
insert into public.election_years (year, label_ar, label_fr, is_active) values
  (2021, 'انتخابات 2021', 'Élections 2021', false),
  (2026, 'انتخابات 2026', 'Élections 2026', true);

-- حزب تجريبي + دومين
insert into public.parties (name_ar, name_fr, slug, status, colors) values
  ('حزب النموذج', 'Parti Exemple', 'parti-exemple', 'active',
   '{"primary":"#0f766e","secondary":"#f59e0b"}'::jsonb);

insert into public.party_domains (party_id, domain, is_primary, verification_token, verified_at, ssl_status)
select id, 'www.parti-exemple.ma', true, 'pw-verify-9f2c1e7a', now(), 'issued'
from public.parties where slug = 'parti-exemple';

-- مكاتب اقتراع تجريبية (الدار البيضاء/الرباط)
insert into public.polling_stations (party_id, station_number, name_ar, city, region, location, status)
select p.id, 'CASA-001', 'مكتب الحي المعاريف', 'الدار البيضاء', 'الدار البيضاء-سطات',
       st_geogfromtext('POINT(-7.6320 33.5892)'), 'open'
from public.parties p where p.slug = 'parti-exemple';

insert into public.polling_stations (party_id, station_number, name_ar, city, region, location, status)
select p.id, 'CASA-002', 'مكتب أنفا', 'الدار البيضاء', 'الدار البيضاء-سطات',
       st_geogfromtext('POINT(-7.6110 33.6150)'), 'planned'
from public.parties p where p.slug = 'parti-exemple';

insert into public.polling_stations (party_id, station_number, name_ar, city, region, location, status)
select p.id, 'RBT-001', 'مكتب أكدال', 'الرباط', 'الرباط-سلا-القنيطرة',
       st_geogfromtext('POINT(-6.8430 34.0080)'), 'counting'
from public.parties p where p.slug = 'parti-exemple';

-- ملاحظة: party_members والمراقبون يُنشأون عبر Edge Functions لأنها مرتبطة بـ auth.users.
-- للتطوير المحلي أنشئ المستخدمين عبر supabase auth admin ثم:
--   insert into public.party_members (party_id, user_id, role_id, full_name) ...
