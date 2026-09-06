-- ============================================================================
-- PHASE 15 — FINAL HARDENING: ADMIN = DIRECTOR (role merge)
-- Runs AFTER phase14_teacher_assignments.sql.
-- ADDITIVE + SAFE: no DROP TABLE, no TRUNCATE, no bulk DELETE, no RLS
-- disabling, no data loss. Idempotent (re-runnable).
--
-- DECISION: the standalone 'director' role is merged INTO 'admin'.
-- Final roles: superadmin, admin, guard, teacher, driver, parent.
-- admin = full administrative authority inside one school.
--
-- What this migration does:
--   1. DATA CONVERSION: every user_roles row with role 'director' becomes
--      'admin'. No school, user, or relation is deleted. (The unique key
--      (profile_id, school_id, role) is respected: rows that would collide
--      with an existing 'admin' row for the SAME person+school are exact
--      duplicates of authority and are removed by a narrowly-scoped,
--      documented DELETE that touches ONLY those duplicate 'director' rows
--      — nothing else.)
--   2. HELPER CLEANUP: fn_resolve_my_role, fn_has_permission,
--      fn_is_admin_or_guard, fn_is_school_staff are re-created WITHOUT the
--      director role (same hardened logic otherwise). All RLS policies and
--      RPCs using them pick up the change automatically.
--
-- NOTE: the app_role enum VALUE 'director' remains in the type (removing an
-- enum value would require recreating the type and rewriting dependent
-- columns — intentionally NOT done for safety). It is simply unused after
-- this migration: no function grants it any authority.
-- ============================================================================

-- ============================================================================
-- SECTION 1 — DATA CONVERSION: director -> admin (no data loss)
-- ============================================================================

-- 1.a Convert every director row whose owner has NO admin row in the same
-- school (the common case — zero collisions).
update user_roles ur
set role = 'admin'::app_role
where ur.role = 'director'::app_role
  and not exists (
    select 1 from user_roles ur2
    where ur2.profile_id = ur.profile_id
      and ur2.school_id = ur.school_id
      and ur2.role = 'admin'::app_role
  );

-- 1.b Collision cleanup: a director row whose owner ALREADY holds admin in
-- the SAME school is an exact duplicate of authority (the person keeps full
-- admin rights via the existing row). Scoped strictly to those rows.
delete from user_roles ur
where ur.role = 'director'::app_role
  and exists (
    select 1 from user_roles ur2
    where ur2.profile_id = ur.profile_id
      and ur2.school_id = ur.school_id
      and ur2.role = 'admin'::app_role
  );

-- ============================================================================
-- SECTION 2 — ROLE RESOLUTION WITHOUT 'director'
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
    when 'guard'      then 2
    when 'teacher'    then 3
    when 'driver'     then 4
    when 'parent'     then 5
    else 6
  end
  limit 1;
$$;

revoke all on function fn_resolve_my_role(uuid) from public;
grant execute on function fn_resolve_my_role(uuid) to authenticated;

-- ============================================================================
-- SECTION 3 — PERMISSION CORE WITHOUT 'director'
-- admin passes by role; every other role needs an explicit grant.
-- ============================================================================

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
  if v_role = 'admin' then
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
-- SECTION 4 — LEGACY HELPERS WITHOUT 'director'
-- fn_is_admin_or_guard: back to (admin, guard) — all dependent policies were
-- guard-inclusive by design, so nothing changes for Guard; Admin keeps full
-- write scope. fn_is_school_staff: superadmin or school admin.
-- ============================================================================

create or replace function fn_is_admin_or_guard(p_school_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select fn_has_role(p_school_id, array['admin','guard']::app_role[]);
$$;

create or replace function fn_is_school_staff(p_school_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select
    exists (select 1 from user_roles
            where profile_id = auth.uid() and role::text = 'superadmin')
    or exists (select 1 from user_roles
               where profile_id = auth.uid()
                 and school_id = p_school_id
                 and role::text = 'admin');
$$;

revoke all on function fn_is_school_staff(uuid) from public;
grant execute on function fn_is_school_staff(uuid) to authenticated;

-- ============================================================================
-- END OF PHASE 15
-- ============================================================================
