export type DecideInput = {
  hasSupabaseUser: boolean;
  needsPasswordCapture: boolean;
  credential: "password" | "jwt";
};
export type Case = "create" | "heal" | "link_existing" | "reject";

// Called only AFTER the Appwrite credential/JWT has been verified ok.
export function decideCase(i: DecideInput): Case {
  if (!i.hasSupabaseUser) return "create";
  if (i.credential === "password" && i.needsPasswordCapture) return "heal";
  return "link_existing";
}
