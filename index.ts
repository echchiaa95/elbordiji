// ============================================================================
// supabase/functions/create-staff-account/index.ts
// Creates a teacher, driver, parent, or guard account — Email + Password.
//
// This is the ONLY place that touches SUPABASE_SERVICE_ROLE_KEY, and only
// server-side (Deno.env), never in any frontend file. verify_jwt stays at
// its DEFAULT (true) for this function — a caller must already be
// authenticated to use it.
//
// SECURITY MODEL (two separate clients, deliberately):
//   1. `callerClient` — anon key + the caller's own forwarded JWT. Used
//      ONLY to discover who is calling and to run fn_has_permission()
//      through PostgREST exactly as the caller would (so auth.uid() inside
//      that RPC resolves correctly) — never used for the actual writes.
//   2. `adminClient` — service role. Used ONLY after permission is
//      confirmed, for: creating the auth.users row (Email + Password via
//      auth.admin.createUser), and inserting into profiles / user_roles /
//      teachers|drivers|guards|parents / parent_students.
//
// AUTHENTICATION MODEL: Email + Password ONLY. No PIN, no user-number
// login, no staff_pins, no fn_set_user_pin — nothing of the legacy PIN
// system is requested, created, or called anywhere in this function.
//
// fn_has_permission / fn_resolve_my_role (Phase 4.2 / 4.2.1) are reused
// exactly as they are — no permission logic is duplicated here.
//
// ALLOWED account types: teacher, driver, parent, guard — ONLY. admin and
// superadmin are rejected unconditionally, regardless of the caller's role
// or permissions.
// ============================================================================

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!;
const ANON_KEY = Deno.env.get('SUPABASE_ANON_KEY')!;
const SERVICE_ROLE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
// Production origin is the safe default; deploys can widen/override the
// list via the ALLOWED_ORIGINS env var (comma-separated). Never '*'.
const ALLOWED_ORIGINS = (Deno.env.get('ALLOWED_ORIGINS') || 'https://school.elbordiji.com')
  .split(',').map((o) => o.trim()).filter(Boolean);

// Guard creation is admin-ONLY (checked by role in user_roles
// below, never by a client-supplied value) — there is intentionally no
// "guards.create" permission key, so a guard can never be granted the
// ability to create another guard.
const ALLOWED_ACCOUNT_TYPES = ['teacher', 'driver', 'parent', 'guard'] as const;
type AccountType = typeof ALLOWED_ACCOUNT_TYPES[number];

const PERMISSION_BY_TYPE: Partial<Record<AccountType, string>> = {
  teacher: 'teachers.create',
  driver: 'drivers.create',
  parent: 'parents.create',
  // guard: intentionally absent
};

// Same deterministic priority as fn_resolve_my_role — kept in sync
// intentionally; if a caller holds multiple roles, resolve the SAME one the
// database functions would, so the permission check target matches.
const ROLE_PRIORITY = ['superadmin', 'admin', 'guard', 'teacher', 'driver', 'parent'];

const adminClient = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, {
  auth: { autoRefreshToken: false, persistSession: false },
});

function corsHeaders(origin: string | null) {
  const headers: Record<string, string> = {
    'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
    'Access-Control-Allow-Methods': 'POST, OPTIONS',
    Vary: 'Origin',
  };
  if (origin && ALLOWED_ORIGINS.includes(origin)) headers['Access-Control-Allow-Origin'] = origin;
  return headers;
}
function json(body: unknown, status: number, origin: string | null) {
  return new Response(JSON.stringify(body), {
    status, headers: { 'Content-Type': 'application/json', ...corsHeaders(origin) },
  });
}
// Arabic, user-safe error messages — never a raw SQL/Postgres error. Every
// failure also carries a machine-readable `code` so the frontend can map it
// deterministically (EMAIL_EXISTS, SCHOOL_ACCESS_DENIED, ...).
function fail(messageAr: string, status: number, origin: string | null, code?: string) {
  return json({ error: messageAr, code: code || null }, status, origin);
}

