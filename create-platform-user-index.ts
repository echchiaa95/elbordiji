// ============================================================================
// supabase/functions/create-platform-user/index.ts
// Creates a full platform account (Email + Password) — SuperAdmin ONLY.
//
// Flow: SuperAdmin UI -> this function -> caller identity verified via the
// caller's own JWT -> superadmin role confirmed in user_roles -> Auth Admin
// API creates the user -> profiles row -> user_roles row bound to the
// requested school_id.
//
// SUPABASE_SERVICE_ROLE_KEY is read server-side only (Deno.env) and never
// appears in any frontend file. verify_jwt stays at its DEFAULT (true).
//
// The school_id and role come from the request body, but BOTH are validated
// server-side: the school must exist in `schools`, and the role must be one
// of the known platform roles. The caller's own privileges are never taken
// from the request — they come from user_roles via the caller's JWT.
// ============================================================================

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!;
const ANON_KEY = Deno.env.get('SUPABASE_ANON_KEY')!;
const SERVICE_ROLE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
// Production origin is the safe default; deploys can widen/override the
// list via the ALLOWED_ORIGINS env var (comma-separated). Never '*'.
const ALLOWED_ORIGINS = (Deno.env.get('ALLOWED_ORIGINS') || 'https://school.elbordiji.com')
  .split(',').map((o) => o.trim()).filter(Boolean);

const ALLOWED_ROLES = ['superadmin', 'admin', 'director', 'guard', 'teacher', 'driver', 'parent'] as const;

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
// Arabic, user-safe error messages — never a raw SQL/Postgres error.
function fail(messageAr: string, status: number, origin: string | null) {
  return json({ error: messageAr }, status, origin);
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

  const fullName = typeof body.fullName === 'string' ? body.fullName.trim() : '';
  const email = typeof body.email === 'string' ? body.email.trim().toLowerCase() : '';
  const password = typeof body.password === 'string' ? body.password : '';
  const schoolId = typeof body.schoolId === 'string' ? body.schoolId.trim() : '';
  const role = typeof body.role === 'string' ? body.role.trim().toLowerCase() : '';

  if (!fullName || fullName.length > 200) return fail('الاسم الكامل مطلوب', 400, origin);
  if (!email || !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) {
    return fail('البريد الإلكتروني غير صالح', 400, origin);
  }
  if (password.length < 8) {
    return fail('كلمة المرور يجب أن تكون 8 أحرف على الأقل', 400, origin);
  }
  if (!schoolId) return fail('المدرسة مطلوبة', 400, origin);
  if (!ALLOWED_ROLES.includes(role as typeof ALLOWED_ROLES[number])) {
    return fail('الدور غير صالح', 400, origin);
  }

  // ---- 1. Identify the caller (via THEIR OWN JWT, not service role) -------
  const callerClient = createClient(SUPABASE_URL, ANON_KEY, {
    global: { headers: { Authorization: authHeader } },
    auth: { autoRefreshToken: false, persistSession: false },
  });

  const { data: userData, error: userErr } = await callerClient.auth.getUser();
  if (userErr || !userData?.user) return fail('جلسة غير صالحة', 401, origin);
  const callerId = userData.user.id;

  // ---- 2. Authorization: caller must hold the superadmin role -------------
  const { data: roleRows, error: roleErr } = await callerClient
    .from('user_roles')
    .select('role')
    .eq('profile_id', callerId);
  if (roleErr || !roleRows || !roleRows.some((r) => r.role === 'superadmin')) {
    return fail('ليس لديك صلاحية لهذه العملية', 403, origin);
  }

  // ---- 3. Validate the target school exists (server-side check) -----------
  const { data: school, error: schoolErr } = await adminClient
    .from('schools').select('id').eq('id', schoolId).maybeSingle();
  if (schoolErr) {
    console.error('school check error:', schoolErr);
    return fail('تعذر التحقق من المدرسة', 500, origin);
  }
  if (!school) return fail('المدرسة غير موجودة', 400, origin);

  // ---- 4. Privileged creation, with compensating rollback on failure ------
  let newUserId: string | null = null;

  try {
    const { data: authUser, error: authErr } = await adminClient.auth.admin.createUser({
      email,
      password,
      email_confirm: true,
      user_metadata: { full_name: fullName, account_type: role },
    });
    if (authErr || !authUser?.user) {
      const msg = (authErr?.message || '').toLowerCase();
      if (msg.includes('already') || msg.includes('duplicate')) {
        return fail('البريد الإلكتروني مستخدم بالفعل', 409, origin);
      }
      if (msg.includes('password')) {
        return fail('كلمة المرور ضعيفة جدًا', 400, origin);
      }
      throw new Error(authErr?.message || 'auth.admin.createUser failed');
    }
    newUserId = authUser.user.id;

    // UPSERT (not plain insert): if the database has an auto-profile
    // trigger on auth.users, the row may already exist the moment
    // createUser returns — a plain insert would then fail with a duplicate
    // key and the whole creation would abort. Upserting on id makes the
    // operation idempotent either way.
    const { error: profileErr } = await adminClient.from('profiles').upsert({
      id: newUserId, full_name: fullName, user_number: email,
    }, { onConflict: 'id' });
    if (profileErr) throw new Error('profile upsert failed: ' + profileErr.message);

    const { error: roleInsertErr } = await adminClient.from('user_roles').insert({
      profile_id: newUserId, school_id: schoolId, role,
    });
    // A duplicate role row means the account already has this role — that
    // is a success state, not a failure.
    if (roleInsertErr && !(roleInsertErr.message || '').toLowerCase().includes('duplicate')) {
      throw new Error('role insert failed: ' + roleInsertErr.message);
    }

    // Staff-record parity with create-staff-account: a guard/teacher/driver/
    // parent ALSO needs its row in guards/teachers/drivers/parents, otherwise
    // the account is invisible in the school console lists (those lists read
    // the staff tables under RLS). Idempotent via the existing
    // unique(profile_id, school_id) constraints.
    if (role === 'guard' || role === 'teacher' || role === 'driver' || role === 'parent') {
      const { error: staffErr } = await adminClient
        .from(role + 's')
        .upsert({ profile_id: newUserId, school_id: schoolId },
                { onConflict: 'profile_id,school_id', ignoreDuplicates: true });
      if (staffErr) throw new Error('staff record insert failed: ' + staffErr.message);
    }

    // Audit trail — reuses the existing fn_write_audit; never logs the
    // password.
    await adminClient.rpc('fn_write_audit', {
      p_school_id: schoolId,
      p_action: 'CREATE_PLATFORM_USER',
      p_entity: 'profiles',
      p_entity_id: newUserId,
      p_old: null,
      p_new: { full_name: fullName, email, role },
    });

    return json({ ok: true, profileId: newUserId, email }, 200, origin);
  } catch (err) {
    console.error('create-platform-user failed, rolling back:', err);
    // Compensating rollback: remove a half-created auth user so a retry
    // with the same email doesn't collide with an orphaned row.
    if (newUserId) {
      await adminClient.auth.admin.deleteUser(newUserId).catch((e) =>
        console.error('rollback deleteUser also failed:', e));
    }
    // TEMPORARY DIAGNOSIS: surface the real server-side reason so the
    // actual failure can be identified from the UI, instead of a blind
    // generic message. (No secrets are exposed — only the step + message.)
    const detail = err instanceof Error ? err.message : String(err);
    return fail('تعذر إنشاء الحساب: ' + detail, 500, origin);
  }
});
