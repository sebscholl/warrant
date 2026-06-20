/**
 * transfer_funds — a guarded agent tool (TypeScript)
 * ==================================================
 *
 * WHAT AN AGENT TOOL IS
 * ---------------------
 * An LLM agent cannot execute code; it only produces text. To let it act, you give it
 * *tools*. A tool is four things:
 *
 *   - a NAME              -> "transfer_funds"
 *   - a DESCRIPTION       -> natural language the model reads to decide WHEN to use it
 *   - a PARAMETERS schema -> the typed arguments the model is allowed to fill in
 *   - a FUNCTION          -> the code your runtime runs when the model picks the tool
 *
 * At run time the model emits a *tool call* — the name plus a JSON object of arguments:
 *
 *   { "name": "transfer_funds", "arguments": { "amount": 10000, "to": "acct_123" } }
 *
 * Your agent runtime parses that, calls the function below with those arguments, and feeds
 * the function's RETURN VALUE back to the model as the tool result. The model reads that
 * string and decides what to do next.
 *
 * So the agent controls exactly two things: WHICH tool, and the ARGUMENT VALUES.
 * It never sees, edits, reorders, or skips the function body.
 *
 * WHY THE GUARD LIVES INSIDE THE FUNCTION
 * ---------------------------------------
 * Because the body is unreachable to the agent, whatever you put there runs on EVERY
 * invocation and cannot be bypassed — not by a confused model, not by a jailbroken one,
 * not by prompt injection. Wrapping the sensitive call in `warrant.guard(...)` makes the
 * human-approval gate unbypassable: there is no path to the transfer that skips the guard.
 *
 * The agent can still change the arguments — but that only changes the action FINGERPRINT,
 * producing a different approval request for a different action. An approval for one
 * action can never be spent on another.
 *
 * (The opposite, broken design is a separate `request_approval` tool the agent must call
 * first. Nothing forces the order, so the agent can just skip it.)
 *
 * NOTE: `warrant`, `payments`, and the framework here are illustrative — this shows the
 * protocol's shape, not a published package. See ../WARRANT.md.
 */

import { Warrant } from "warrant"; // illustrative SDK

const warrant = new Warrant({ apiKey: process.env.WARRANT_API_KEY! });

// The three replies the model can get back — short instructions it will act on.
const APPROVED = "Done — the transfer completed.";
const PENDING = "Awaiting committee approval. Call this tool again with the same arguments shortly.";
const DENIED = "The committee rejected this transfer. Do not retry.";

// This definition is the ENTIRE surface the model can act on: a name, a description, and
// the argument shape. Notice what is NOT here — no "skip approval" flag, and no mention of
// Warrant. The gate is an implementation detail the model is unaware of.
export const transferFundsTool = {
  name: "transfer_funds",
  description: "Transfer money from the company account to a destination account.",
  parameters: {
    type: "object",
    properties: {
      amount: { type: "integer", description: "Amount to transfer, in dollars." },
      to: { type: "string", description: "Destination account id, e.g. acct_123." },
    },
    required: ["amount", "to"],
  },
} as const;

// The function the runtime invokes with the model-supplied arguments.
// Everything inside this function is invisible and unreachable to the agent.
export async function transferFunds({ amount, to }: { amount: number; to: string }): Promise<string> {
  // The ACTION is the data the committee signs. Its fingerprint binds the approval to
  // THIS exact transfer. params are strings so the hash is identical in every language
  // (spec §4.1 — no raw numbers).
  const action = { type: "transfer_funds", params: { amount: String(amount), to } };

  const result = await warrant.guard(
    "cmte_finance_approvals",                 // which committee must approve
    action,                                   // what they're approving (fingerprinted)
    { message: `Transfer $${amount} to ${to}.` }, // human-readable context; NOT fingerprinted
    // This callback runs ONLY after a valid, matching proof is verified locally — i.e.
    // only after the committee approved this exact action. The agent can't reach it.
    async (grant) =>
      // `grant.idempotencyKey` (the fingerprint) makes an accidental double-run a single
      // real transfer; thread it into whatever performs the side effect.
      payments.transfer({ amount, to, idempotencyKey: grant.idempotencyKey }),
  );

  // The return value goes back to the model as the tool result. Calling this tool again
  // with the SAME arguments on "pending" IS the resume: same args -> same fingerprint.
  switch (result.status) {
    case "approved": return APPROVED;
    case "pending":  return PENDING;
    case "denied":   return DENIED;
  }
}

// How a runtime dispatches a tool call (illustrative). Every framework reduces to this:
// match the tool by name, call its function with the model's arguments, return the result
// to the model. The agent never touches the function body above.
export const tools = { transfer_funds: transferFunds } as const;
