# Examples — Warrant inside agent tools

Heavily-commented examples of using a Warrant SDK **inside an agent tool**, in several languages. They illustrate the protocol — there is no published `warrant` package yet (see the [specification](../WARRANT.md)). Every file is the *same* guarded `transfer_funds` action from the spec, written idiomatically per language.

If you read one thing, read this section.

## What is an agent tool?

This pattern is new, so it's worth stating precisely.

An LLM agent **cannot run code** — it produces text. To let it *act*, you give it **tools**. A tool is four things:

1. a **name** (e.g. `transfer_funds`),
2. a **description** — natural language the model reads to decide *when* to use it,
3. a **parameters schema** — the typed arguments the model is allowed to fill in, and
4. a **function** — the code your runtime runs when the model picks the tool.

During a run, the model emits a **tool call**: the tool's name plus a JSON object of arguments —

```json
{ "name": "transfer_funds", "arguments": { "amount": 10000, "to": "acct_123" } }
```

Your agent runtime (LangGraph, the OpenAI/Anthropic SDKs, the Vercel AI SDK, or your own loop) parses that, **calls your function with those arguments**, and feeds the function's **return value** back to the model as the tool result. The model reads it and continues.

So the agent controls exactly two things: **which tool**, and **the argument values**. It never sees, edits, reorders, or skips your function's body.

## Why the guard goes *inside* the function

Because the function body is unreachable to the agent, anything you put there **runs on every invocation and cannot be bypassed** — not by a confused model, not by a jailbroken one, not by prompt injection. Putting `warrant.guard(...)` around the sensitive operation makes the human-approval gate **unbypassable**:

- There is **no code path** to the transfer that doesn't pass through the guard.
- The agent can change the **arguments**, but that only changes the action **fingerprint** — producing a *different* approval request for a *different* action. An approval for "transfer $10" can never be spent on "transfer $10,000,000" ([spec §3.2](../WARRANT.md)).

Contrast the **broken** alternative — exposing approval as a *separate* tool the agent must call first:

```text
# BROKEN: two tools, and nothing forces the order.
request_approval(...)   # the agent can simply… not call this,
transfer_funds(...)     # …and call this directly.
```

A confused or adversarial agent just skips the first call. Guard-inside-the-tool removes that possibility: the approval *is* part of the operation, not a step the model is trusted to remember.

## How "waiting for humans" works without blocking

Approval can take minutes or hours, but the tool never blocks:

1. **First call** — no approval yet, so the guard opens a request, the platform notifies the humans, and the tool returns something like *"awaiting approval — call again with the same arguments shortly."*
2. The model does the natural thing: it **calls the tool again with the same arguments**.
3. Same arguments → **same fingerprint** → the SDK finds the existing request. Once approved, the guard verifies the proof locally and runs the operation.

The agent's ordinary retry behavior *is* the resume — no request IDs, no state to thread ([spec §3.3](../WARRANT.md)).

## The files

| File | Language | Notes |
|---|---|---|
| [`python_tool.py`](python_tool.py) | Python | Function-calling style with the tool schema the model sees |
| [`typescript_tool.ts`](typescript_tool.ts) | TypeScript | Same, with a typed tool definition |
| [`ruby_tool.rb`](ruby_tool.rb) | Ruby | Block-style guard, matching the spec's primary example |
| [`rust_tool.rs`](rust_tool.rs) | Rust | Closure-based guard; client passed in explicitly |
| [`csharp_tool.cs`](csharp_tool.cs) | C# | Semantic-Kernel-style attributes that *are* the tool schema |
| [`cli_tool.sh`](cli_tool.sh) | Shell / CLI | Wrap any command as a guarded tool; "resume" is just re-running it |
| [`raw_api_ruby.rb`](raw_api_ruby.rb) | Ruby (no SDK) | The same tool against the raw REST API — fingerprinting and full proof re-validation by hand, stdlib only |

Each restates the two points above in its own comments: **a tool is a function the agent calls with params**, and **the guard lives inside it so it always runs.**

[`raw_api_ruby.rb`](raw_api_ruby.rb) goes one further and uses **no SDK at all** — with only the Ruby standard library it computes the fingerprint and performs the complete [§6.7](../WARRANT.md) proof re-validation (signatures, fingerprint match, distinct-member threshold, freshness) by hand. It's long on purpose: it shows that an SDK is only a convenience over a compliant API, not a requirement.
