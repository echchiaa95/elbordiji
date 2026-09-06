-- ============================================================================
-- PHASE 16 — AUTOMATIC STUDENT NUMBER
-- Final fix for student registration.
--
-- Student number is generated server-side, sequentially per school.
-- Existing student numbers are preserved. The first generated number is
-- max(existing numeric student_number) + 1 for that school; subsequent
-- registrations use a locked counter, preventing duplicates under normal
-- concurrent registration.
--
-- No existing data is deleted. The legacy fn_register_student signature is
-- preserved; this RPC generates the number and delegates to it.
-- ============================================================================

create table if not exists school_student_number_counters (
  school_id uuid primary key references schools(id) on delete cascade,
  next_number bigint not null default 0,
  updated_at timestamptz not null default now()
);

revoke all on table school_student_number_counters from public;

create or replace function fn_register_student_auto_number(
  p_full_name text,
  p_class_id uuid,
  p_academic_year_id uuid,
  p_birth_date date default null,
  p_gender text default null
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_school_id uuid;
  v_role text;
  v_max_number bigint := 0;
  v_student_number text;
  v_student_id uuid;
begin
  if auth.uid() is null then
    raise exception 'NOT_AUTHENTICATED';
  end if;

  if p_full_name is null or btrim(p_full_name) = '' then
    raise exception 'STUDENT_NAME_REQUIRED';
  end if;

  select c.school_id into v_school_id
  from classes c
  where c.id = p_class_id;

  if v_school_id is null then
    raise exception 'INVALID_CLASS';
  end if;

  if not exists (
    select 1 from academic_years ay
    where ay.id = p_academic_year_id
      and ay.school_id = v_school_id
  ) then
    raise exception 'ACADEMIC_YEAR_SCHOOL_MISMATCH';
  end if;

  v_role := fn_resolve_my_role(v_school_id);
  if v_role is null then
    raise exception 'PERMISSION_DENIED: no role in this school';
  end if;

  if v_role <> 'admin' and not fn_has_permission('students.create', v_school_id) then
    raise exception 'PERMISSION_DENIED: missing students.create';
  end if;

  -- Serialize number allocation for this school.
  perform pg_advisory_xact_lock(hashtextextended(v_school_id::text, 0));

  -- Synchronize the counter with all existing numeric student numbers.
  select coalesce(max(student_number::bigint), 0)
    into v_max_number
  from students
  where school_id = v_school_id
    and student_number ~ '^[0-9]+$';

  insert into school_student_number_counters (school_id, next_number)
  values (v_school_id, v_max_number)
  on conflict (school_id) do nothing;

  update school_student_number_counters c
     set next_number = greatest(c.next_number, v_max_number) + 1,
         updated_at = now()
   where c.school_id = v_school_id
  returning c.next_number into v_max_number;

  v_student_number := v_max_number::text;

  -- Delegate the actual registration to the existing, tested RPC.
  v_student_id := fn_register_student(
    v_school_id,
    p_full_name,
    v_student_number,
    p_class_id,
    p_academic_year_id,
    p_birth_date,
    p_gender
  );

  return v_student_id;
end;
$$;

revoke all on function fn_register_student_auto_number(text, uuid, uuid, date, text) from public;
grant execute on function fn_register_student_auto_number(text, uuid, uuid, date, text) to authenticated;

insert into school_student_number_counters (school_id, next_number)
select s.id,
       coalesce((
         select max(st.student_number::bigint)
         from students st
         where st.school_id = s.id
           and st.student_number ~ '^[0-9]+$'
       ), 0)
from schools s
on conflict (school_id) do update
set next_number = greatest(
  school_student_number_counters.next_number,
  excluded.next_number
),
updated_at = now();

-- Error text used by the new RPC.
