// Invisible account migration: verifies a user against the legacy Appwrite
// backend, then creates/heals/links their Supabase account and claims their
// legacy-uid-keyed rows. Called pre-auth (no Supabase JWT yet), so this
// function must do its own credential check against Appwrite before touching
// admin APIs.
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { verifyPassword, verifyJwt } from "../_shared/appwrite-verify.ts";
import { decideCase } from "./decide.ts";

const admin = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  { auth: { autoRefreshToken: false, persistSession: false } },
);

Deno.serve(async (req) => {
  try {
    const body = await req.json();
    const credential: "password" | "jwt" = body.appwriteJwt ? "jwt" : "password";

    // 1. Verify against Appwrite.
    const v = credential === "jwt"
      ? await verifyJwt(body.appwriteJwt)
      : await verifyPassword(body.email, body.password);
    if (!v.ok || !v.legacyUid || !v.email) return json({ ok: false, error: "verify_failed" }, 401);

    // 2. Does a Supabase user already exist for this email?
    const { data: list, error: listErr } = await admin.auth.admin.listUsers();
    if (listErr) return json({ ok: false, error: "server_error" }, 500);
    const existing = list.users.find((u) => u.email?.toLowerCase() === v.email!.toLowerCase());
    const profile = existing
      ? (await admin.from("profiles").select("*").eq("id", existing.id).maybeSingle()).data
      : null;

    const kase = decideCase({
      hasSupabaseUser: !!existing,
      needsPasswordCapture: !!profile?.needs_password_capture,
      credential,
    });

    let userId = existing?.id;

    if (kase === "create") {
      const password = credential === "password" ? body.password : crypto.randomUUID();
      const { data: created, error } = await admin.auth.admin.createUser({
        email: v.email, password, email_confirm: true,
        user_metadata: { name: v.name ?? "" },
      });
      if (error || !created.user) return json({ ok: false, error: "create_failed" }, 500);
      userId = created.user.id;
      await admin.from("profiles").upsert({
        id: userId, display_name: v.name ?? "", legacy_uid: v.legacyUid,
        needs_password_capture: credential === "jwt", // JWT path used a random pw
      });
    } else if (kase === "heal") {
      await admin.auth.admin.updateUserById(userId!, { password: body.password });
      await admin.from("profiles").update({ needs_password_capture: false }).eq("id", userId!);
    } else if (kase === "link_existing") {
      // ensure the legacy link + data claim happen even if the row pre-existed
      await admin.from("profiles").update({ legacy_uid: v.legacyUid }).eq("id", userId!);
    } else {
      // decideCase's "reject" is not reachable from the inputs this function
      // passes (verify already failed fast above), but guard anyway rather
      // than silently falling through to claimData with no case handled.
      return json({ ok: false, error: "rejected" }, 403);
    }

    // 3. Claim data: relabel legacy rows to the Supabase uid.
    await claimData(v.legacyUid, userId!);

    // 4. For Case-2 (jwt), hand back a one-time sign-in since the app has no
    // Supabase password to sign in with directly.
    if (credential === "jwt") {
      const { data: link, error: linkErr } = await admin.auth.admin.generateLink({
        type: "magiclink",
        email: v.email,
      });
      if (linkErr) return json({ ok: false, error: "server_error" }, 500);
      return json({ ok: true, session: { email: v.email, token: link?.properties?.email_otp } });
    }
    // Case-1 password path: app already has the password, it signs in itself.
    return json({ ok: true });
  } catch (_e) {
    return json({ ok: false, error: "server_error" }, 500);
  }
});

async function claimData(legacyUid: string, newUid: string) {
  for (const t of ["mylist", "history", "backups"]) {
    await admin.from(t).update({ user_key: newUid }).eq("user_key", legacyUid);
  }
  // avatar: point profile at the legacy-uploaded object if present and profile has none
  const path = `legacy/${legacyUid}.jpg`;
  await admin.from("profiles").update({ avatar_path: path })
    .eq("id", newUid).is("avatar_path", null);
}

function json(b: unknown, status = 200) {
  return new Response(JSON.stringify(b), { status, headers: { "content-type": "application/json" } });
}