Deno.serve(async (req: Request) => {
  const origin = req.headers.get('origin');
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders(origin) });
  if (req.method !== 'POST') return fail('طريقة غير مسموحة', 405, origin);

  const authHeader = req.headers.get('Authorization');
  if (!authHeader) return fail('يجب تسجيل الدخول', 401, origin);

  let body: Record<string, unknown>;
  try {
    body = await req.json();
  } catch {
    return fail('طلب غير صالح', 400, origin);
  }

  const accountType = String(body.accountType || '');
  if (!ALLOWED_ACCOUNT_TYPES.includes(accountType as AccountType)) {
    // Explicitly and unconditionally rejects 'admin', 'superadmin', or
    // anything else — no code path below can ever create those.
    return fail('نوع الحساب غير مسموح به', 400, origin);
  }
  const type = accountType as AccountType;

  const fullName = typeof body.fullName === 'string' ? body.fullName.trim() : '';
  const email = typeof body.email === 'string' ? body.email.trim().toLowerCase() : '';
  const password = typeof body.password === 'string' ? body.password : '';
  const phone = typeof body.phone === 'string' ? body.phone.trim() : null;
  const employeeNumber = typeof body.employeeNumber === 'string' ? body.employeeNumber.trim() : null;
  const licenseNumber = typeof body.licenseNumber === 'string' ? body.licenseNumber.trim() : null;
  const parentStudentLinks: Array<{ studentId: string; relationship?: string }> =
    Array.isArray(body.parentStudentLinks) ? body.parentStudentLinks : [];

  if (!fullName || fullName.length > 200) return fail('الاسم الكامل مطلوب', 400, origin);
  if (!email || !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) {
    return fail('البريد الإلكتروني غير صالح', 400, origin);
  }
  if (password.length < 8) {
    return fail('كلمة المرور يجب أن تكون 8 أحرف على الأقل', 400, origin);
  }

  // ---- 1. Identify the caller (via THEIR OWN JWT, not service role) -------
  const callerClient = createClient(SUPABASE_URL, ANON_KEY, {
    global: { headers: { Authorization: authHeader } },
    auth: { autoRefreshToken: false, persistSession: false },
  });

  const { data: userData, error: userErr } = await callerClient.auth.getUser();
  if (userErr || !userData?.user) return fail('جلسة غير صالحة', 401, origin);
  const callerId = userData.user.id;

  // ---- 2. Resolve which school this action targets, deterministically ----
  // (same priority order as fn_resolve_my_role — never an arbitrary pick).
  const { data: roleRows, error: roleErr } = await callerClient
    .from('user_roles')
    .select('school_id, role')
    .eq('profile_id', callerId);
  if (roleErr || !roleRows || roleRows.length === 0) {
    return fail('لا يوجد سياق مؤسسة لهذا المستخدم', 403, origin);
  }
  roleRows.sort((a, b) => ROLE_PRIORITY.indexOf(a.role) - ROLE_PRIORITY.indexOf(b.role));
  const schoolId = roleRows[0].school_id as string;
  const callerRole = roleRows[0].role as string;

  // ---- 3. Authorization ----------------------------------------------------
  if (type === 'guard') {
    // Role-only gate, deliberately NOT permission-based — a Guard can never
    // be granted "create another guard" because no such permission key
    // exists in the catalog. Admin only.
    if (callerRole !== 'admin') {
      return fail('ليس لديك صلاحية لهذه العملية', 403, origin, 'SCHOOL_ACCESS_DENIED');
    }
  } else {
    // Real, server-verified permission check via the existing
    // fn_has_permission RPC (admin always passes inside that
    // function too; a guard needs the specific granted key).
    const { data: allowed, error: permErr } = await callerClient.rpc('fn_has_permission', {
      p_permission_key: PERMISSION_BY_TYPE[type],
      p_school_id: schoolId,
    });
    if (permErr) {
      // Machine-readable code so the frontend can distinguish a permission
      // CHECK failure (RPC/schema problem — retryable, see phase14 defensive
      // re-creation of fn_has_permission) from a real PERMISSION_DENIED.
      console.error('fn_has_permission error:', permErr);
      return fail('تعذر التحقق من الصلاحية', 500, origin, 'PERMISSION_CHECK_FAILED');
    }
    if (!allowed) {
      return fail('ليس لديك صلاحية لهذه العملية', 403, origin);
    }
  }

  // ---- 4. Business validation: parent-student links must be in-school ----
  // (queried through callerClient, so RLS itself already scopes results to
  // students the caller can see — never trusting a client-asserted school).
  let validatedLinks: Array<{ studentId: string; relationship: string | null }> = [];
  if (type === 'parent' && parentStudentLinks.length > 0) {
    const studentIds = parentStudentLinks.map((l) => l.studentId);
    const { data: validStudents } = await callerClient
      .from('students').select('id').in('id', studentIds);
    const validIds = new Set((validStudents || []).map((s) => s.id));
    validatedLinks = parentStudentLinks
      .filter((l) => validIds.has(l.studentId))
      .map((l) => ({ studentId: l.studentId, relationship: l.relationship || null }));
    if (validatedLinks.length !== parentStudentLinks.length) {
      return fail('لا يمكن ربط ولي الأمر بتلميذ من مؤسسة أخرى', 400, origin);
    }
  }

  // ---- 5. Privileged creation, with compensating rollback on failure ------
  let newUserId: string | null = null;

  try {
    const { data: authUser, error: authErr } = await adminClient.auth.admin.createUser({
      email,
      password,
      email_confirm: true,
      user_metadata: { full_name: fullName, account_type: type },
    });
    if (authErr || !authUser?.user) {
      const msg = (authErr?.message || '').toLowerCase();
      if (msg.includes('already') || msg.includes('duplicate') || msg.includes('registered')) {
        return fail('البريد الإلكتروني مستخدم بالفعل', 409, origin, 'EMAIL_EXISTS');
      }
      if (msg.includes('password')) {
        return fail('كلمة المرور ضعيفة جدًا', 400, origin, 'WEAK_PASSWORD');
      }
      console.error('auth.admin.createUser failed:', authErr);
      return fail('تعذر إنشاء حساب الدخول، حاول مرة أخرى', 500, origin, 'AUTH_CREATE_FAILED');
    }
    newUserId = authUser.user.id;

    // UPSERT for the same reason as create-platform-user: a possible
    // auto-profile trigger on auth.users would make a plain insert fail
    // with a duplicate key right after createUser succeeds.
    const { error: profileErr } = await adminClient.from('profiles').upsert({
      id: newUserId, full_name: fullName, phone, user_number: email,
    }, { onConflict: 'id' });
    if (profileErr) {
      console.error('profile upsert failed:', profileErr);
      throw new Error('PROFILE_CREATE_FAILED');
    }

    const { error: roleInsertErr } = await adminClient.from('user_roles').insert({
      profile_id: newUserId, school_id: schoolId, role: type,
    });
    if (roleInsertErr) {
      console.error('role insert failed:', roleInsertErr);
      throw new Error('ROLE_CREATE_FAILED');
    }

    if (type === 'teacher') {
      const { error: e } = await adminClient.from('teachers').upsert({
        profile_id: newUserId, school_id: schoolId, employee_number: employeeNumber,
      }, { onConflict: 'profile_id,school_id', ignoreDuplicates: true });
      if (e) { console.error('teacher insert failed:', e); throw new Error('STAFF_CREATE_FAILED'); }
    } else if (type === 'driver') {
      const { error: e } = await adminClient.from('drivers').upsert({
        profile_id: newUserId, school_id: schoolId, license_number: licenseNumber,
      }, { onConflict: 'profile_id,school_id', ignoreDuplicates: true });
      if (e) { console.error('driver insert failed:', e); throw new Error('STAFF_CREATE_FAILED'); }
    } else if (type === 'guard') {
      // Reuses the existing `guards` table, same shape as teachers/drivers
      // — no new table. Idempotent via unique(profile_id, school_id).
      const { error: e } = await adminClient.from('guards').upsert({
        profile_id: newUserId, school_id: schoolId,
      }, { onConflict: 'profile_id,school_id', ignoreDuplicates: true });
      if (e) { console.error('guard insert failed:', e); throw new Error('STAFF_CREATE_FAILED'); }
    } else {
      const { data: parentRow, error: e } = await adminClient.from('parents').upsert({
        profile_id: newUserId, school_id: schoolId,
      }, { onConflict: 'profile_id,school_id' }).select('id').single();
      if (e || !parentRow) {
        console.error('parent insert failed:', e);
        throw new Error('STAFF_CREATE_FAILED');
      }

      for (const link of validatedLinks) {
        const { error: linkErr } = await adminClient.from('parent_students').insert({
          parent_id: parentRow.id, student_id: link.studentId, relationship: link.relationship,
        });
        if (linkErr) throw new Error('parent_students insert failed: ' + linkErr.message);
      }
    }

    // Audit trail — reuses the existing fn_write_audit; never logs the
    // password.
    await adminClient.rpc('fn_write_audit', {
      p_school_id: schoolId,
      p_action: 'CREATE_' + type.toUpperCase() + '_ACCOUNT',
      p_entity: type + 's',
      p_entity_id: newUserId,
      p_old: null,
      p_new: { full_name: fullName, email },
    });

    return json({ ok: true, profileId: newUserId, email }, 200, origin);
  } catch (err) {
    console.error('create-staff-account failed, rolling back:', err);
    // Compensating rollback: an orphaned auth.users row with no profile is
    // exactly the failure mode to avoid — clean it up so a retry with the
    // same email doesn't collide with a half-created account.
    if (newUserId) {
      await adminClient.auth.admin.deleteUser(newUserId).catch((e) =>
        console.error('rollback deleteUser also failed:', e));
    }
    const detail = err instanceof Error ? err.message : String(err);
    const CODE_MESSAGES: Record<string, string> = {
      PROFILE_CREATE_FAILED: 'تعذر إنشاء الملف الشخصي',
      ROLE_CREATE_FAILED: 'تعذر ربط الدور بالمؤسسة',
      STAFF_CREATE_FAILED: 'تعذر إنشاء السجل الوظيفي',
    };
    return fail(CODE_MESSAGES[detail] || 'تعذر إنشاء الحساب، حاول مرة أخرى', 500, origin,
                CODE_MESSAGES[detail] ? detail : 'CREATE_FAILED');
  }
});
