-- ============================================================================
-- PHASE 14 — TEACHER ACADEMIC ASSIGNMENTS + AUTHORIZATION HARDENING
-- Runs AFTER phase12_complete_platform_v5.sql, phase12_1_hardening.sql and
-- phase13_fixes.sql. ADDITIVE ONLY: no DROP, no TRUNCATE, no DELETE, no
-- RLS disabling, no policy removal.
--
-- What this migration does:
--
--   0. Defensive re-creation of fn_resolve_my_role / fn_has_permission
--      (identical logic to phase4_2 + phase12 v5). Guarantees the dependency
--      chain used by the create-staff-account Edge Function exists and is
--      the hardened variant, regardless of which older migrations ran.
--      Root-cause fix for "تعذر التحقق من الصلاحية".
--
--   1. Teacher ↔ Subject / Teacher ↔ Class assignment RPCs.
--      AUDIT RESULT: the tables teacher_subjects(teacher_id, subject_id) and
--      teacher_classes(teacher_id, class_id) ALREADY EXIST since
--      phase2_schema (PKs prevent duplicates; FKs cascade with the teacher).
--      They are REUSED as-is — no duplicate structure is created.
--      All write RPCs verify: auth.uid(), caller is admin/director of the
--      TEACHER's school (or superadmin), and that teacher + subject/class
--      all belong to the SAME school (cross-school impossible).
--
--   2. fn_teacher_classes is REPLACED so a teacher sees BOTH their homeroom
--      classes (legacy classes.teacher_id) AND explicitly assigned classes
--      (teacher_classes). Same signature and return shape.
--
--   3. fn_add_grade / fn_save_attendance are REPLACED (same signatures,
--      same bodies) with one added rule: when the caller is a TEACHER (not
--      admin/director/superadmin), the operation additionally requires
--        permission (grades.manage / attendance.manage)
--        AND subject assignment (teacher_subjects)        [grades]
--        AND class assignment   (teacher_classes or homeroom)
--      otherwise: TEACHER_ASSIGNMENT_REQUIRED / PERMISSION_DENIED.
--      Admin/director/superadmin paths are unchanged.
-- ============================================================================

-- ============================================================================
-- SECTION 0 — DEFENSIVE PERMISSION CORE (idempotent, same logic as deployed)
-- ============================================================================

create or replace function fn_resolve_my_role(p_school_id uuid)
returns text
language sql
stable
security definer
set search_path = public
as $$
  select role::text
  from user_roles
  where profile_id = auth.uid()
    and school_id = p_school_id
  order by case role::text
    when 'superadmin' then 0
    when 'admin'      then 1
    when 'director'   then 2
    when 'guard'      then 3
    when 'teacher'    then 4
    when 'driver'     then 5
    when 'parent'     then 6
    else 7
  end
  limit 1;
$$;

revoke all on function fn_resolve_my_role(uuid) from public;
grant execute on function fn_resolve_my_role(uuid) to authenticated;

-- Hardened variant (phase12 v5): admin/director pass by role; every other
-- role needs an explicit user_permissions grant. Never "always true".
create or replace function fn_has_permission(p_permission_key text, p_school_id uuid)
returns boolean
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_role text;
begin
  if auth.uid() is null then
    return false;
  end if;

  if exists (select 1 from user_roles
             where profile_id = auth.uid() and role::text = 'superadmin') then
    return true;
  end if;

  v_role := fn_resolve_my_role(p_school_id);
  if v_role in ('admin', 'director') then
    return true;
  end if;

  return exists (
    select 1 from user_permissions
    where profile_id = auth.uid()
      and school_id = p_school_id
      and permission_key = p_permission_key
  );
end;
$$;

revoke all on function fn_has_permission(text, uuid) from public;
grant execute on function fn_has_permission(text, uuid) to authenticated;

-- ============================================================================
-- SECTION 1 — TEACHER ↔ SUBJECT ASSIGNMENT RPCs
-- Table reused: teacher_subjects(teacher_id, subject_id) — PK prevents
-- duplicate assignments; FK cascade removes assignments with the teacher.
-- ============================================================================

