# AI Usage Policy for Zangetsu

**Last Updated: August 3, 2026**

AI tools (Copilot, ChatGPT, Claude, Cursor, etc.) are welcome for contributing to Zangetsu — used well, they're a normal part of how software gets written in 2026. This policy exists to make sure AI-assisted contributions meet the same bar as any other contribution: correct, legally clean, and something a human actually understands and stands behind.

---

## TL;DR

- AI-assisted contributions are **allowed**.
- You must **disclose** that AI was used, and to what extent.
- You are **fully responsible** for AI-generated code you submit — "the AI wrote it" is not a defense against bugs, license violations, or security issues.
- You must **understand and have tested** anything you submit, AI-written or not.
- Extra care applies to **providers/extractors** — see Section 5.
- The CLA still applies in full; AI assistance doesn't change your obligations under it. In fact, the CLA's Section 5 promises now explicitly include "if AI tools were used to help create the Contribution, its use complies with this policy" — so signing the CLA means agreeing to this document too.

---

## 1. Disclosure Requirement

If a Contribution was substantially written, generated, or refactored with AI assistance, say so in the pull request description. A short note is enough:

```
AI assistance: used Claude to draft the initial extractor logic, reviewed
and tested manually.
```

You don't need to disclose minor, ordinary uses (autocomplete-style suggestions, AI-assisted debugging of your own code, spell-checking a comment). The bar is: **if a reviewer would reasonably want to know AI was involved in producing the logic, disclose it.**

Non-disclosure of substantial AI-generated content, discovered later, will be treated as a good-faith violation of this policy and may result in the PR being closed and future Contributions receiving closer scrutiny.

---

## 2. You Own What You Submit

Submitting an AI-assisted Contribution means you are certifying, same as with any other Contribution under the [CLA](CLA.md):

- You've **read and understood** the code, not just pasted it in.
- You've **tested it** — AI-generated code frequently looks plausible while being subtly wrong, especially around edge cases, async logic, and platform-specific behavior.
- You take responsibility for bugs, security issues, or license problems it introduces, exactly as if you'd written it by hand.

"An AI wrote this" is never an acceptable answer to "why does this code do X" during review.

---

## 3. License and Copyright Cleanliness

AI models can reproduce memorized snippets from their training data, sometimes verbatim, without flagging that it's someone else's copyrighted or differently-licensed code. Before submitting AI-assisted code:

- Check for anything that looks like it was lifted from a specific existing project (unusual comments, distinctive variable names matching a known library, license headers, etc.).
- If AI output includes or closely resembles code from a project under a license incompatible with GPLv3 (or requiring attribution you haven't given), **do not submit it** — rewrite the logic yourself or find a compatible reference implementation.
- This is the same disclosure obligation already in **Section 5 of the CLA** ("if the Contribution includes third-party code, assets, data, or references, you have clearly identified them...") — AI-generated code is not exempt just because a model produced it instead of a human copy-pasting.
- If your Contribution is derived from, or closely modeled on, a specific third-party project (the way Zangetsu's existing CloudStream and Aniyomi/Tachiyomi integrations are), that needs its own entry in [`NOTICE.md`](NOTICE.md), same as any other third-party-derived code — regardless of whether a human or an AI wrote the derivation.

---

## 4. Security

AI-generated code has a track record of introducing subtle security issues — unsanitized inputs, weak crypto usage, unsafe deserialization, secrets accidentally hardcoded, overly permissive exported components, etc. If your Contribution touches:

- Authentication or token handling
- Anything parsing untrusted input (subtitles, remote JSON/config, `.cs3`-style extension payloads)
- Network requests to third-party sources

review AI-generated code in those paths especially carefully, and call it out in your PR so reviewers know to look closely.

---

## 5. Providers, Extractors, and Scraping Logic

This is the area where AI-assisted contributions need the most caution, because the legal risk isn't just about Zangetsu's own code:

- **Don't let AI invent plausible-looking scraping logic for a source you haven't personally verified.** AI models will confidently generate code that *looks* like it scrapes a real site correctly while being outdated, wrong, or targeting something that never worked to begin with.
- **Don't use AI to help bypass anti-scraping protections, rate limits, DRM, or authentication on a third-party source** you don't have the right to access that way. This applies regardless of whether a human or an AI wrote the bypass.
- If an AI-assisted provider/extractor PR is later found to violate a source's terms of service in a way you didn't personally verify, responsibility for that still falls on you as the Contributor, per the CLA's indemnification terms (Section 8).

---

## 6. What AI Assistance Is Good For Here

To be clear this isn't a discouragement policy — AI tools are genuinely useful for:

- Drafting documentation, README updates, and code comments
- Writing and expanding test coverage
- Boilerplate (DTOs, serialization models, repetitive UI scaffolding)
- Debugging assistance and explaining unfamiliar code
- Translation drafts (still needs a fluent human to check accuracy — see `CONTRIBUTING.md`)
- Refactoring suggestions you then review and apply deliberately

Use it for these freely, disclosure requirements in Section 1 still apply where relevant.

---

## 7. Maintainer Review Rights

Maintainers may ask you directly whether/how AI was used on any PR, and may request additional explanation or testing evidence for AI-assisted Contributions before merging. This isn't an accusation — it's a normal part of review, the same way a maintainer might ask about a Contribution's origin for any other reason.

Maintainers reserve the right to decline AI-assisted Contributions that don't meet the bar in Sections 2–5, same as any other Contribution that isn't ready to merge.

---

## 8. Relationship to the CLA and LICENSE

This policy doesn't modify the [CLA](CLA.md) or [LICENSE](LICENSE) — it clarifies how existing obligations (originality, no undisclosed third-party code, indemnification, no warranty) apply specifically to AI-assisted work. Where anything here seems to conflict with the CLA or LICENSE, those documents control.

---

Questions about this policy? Open an issue and ask.
