import { assertEquals } from "https://deno.land/std/assert/mod.ts";
import { decideCase } from "./decide.ts";

Deno.test("fresh password login, no supabase user -> create", () => {
  assertEquals(decideCase({ hasSupabaseUser: false, needsPasswordCapture: false, credential: "password" }), "create");
});
Deno.test("password login, existing user flagged for capture -> heal", () => {
  assertEquals(decideCase({ hasSupabaseUser: true, needsPasswordCapture: true, credential: "password" }), "heal");
});
Deno.test("jwt (case 2), no supabase user -> create", () => {
  assertEquals(decideCase({ hasSupabaseUser: false, needsPasswordCapture: false, credential: "jwt" }), "create");
});
Deno.test("password login, existing verified user not flagged -> link_existing (dedupe)", () => {
  assertEquals(decideCase({ hasSupabaseUser: true, needsPasswordCapture: false, credential: "password" }), "link_existing");
});
Deno.test("jwt, existing user -> link_existing", () => {
  assertEquals(decideCase({ hasSupabaseUser: true, needsPasswordCapture: false, credential: "jwt" }), "link_existing");
});
