// Verifies a user against the legacy Appwrite backend during account migration.
// Read-only from Supabase's perspective: never writes to Appwrite except the
// throwaway session created to check a password.
const AW_ENDPOINT = "https://sgp.cloud.appwrite.io/v1";
const AW_PROJECT = "6a1ed44f0029b50bccde";

type AwResult = { ok: boolean; legacyUid?: string; name?: string; email?: string };

// Verify email+password by creating an email-password session, then reading
// /account with that session. Any non-2xx or thrown error is treated as a
// failed verification (never leaks Appwrite error details to the caller).
export async function verifyPassword(email: string, password: string): Promise<AwResult> {
  try {
    const res = await fetch(`${AW_ENDPOINT}/account/sessions/email`, {
      method: "POST",
      headers: { "content-type": "application/json", "X-Appwrite-Project": AW_PROJECT },
      body: JSON.stringify({ email, password }),
    });
    if (!res.ok) return { ok: false };
    const session = await res.json();
    return await meFromSession(res.headers, session);
  } catch (_e) {
    return { ok: false };
  }
}

async function meFromSession(headers: Headers, session: { secret?: string }): Promise<AwResult> {
  // Appwrite's session-creation response carries the session cookie via
  // set-cookie; if that isn't forwardable server-to-server, fall back to the
  // session secret as an X-Appwrite-Session header (both paths are exercised
  // at deploy time against the live project — see task-4-6-report.md).
  const cookie = headers.get("set-cookie");
  const authHeaders: Record<string, string> = { "X-Appwrite-Project": AW_PROJECT };
  if (cookie) {
    authHeaders["cookie"] = cookie;
  } else if (session.secret) {
    authHeaders["X-Appwrite-Session"] = session.secret;
  } else {
    return { ok: false };
  }

  try {
    const res = await fetch(`${AW_ENDPOINT}/account`, { headers: authHeaders });
    if (!res.ok) return { ok: false };
    const u = await res.json();
    return { ok: true, legacyUid: u.$id, name: u.name, email: u.email };
  } catch (_e) {
    return { ok: false };
  }
}

// Verify a client-minted Appwrite JWT (Case 2: user still has a live Appwrite session).
export async function verifyJwt(jwt: string): Promise<AwResult> {
  try {
    const res = await fetch(`${AW_ENDPOINT}/account`, {
      headers: { "X-Appwrite-Project": AW_PROJECT, "X-Appwrite-JWT": jwt },
    });
    if (!res.ok) return { ok: false };
    const u = await res.json();
    return { ok: true, legacyUid: u.$id, name: u.name, email: u.email };
  } catch (_e) {
    return { ok: false };
  }
}
