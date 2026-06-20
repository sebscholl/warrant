// transfer_funds — a guarded agent tool (C#)
// ==========================================
//
// WHAT AN AGENT TOOL IS
// ---------------------
// An LLM agent cannot execute code; it only produces text. To let it act, you give it
// *tools*. A tool is four things:
//
//   - a NAME              -> "transfer_funds"
//   - a DESCRIPTION       -> natural language the model reads to decide WHEN to use it
//   - a PARAMETERS schema -> the typed arguments the model is allowed to fill in
//   - a METHOD            -> the code your runtime runs when the model picks the tool
//
// At run time the model emits a *tool call* — the name plus a JSON object of arguments:
//
//   { "name": "transfer_funds", "arguments": { "amount": 10000, "to": "acct_123" } }
//
// Your agent runtime parses that, calls the method below with those arguments, and feeds
// its RETURN VALUE back to the model as the tool result. The model reads that string and
// decides what to do next.
//
// So the agent controls exactly two things: WHICH tool, and the ARGUMENT VALUES.
// It never sees, edits, reorders, or skips the method body.
//
// Here the [KernelFunction] + [Description] attributes ARE the schema the model sees: the
// framework reflects over them to build the name/description/parameters the model is
// offered. (This is Semantic Kernel style; the idea is identical in any .NET agent stack.)
//
// WHY THE GUARD LIVES INSIDE THE METHOD
// -------------------------------------
// Because the body is unreachable to the agent, whatever you put there runs on EVERY
// invocation and cannot be bypassed — not by a confused model, not by a jailbroken one,
// not by prompt injection. Wrapping the sensitive call in `_warrant.Guard(...)` makes the
// human-approval gate unbypassable: there is no path to the transfer that skips the guard.
//
// The agent can still change the arguments — but that only changes the action FINGERPRINT,
// producing a different approval request for a different action. An approval for one action
// can never be spent on another.
//
// (The opposite, broken design is a separate `request_approval` tool the agent must call
// first. Nothing forces the order, so the agent can just skip it.)
//
// NOTE: the Warrant client, Payments, and the framework attributes here are illustrative —
// this shows the protocol's shape, not a published package. See ../WARRANT.md.

using System;
using System.ComponentModel;       // [Description]
using Microsoft.SemanticKernel;    // [KernelFunction] (illustrative)
using Warrant;                     // illustrative SDK

public class TreasuryTools
{
    // Share one client across the process.
    private readonly WarrantClient _warrant =
        new(Environment.GetEnvironmentVariable("WARRANT_API_KEY"));

    // The three replies the model can get back — short instructions it will act on.
    private const string APPROVED = "Done — the transfer completed.";
    private const string PENDING = "Awaiting committee approval. Call this tool again with the same arguments shortly.";
    private const string DENIED = "The committee rejected this transfer. Do not retry.";

    // The attributes below are the ENTIRE surface the model can act on: a name, a
    // description, and the typed parameters. Notice what is NOT here — no "skip approval"
    // parameter, and no mention of Warrant. The gate is invisible to the model.
    [KernelFunction("transfer_funds")]
    [Description("Transfer money from the company account to a destination account.")]
    public string TransferFunds(
        [Description("Amount to transfer, in dollars.")] int amount,
        [Description("Destination account id, e.g. acct_123.")] string to)
    {
        // The action is what the committee signs. Its fingerprint binds the approval to
        // THIS exact transfer; params are strings so the hash is identical in every
        // language (§4.1). `@params` is the C# escape for the JSON key "params".
        var action = new
        {
            type = "transfer_funds",
            @params = new { amount = amount.ToString(), to }
        };

        // The callback runs ONLY after a valid, matching proof is verified locally — i.e.
        // only after the committee approved this exact action. The agent cannot reach it.
        var result = _warrant.Guard(
            committee: "cmte_finance_approvals",          // who must approve
            action: action,                               // what they're approving (fingerprinted)
            message: $"Transfer ${amount} to {to}.",      // human-readable context; NOT fingerprinted
            onGrant: grant =>
                // grant.IdempotencyKey (the fingerprint) makes an accidental double-run a
                // single real transfer; thread it into whatever performs the side effect.
                Payments.Transfer(amount, to, grant.IdempotencyKey));

        // The return value goes back to the model as the tool result. Calling this tool
        // again with the SAME arguments on Pending IS the resume: same args -> same fingerprint.
        return result.Status switch
        {
            GuardStatus.Approved => APPROVED,
            GuardStatus.Pending => PENDING,
            GuardStatus.Denied => DENIED,
            _ => throw new InvalidOperationException($"unexpected status: {result.Status}")
        };
    }
}