-- 1.1 assign — admin/director of the teacher's school (or superadmin) only.
create or replace function fn_assign_teacher_subject(p_teacher_id uuid, p_subject_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_school_id uuid;
begin
  if auth.uid() is null then
    raise exception 'NOT_AUTHENTICATED';
  end if;

  select t.school_id into v_school_id
  from teachers t
  where t.id = p_teacher_id and t.deleted_at is null;
  if v_school_id is null then
    raise exception 'INVALID_TEACHER';
  end if;

  -- Caller authority: admin/director of THIS school, or superadmin.
  if not fn_is_school_staff(v_school_id) then
    raise exception 'PERMISSION_DENIED';
  end if;

  -- Subject must belong to the SAME school — cross-school impossible.
  if not exists (select 1 from subjects s
                 where s.id = p_subject_id and s.school_id = v_school_id) then
    raise exception 'SUBJECT_SCHOOL_MISMATCH';
  end if;

  insert into teacher_subjects (teacher_id, subject_id)
  values (p_teacher_id, p_subject_id)
  on conflict (teacher_id, subject_id) do nothing;

  perform fn_safe_audit(v_school_id, 'ASSIGN_TEACHER_SUBJECT', 'teacher_subjects', p_teacher_id,
    null, jsonb_build_object('teacher_id', p_teacher_id, 'subject_id', p_subject_id));
end;
$$;

revoke all on function fn_assign_teacher_subject(uuid, uuid) from public;
grant execute on function fn_assign_teacher_subject(uuid, uuid) to authenticated;

-- 1.2 remove — same authority rules.
create or replace function fn_remove_teacher_subject(p_teacher_id uuid, p_subject_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_school_id uuid;
begin
  if auth.uid() is null then
    raise exception 'NOT_AUTHENTICATED';
  end if;

  select t.school_id into v_school_id from teachers t where t.id = p_teacher_id;
  if v_school_id is null then
    raise exception 'INVALID_TEACHER';
  end if;

  if not fn_is_school_staff(v_school_id) then
    raise exception 'PERMISSION_DENIED';
  end if;

  delete from teacher_subjects
  where teacher_id = p_teacher_id and subject_id = p_subject_id;

  perform fn_safe_audit(v_school_id, 'REMOVE_TEACHER_SUBJECT', 'teacher_subjects', p_teacher_id,
    jsonb_build_object('teacher_id', p_teacher_id, 'subject_id', p_subject_id), null);
end;
$$;

revoke all on function fn_remove_teacher_subject(uuid, uuid) from public;
grant execute on function fn_remove_teacher_subject(uuid, uuid) to authenticated;

-- 1.3 list — staff of the school, or the teacher reading their OWN record.
create or replace function fn_list_teacher_subjects(p_teacher_id uuid)
returns table(subject_id uuid, subject_name text)
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_school_id uuid;
begin
  if auth.uid() is null then
    raise exception 'NOT_AUTHENTICATED';
  end if;

  select t.school_id into v_school_id from teachers t where t.id = p_teacher_id;
  if v_school_id is null then
    raise exception 'INVALID_TEACHER';
  end if;

  if not (fn_is_school_member(v_school_id)
          or exists (select 1 from teachers t
                     where t.id = p_teacher_id and t.profile_id = auth.uid())) then
    raise exception 'PERMISSION_DENIED';
  end if;

  return query
  select s.id, s.name
  from teacher_subjects ts
  join subjects s on s.id = ts.subject_id
  where ts.teacher_id = p_teacher_id
  order by s.name;
end;
$$;

revoke all on function fn_list_teacher_subjects(uuid) from public;
grant execute on function fn_list_teacher_subjects(uuid) to authenticated;

-- ============================================================================
-- SECTION 2 — TEACHER ↔ CLASS ASSIGNMENT RPCs
-- Table reused: teacher_classes(teacher_id, class_id).
-- ============================================================================

create or replace function fn_assign_teacher_class(p_teacher_id uuid, p_class_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_school_id uuid;
begin
  if auth.uid() is null then
    raise exception 'NOT_AUTHENTICATED';
  end if;

  select t.school_id into v_school_id
  from teachers t
  where t.id = p_teacher_id and t.deleted_at is null;
  if v_school_id is null then
    raise exception 'INVALID_TEACHER';
  end if;

  if not fn_is_school_staff(v_school_id) then
    raise exception 'PERMISSION_DENIED';
  end if;

  -- Class must belong to the SAME school — cross-school impossible.
  if not exists (select 1 from classes c
                 where c.id = p_class_id and c.school_id = v_school_id) then
    raise exception 'CLASS_SCHOOL_MISMATCH';
  end if;

  insert into teacher_classes (teacher_id, class_id)
  values (p_teacher_id, p_class_id)
  on conflict (teacher_id, class_id) do nothing;

  perform fn_safe_audit(v_school_id, 'ASSIGN_TEACHER_CLASS', 'teacher_classes', p_teacher_id,
    null, jsonb_build_object('teacher_id', p_teacher_id, 'class_id', p_class_id));
end;
$$;

revoke all on function fn_assign_teacher_class(uuid, uuid) from public;
grant execute on function fn_assign_teacher_class(uuid, uuid) to authenticated;

create or replace function fn_remove_teacher_class(p_teacher_id uuid, p_class_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_school_id uuid;
begin
  if auth.uid() is null then
    raise exception 'NOT_AUTHENTICATED';
  end if;

  select t.school_id into v_school_id from teachers t where t.id = p_teacher_id;
  if v_school_id is null then
    raise exception 'INVALID_TEACHER';
  end if;

  if not fn_is_school_staff(v_school_id) then
    raise exception 'PERMISSION_DENIED';
  end if;

  delete from teacher_classes
  where teacher_id = p_teacher_id and class_id = p_class_id;

  perform fn_safe_audit(v_school_id, 'REMOVE_TEACHER_CLASS', 'teacher_classes', p_teacher_id,
    jsonb_build_object('teacher_id', p_teacher_id, 'class_id', p_class_id), null);
end;
$$;

revoke all on function fn_remove_teacher_class(uuid, uuid) from public;
grant execute on function fn_remove_teacher_class(uuid, uuid) to authenticated;

create or replace function fn_list_teacher_classes(p_teacher_id uuid)
returns table(class_id uuid, class_name text, level text, year_name text)
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_school_id uuid;
begin
  if auth.uid() is null then
    raise exception 'NOT_AUTHENTICATED';
  end if;

  select t.school_id into v_school_id from teachers t where t.id = p_teacher_id;
  if v_school_id is null then
    raise exception 'INVALID_TEACHER';
  end if;

  if not (fn_is_school_member(v_school_id)
          or exists (select 1 from teachers t
                     where t.id = p_teacher_id and t.profile_id = auth.uid())) then
    raise exception 'PERMISSION_DENIED';
  end if;

  return query
  select c.id, c.name, c.level, ay.label
  from teacher_classes tc
  join classes c on c.id = tc.class_id
  join academic_years ay on ay.id = c.academic_year_id
  where tc.teacher_id = p_teacher_id
  order by ay.is_current desc, c.name;
end;
$$;

revoke all on function fn_list_teacher_classes(uuid) from public;
grant execute on function fn_list_teacher_classes(uuid) to authenticated;

-- 2.4 fn_my_teacher_subjects — the caller's OWN assigned subjects
-- (used by the teacher console to limit the grade form to assigned subjects).
create or replace function fn_my_teacher_subjects()
returns table(subject_id uuid, subject_name text)
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_teacher_id uuid;
begin
  select t.id into v_teacher_id
  from teachers t
  where t.profile_id = auth.uid() and t.deleted_at is null
  limit 1;
  if v_teacher_id is null then
    return;
  end if;

  return query
  select s.id, s.name
  from teacher_subjects ts
  join subjects s on s.id = ts.subject_id
  where ts.teacher_id = v_teacher_id
  order by s.name;
end;
$$;

revoke all on function fn_my_teacher_subjects() from public;
grant execute on function fn_my_teacher_subjects() to authenticated;

-- ============================================================================
-- SECTION 3 — fn_teacher_classes: homeroom (legacy classes.teacher_id)
-- UNION explicit assignments (teacher_classes). Same signature/return shape.
-- ============================================================================
create or replace function fn_teacher_classes()
returns table(class_id uuid, class_name text, level text, year_name text, student_count bigint)
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_teacher_id uuid;
begin
  select t.id into v_teacher_id from teachers t
  where t.profile_id = auth.uid() and t.deleted_at is null
  limit 1;
  if v_teacher_id is null then
    return;
  end if;

  return query
  select c.id, c.name, c.level, ay.label,
         (select count(*) from student_enrollments se
          where se.class_id = c.id and se.status = 'ACTIVE')
  from classes c
  join academic_years ay on ay.id = c.academic_year_id
  where not c.is_disabled
    and (c.teacher_id = v_teacher_id
         or exists (select 1 from teacher_classes tc
                    where tc.class_id = c.id and tc.teacher_id = v_teacher_id))
  order by ay.is_current desc, c.name;
end;
$$;

revoke all on function fn_teacher_classes() from public;
grant execute on function fn_teacher_classes() to authenticated;

-- ============================================================================
-- SECTION 4 — ACADEMIC AUTHORIZATION ENFORCEMENT
-- Teacher = permission + assignment. Admin/director/superadmin unchanged.
-- ============================================================================

-- 4.1 fn_add_grade — teacher must hold grades.manage AND be assigned to
-- BOTH the subject (teacher_subjects) and the class (teacher_classes or
-- homeroom teacher). Everything else about the function is unchanged.
create or replace function fn_add_grade(
  p_student_id uuid,
  p_class_id uuid,
  p_subject_id uuid,
  p_period text,
  p_grade_type text,
  p_score numeric,
  p_max_score numeric default 20,
  p_note text default null
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_school_id uuid;
  v_id uuid;
  v_teacher_id uuid;
begin
  select school_id into v_school_id from students where id = p_student_id;
  if v_school_id is null then
    raise exception 'INVALID_STUDENT';
  end if;

  -- The caller's teachers row (teachers.id) — student_grades.teacher_id has a
  -- legacy FK to teachers(id), so auth.uid() is never stored directly.
  select t.id into v_teacher_id
  from teachers t
  where t.school_id = v_school_id and t.profile_id = auth.uid()
    and t.deleted_at is null
  limit 1;

  if not (fn_is_school_staff(v_school_id) or v_teacher_id is not null
          or fn_has_permission('grades.manage', v_school_id)) then
    raise exception 'PERMISSION_DENIED';
  end if;

  -- Legacy NOT NULL columns must never receive NULL:
  if p_subject_id is null then
    raise exception 'GRADE_SUBJECT_REQUIRED';
  end if;
  if not exists (select 1 from subjects s where s.id = p_subject_id and s.school_id = v_school_id) then
    raise exception 'INVALID_SUBJECT';
  end if;
  if p_score is null or p_score < 0 then
    raise exception 'INVALID_SCORE';
  end if;

  -- PHASE 14: a TEACHER caller (not admin/director/superadmin) needs
  -- permission + subject assignment + class assignment.
  if v_teacher_id is not null and not fn_is_school_staff(v_school_id) then
    if not fn_has_permission('grades.manage', v_school_id) then
      raise exception 'PERMISSION_DENIED';
    end if;
    if not exists (select 1 from teacher_subjects ts
                   where ts.teacher_id = v_teacher_id and ts.subject_id = p_subject_id) then
      raise exception 'TEACHER_ASSIGNMENT_REQUIRED';
    end if;
    if not (exists (select 1 from teacher_classes tc
                    where tc.teacher_id = v_teacher_id and tc.class_id = p_class_id)
            or exists (select 1 from classes c
                       where c.id = p_class_id and c.teacher_id = v_teacher_id)) then
      raise exception 'TEACHER_ASSIGNMENT_REQUIRED';
    end if;
  end if;

  insert into student_grades
    (school_id, student_id, class_id, subject_id, period, grade_type, score, max_score, note, grade_date, teacher_id)
  values (
    v_school_id, p_student_id, p_class_id, p_subject_id,
    nullif(trim(coalesce(p_period, '')), ''),
    coalesce(nullif(trim(coalesce(p_grade_type, '')), ''), 'تقويم'),
    p_score, coalesce(p_max_score, 20),
    nullif(trim(coalesce(p_note, '')), ''),
    current_date,           -- grade_date NOT NULL (legacy default kept explicit)
    v_teacher_id            -- teachers.id resolved from profile_id = auth.uid()
  )
  returning id into v_id;

  perform fn_safe_audit(v_school_id, 'ADD_GRADE', 'student_grades', v_id,
    null, jsonb_build_object('student_id', p_student_id, 'score', p_score));

  return v_id;
end;
$$;

revoke all on function fn_add_grade(uuid, uuid, uuid, text, text, numeric, numeric, text) from public;
grant execute on function fn_add_grade(uuid, uuid, uuid, text, text, numeric, numeric, text) to authenticated;

-- 4.2 fn_save_attendance — a TEACHER caller must hold attendance.manage AND
-- be assigned to the class (teacher_classes or homeroom). Same body
-- otherwise; admin/director/superadmin unchanged.
create or replace function fn_save_attendance(
  p_class_id uuid,
  p_date date,
  p_rows jsonb
)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_school_id uuid;
  v_row jsonb;
  v_count integer := 0;
  v_teacher_id uuid;
begin
  select school_id into v_school_id from classes where id = p_class_id;
  if v_school_id is null then
    raise exception 'INVALID_CLASS';
  end if;

  select t.id into v_teacher_id
  from teachers t
  where t.school_id = v_school_id
    and t.profile_id = auth.uid()
    and t.deleted_at is null
  limit 1;

  if not (fn_is_school_staff(v_school_id)
          or v_teacher_id is not null
          or fn_has_permission('attendance.manage', v_school_id)) then
    raise exception 'PERMISSION_DENIED';
  end if;

  -- PHASE 14: teacher caller needs permission + class assignment.
  if v_teacher_id is not null and not fn_is_school_staff(v_school_id) then
    if not fn_has_permission('attendance.manage', v_school_id) then
      raise exception 'PERMISSION_DENIED';
    end if;
    if not (exists (select 1 from teacher_classes tc
                    where tc.teacher_id = v_teacher_id and tc.class_id = p_class_id)
            or exists (select 1 from classes c
                       where c.id = p_class_id and c.teacher_id = v_teacher_id)) then
      raise exception 'TEACHER_ASSIGNMENT_REQUIRED';
    end if;
  end if;

  if p_rows is null or jsonb_typeof(p_rows) <> 'array' then
    raise exception 'INVALID_ROWS';
  end if;

  for v_row in select * from jsonb_array_elements(p_rows)
  loop
    -- The student must have an ACTIVE enrollment in THIS class (school
    -- isolation is enforced by following the class -> school chain).
    if not exists (
      select 1 from student_enrollments se
      where se.student_id = (v_row->>'student_id')::uuid
        and se.class_id = p_class_id
        and se.status = 'ACTIVE'
    ) then
      continue;
    end if;

    if coalesce(v_row->>'status', '') not in ('present', 'absent', 'late', 'excused') then
      continue;
    end if;

    insert into attendance_records
      (school_id, student_id, class_id, att_date, status, note, recorded_by)
    values (
      v_school_id,
      (v_row->>'student_id')::uuid,
      p_class_id,
      coalesce(p_date, current_date),
      v_row->>'status',
      nullif(trim(coalesce(v_row->>'note', '')), ''),
      auth.uid()
    )
    on conflict (student_id, class_id, att_date)
    do update set status = excluded.status,
                  note = excluded.note,
                  recorded_by = excluded.recorded_by,
                  updated_at = now();

    v_count := v_count + 1;
  end loop;

  perform fn_safe_audit(v_school_id, 'SAVE_ATTENDANCE', 'attendance_records', p_class_id,
    null, jsonb_build_object('date', coalesce(p_date, current_date), 'count', v_count));

  return v_count;
end;
$$;

revoke all on function fn_save_attendance(uuid, date, jsonb) from public;
grant execute on function fn_save_attendance(uuid, date, jsonb) to authenticated;

-- ============================================================================
-- END OF PHASE 14
-- ============================================================================
