# The Warrant Protocol

*A protocol specification (`warrant/1.0`) — not a package you install. The code below shows how a **conformant** SDK is used; building one, in any language, is up to you.*

**Some actions are too important to leave to a prompt.**

You can tell an agent "only wire money if the user really confirms." But a prompt is an inconvenience, not a security boundary — a jailbreak, an injected instruction, or a bad day for the model, and the wire goes out anyway.

The Warrant Protocol puts a **real gate** in front of those actions: the sensitive code literally **cannot run** until a group of one or more humans — a **committee** — has approved it. Each approval is cryptographically signed and bound to the *exact* action, so an approval for "transfer $10" can never be spent on "transfer $10,000,000," and a prompt-injected agent can't forge one.

Every agent framework already has *some* human-in-the-loop step. But that step usually hands your code a boolean to trust — and anything that can reach that code path can flip it. Warrant replaces the trusted flag with a portable cryptographic proof, bound to the exact action and re-verified by your own code before it runs. The platform never gets to say "yes" for you. That difference is the whole protocol.

---

## The idea in one example

You expose a normal tool to your agent — say `transfer_funds`. Inside that tool, you wrap the dangerous part in a `guard`:

```ruby
warrant = Warrant::Client.new(api_key: ENV["WARRANT_API_KEY"])

# Three outcomes, three replies — each phrased as an instruction the agent acts on.
APPROVED = "Done — the transfer completed."
PENDING  = "Awaiting committee approval. Call this tool again with the same arguments in a few minutes."
DENIED   = "The committee rejected this transfer. Do not retry."

# A normal tool your agent calls. The agent never sees Warrant — it just
# calls transfer_funds(...) and reads the string it gets back.
def transfer_funds(amount:, to:)
  # The action is what the committee signs. Its fingerprint binds the approval to
  # THIS exact transfer; params are strings so the hash is identical in every language.
  action = {
    type: "transfer_funds",
    params: { amount: amount.to_s, to: }
  }

  # Human-readable context for the approvers. Shown to them, never part of the fingerprint.
  message = "Transfer $#{amount} to #{to}."

  # The block runs ONLY after the committee approves this exact action.
  result = warrant.guard("cmte_finance_approvals", action:, message:) do |grant|
    # Each retry re-runs this block; idempotency_key keeps a double-run a single transfer.
    Payments.transfer!(amount:, to:, idempotency_key: grant.idempotency_key)
  end

  # Map the outcome to the reply the agent receives.
  case result
  when Warrant::Approved then APPROVED
  when Warrant::Pending  then PENDING
  when Warrant::Denied   then DENIED
  end
end
```

That's the whole integration. No request IDs to track, no webhooks to wire up, no state to store — because the action's own fingerprint is the handle.

---

## What actually happens

**The trick: the agent's ordinary "try again later" behavior _is_ the resume.** An asynchronous, multi-human approval that can take minutes or hours looks, to the agent, like a tool that was briefly busy. Here is the full sequence.

The first time the agent calls the tool:

1. The committee can't have approved yet, so the `guard` block **does not run**.
2. The SDK opens an approval request on the platform, and the **platform** notifies the humans (Slack, email, however the committee is set up).
3. The `guard` returns a `Pending` status. You decide what the tool says back to the agent — here we return *"call this tool again with the same arguments in a few minutes,"* and the agent does exactly that.

A few minutes later the agent retries with the **same arguments**:

1. The SDK recognizes it as the same action — the same arguments hash to the same fingerprint — and finds the existing request.
2. If the committee approved, the SDK verifies the signed proof **locally** and runs your `guard` block. The transfer goes out.
3. If they rejected, the agent gets *"do not retry"* and moves on.

---

## Why it's safe

The guarantee is narrow and strong: **nothing runs unless a human approved this exact action.** It can't stop a human from approving a bad action they were shown — the committee is still the judgment call. What it removes is everything *else*: forgery, tampering, and "the agent decided on its own."

**The approval is bound to the action.** Every action is reduced to a **fingerprint** — a hash of `{ version, committee, type, params }`. Humans sign an approval *bound to that fingerprint*. Change anything and it's a different fingerprint with no approval. There is no "approved = yes" flag to reuse.

**The same action always has the same fingerprint.** That's why you carry no request ID across the wait. "Retry the same action" is a content-addressed lookup — it works after a crash, a redeploy, or on a different machine. Most integrations need **zero developer-maintained storage**.

**Your code is the final authority.** The platform collects signatures, but your SDK **re-verifies them locally** and recomputes the fingerprint before running the block. A leaked proof is an audit-log entry, not a breach — the dangerous code lives in your process, which the platform never sees. (The one thing local re-verification can't catch is a *compromised platform* that holds the signing keys — that's what self-custody and pinning are for; see the spec's trust model.)

---

## The same thing, other languages

It's a protocol, not a library — any client in any language works the same way.

**TypeScript**

```ts
// The three replies the agent can get back — phrased as instructions to it.
const APPROVED = "Done — the transfer completed.";
const PENDING  = "Awaiting committee approval. Call this tool again with the same arguments in a few minutes.";
const DENIED   = "The committee rejected this transfer. Do not retry.";

// The action is what the committee signs. Its fingerprint binds the approval to
// THIS exact transfer; params are strings so the hash is identical in every language.
const action = { type: "transfer_funds", params: { amount: String(amount), to } };

// Human-readable context for the approvers. Shown to them, never part of the fingerprint.
const message = `Transfer $${amount} to ${to}.`;

// The callback runs ONLY after the committee approves this exact action.
const result = await warrant.guard(
  "cmte_finance_approvals",
  action,
  { message },
  async (grant) => await payments.transfer({ amount, to, idempotencyKey: grant.idempotencyKey }),
);

// Map the outcome to the reply the agent receives.
switch (result.status) {
  case "approved": return APPROVED;
  case "pending":  return PENDING;
  case "denied":   return DENIED;
}
```

**CLI** — wrap any command; "resume" is just running it again:

```
# Wrap any command. The agent runs the SAME command every time —
# "resume" is just running it again.
warrant guard cmte_finance_approvals \
  --type  transfer_funds \
  --param amount=10000 \
  --param to=acct_123 \
  -- ./do_transfer.sh

# Pending  → exit 75:  "Awaiting approval — approvers notified. Re-run shortly."
# Approved → runs ./do_transfer.sh, exit 0:  "Done."
# Rejected → exit 1:   "Committee rejected this. Do not retry."
```

Full, heavily-commented versions of these tools — Python, TypeScript, Ruby, Rust, C#, and CLI — are in [`examples/`](examples/), with notes on how an agent invokes a tool and why the guard goes *inside* it. There's also a no-SDK walkthrough that hits the raw REST API directly and re-validates the proof by hand.

---

## The full specification

This README is the tour. **[WARRANT.md](WARRANT.md)** (`warrant/1.0`) is the contract: the exact byte-strings to hash and sign, the REST endpoints, the approval lifecycle, and the precise conformance requirements for building a compliant platform or client.

---

## License

The Warrant Protocol — the spec and this README — is released under the [Apache License 2.0](LICENSE). Implement it freely, in any language.
