// transfer_funds — a guarded agent tool (Rust)
// =============================================
//
// WHAT AN AGENT TOOL IS
// ---------------------
// An LLM agent cannot execute code; it only produces text. To let it act, you give it
// *tools*. A tool is four things:
//
//   - a NAME              -> "transfer_funds"
//   - a DESCRIPTION       -> natural language the model reads to decide WHEN to use it
//   - a PARAMETERS schema -> the typed arguments the model is allowed to fill in
//   - a FUNCTION          -> the code your runtime runs when the model picks the tool
//
// At run time the model emits a *tool call* — the name plus a JSON object of arguments:
//
//   { "name": "transfer_funds", "arguments": { "amount": 10000, "to": "acct_123" } }
//
// Your agent runtime parses that, calls the function below with those arguments, and feeds
// its RETURN VALUE back to the model as the tool result. The model reads that string and
// decides what to do next.
//
// So the agent controls exactly two things: WHICH tool, and the ARGUMENT VALUES.
// It never sees, edits, reorders, or skips the function body.
//
// WHY THE GUARD LIVES INSIDE THE FUNCTION
// ---------------------------------------
// Because the body is unreachable to the agent, whatever you put there runs on EVERY
// invocation and cannot be bypassed — not by a confused model, not by a jailbroken one,
// not by prompt injection. Wrapping the sensitive call in `warrant.guard(...)` makes the
// human-approval gate unbypassable: there is no path to the transfer that skips the guard.
//
// The agent can still change the arguments — but that only changes the action FINGERPRINT,
// producing a different approval request for a different action. An approval for one action
// can never be spent on another.
//
// (The opposite, broken design is a separate `request_approval` tool the agent must call
// first. Nothing forces the order, so the agent can just skip it.)
//
// NOTE: the `warrant` crate, `payments`, and `serde_json` usage here are illustrative —
// this shows the protocol's shape, not a published crate. See ../WARRANT.md.

use serde_json::{json, Value};
use warrant::{Client, GuardResult}; // illustrative SDK

// This schema is the ENTIRE surface the model can act on: a name, a description, and the
// argument shape. Notice what is NOT here — no "skip approval" flag, and no mention of
// Warrant. The gate is an implementation detail the model is unaware of.
fn tool_schema() -> Value {
    json!({
        "name": "transfer_funds",
        "description": "Transfer money from the company account to a destination account.",
        "parameters": {
            "type": "object",
            "properties": {
                "amount": { "type": "integer", "description": "Amount to transfer, in dollars." },
                "to":     { "type": "string",  "description": "Destination account id, e.g. acct_123." }
            },
            "required": ["amount", "to"]
        }
    })
}

// The function the runtime invokes with the model-supplied arguments. The `warrant` client
// is passed in (share one across the process). Everything in this body is invisible and
// unreachable to the agent.
fn transfer_funds(warrant: &Client, amount: u64, to: &str) -> String {
    // The action is what the committee signs. Its fingerprint binds the approval to THIS
    // exact transfer; params are strings so the hash is identical in every language (§4.1).
    let action = json!({
        "type": "transfer_funds",
        "params": { "amount": amount.to_string(), "to": to }
    });

    // The closure runs ONLY after a valid, matching proof is verified locally — i.e. only
    // after the committee approved this exact action. The agent cannot reach it.
    let result = warrant.guard(
        "cmte_finance_approvals",                 // which committee must approve
        &action,                                  // what they're approving (fingerprinted)
        &format!("Transfer ${amount} to {to}."),  // human-readable context; NOT fingerprinted
        |grant| {
            // grant.idempotency_key (the fingerprint) makes an accidental double-run a
            // single real transfer; thread it into whatever performs the side effect.
            payments::transfer(amount, to, &grant.idempotency_key)
        },
    );

    // The return value goes back to the model as the tool result — plain text it acts on.
    match result {
        GuardResult::Approved => format!("Done — transferred ${amount} to {to}."),
        // Not decided yet. The model's natural next step — call this tool again with the
        // SAME arguments — IS the resume: same args -> same fingerprint -> same request.
        GuardResult::Pending => "Awaiting committee approval. The approvers have been \
             notified. Call this tool again with the same arguments in a few minutes."
            .to_string(),
        GuardResult::Denied => "The committee rejected this transfer. Do not retry.".to_string(),
    }
}

// How a runtime dispatches a tool call (illustrative). Every framework reduces to this:
// match the tool by name, call its function with the model's arguments, return the result
// to the model. The agent never touches the function body above.
fn handle_tool_call(warrant: &Client, name: &str, args: &Value) -> String {
    match name {
        "transfer_funds" => transfer_funds(
            warrant,
            args["amount"].as_u64().expect("amount"),
            args["to"].as_str().expect("to"),
        ),
        other => panic!("unknown tool: {other}"),
    }
}
