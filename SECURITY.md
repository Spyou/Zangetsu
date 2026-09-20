# Security Policy

**Last Updated: September 18, 2026**

Thanks for looking. If you've found a security problem in Zangetsu, please report it privately first — a public issue makes it exploitable before there's a fix.

---

## How to report

**Use GitHub's private vulnerability reporting:**

[**→ Report a vulnerability**](https://github.com/Spyou/Zangetsu/security/advisories/new)

(Also reachable from the repo's **Security** tab → *Report a vulnerability*.)

That opens a private thread only the maintainer can see. It's the preferred route — no email address to find, and the whole discussion, fix and disclosure live in one place.

Please **don't** open a public issue, PR, or Discord post for a vulnerability until it's fixed.

---

## What to include

The more of this you have, the faster it gets fixed:

- What the problem is, and what an attacker gets out of it
- Steps to reproduce — a minimal case beats a long description
- App version, platform (Android / TV / iOS), and the source or extension involved, if any
- A fix, if you have one. A failing test that passes after the fix is ideal.

---

## Scope

**In scope** — anything in this repository:

- The Flutter app and its Android/iOS native code
- The extension bridges (CloudStream, Aniyomi, Mihon, LNReader) and the JS runtime that hosts them
- Supabase Edge Functions under `supabase/functions/`
- Backup, sync, tracker and account-migration flows
- Anything that leaks credentials, tokens, cookies or user data

**Out of scope:**

- **Third-party extensions and the sites they scrape.** Zangetsu ships no sources — extensions are installed by the user from repositories they choose. Bugs in someone else's extension belong to that extension's author. A bug in *how this app loads or sandboxes* an extension is very much in scope.
- Anything requiring a rooted device, a malicious build, or physical access to an unlocked phone
- Missing hardening that isn't exploitable on its own (no HSTS, no certificate pinning, and so on) — still worth mentioning, just not treated as urgent
- Reports from automated scanners with no demonstrated impact

---

## What to expect

This is a small project maintained by one person, so please be realistic about timing:

- **Acknowledgement:** within a few days
- **Assessment:** an honest answer on whether it's a real issue and how serious
- **Fix:** as fast as severity warrants — a credential or data-exposure bug jumps the queue

You'll be credited in the advisory unless you'd rather not be. There's no bounty programme; this is a free, open-source app.

---

## Disclosure

Please give a fix a reasonable chance to ship before going public. If a report goes quiet on the maintainer's side for a long stretch, you're within your rights to disclose — just say so first.

Fixed issues are published as GitHub Security Advisories on this repository.
