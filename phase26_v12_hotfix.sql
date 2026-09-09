-- PHASE 26 — V12 HOTFIX
-- Fixes the Phase25 audit trigger to the real legacy audit_logs schema
-- (actor_id / old_value / new_value), and adds school logo upload storage.

create or replace function fn_audit_row() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  v_row jsonb; v_old jsonb; v_new jsonb; v_school uuid;
begin
  v_row := case when tg_op = 'DELETE' then to_jsonb(old) else to_jsonb(new) end;
  v_old := case when tg_op in ('UPDATE','DELETE') then to_jsonb(old) else null end;
  v_new := case when tg_op in ('INSERT','UPDATE') then to_jsonb(new) else null end;
  if tg_table_name = 'student_badges' then
    v_old := case when v_old is null then null else v_old - 'secure_token' end;
    v_new := case when v_new is null then null else v_new - 'secure_token' end;
  end if;
  v_school := nullif(v_row ->> 'school_id', '')::uuid;
  if v_school is null and v_row ? 'student_id' then
    select school_id into v_school from students where id = (v_row ->> 'student_id')::uuid;
  end if;
  if v_school is null and v_row ? 'class_id' then
    select school_id into v_school from classes where id = (v_row ->> 'class_id')::uuid;
  end if;
  insert into audit_logs (school_id, actor_id, action, entity, entity_id, old_value, new_value)
  values (v_school, auth.uid(), tg_op, tg_table_name,
          nullif(v_row ->> 'id', '')::uuid, v_old, v_new);
  return coalesce(new, old);
end; $$;

-- School logos: public read is intentional because badge cards need the logo
-- in <img>; uploads/updates remain limited to authorized school staff.
insert into storage.buckets (id, name, public)
values ('school-logos', 'school-logos', true)
on conflict (id) do nothing;

do $$ begin
  if not exists (select 1 from pg_policies where schemaname='storage' and tablename='objects' and policyname='p_school_logos_public_read') then
    create policy p_school_logos_public_read on storage.objects
      for select using (bucket_id = 'school-logos');
  end if;
  if not exists (select 1 from pg_policies where schemaname='storage' and tablename='objects' and policyname='p_school_logos_staff_insert') then
    create policy p_school_logos_staff_insert on storage.objects
      for insert to authenticated
      with check (bucket_id='school-logos' and fn_is_school_staff((storage.foldername(name))[1]::uuid));
  end if;
  if not exists (select 1 from pg_policies where schemaname='storage' and tablename='objects' and policyname='p_school_logos_staff_update') then
    create policy p_school_logos_staff_update on storage.objects
      for update to authenticated
      using (bucket_id='school-logos' and fn_is_school_staff((storage.foldername(name))[1]::uuid))
      with check (bucket_id='school-logos' and fn_is_school_staff((storage.foldername(name))[1]::uuid));
  end if;
end $$;
