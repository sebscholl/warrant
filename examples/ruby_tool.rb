# frozen_string_literal: true

# transfer_funds — a guarded agent tool (Ruby)
# ============================================
#
# WHAT AN AGENT TOOL IS
# ---------------------
# An LLM agent cannot execute code; it only produces text. To let it act, you give it
# *tools*. A tool is four things:
#
#   - a NAME              -> "transfer_funds"
#   - a DESCRIPTION       -> natural language the model reads to decide WHEN to use it
#   - a PARAMETERS schema -> the typed arguments the model is allowed to fill in
#   - a FUNCTION (method) -> the code your runtime runs when the model picks the tool
#
# At run time the model emits a *tool call* — the name plus a JSON object of arguments:
#
#   { "name": "transfer_funds", "arguments": { "amount": 10000, "to": "acct_123" } }
#
# Your agent runtime parses that, calls the method below with those arguments, and feeds
# its RETURN VALUE back to the model as the tool result. The model reads that string and
# decides what to do next.
#
# So the agent controls exactly two things: WHICH tool, and the ARGUMENT VALUES.
# It never sees, edits, reorders, or skips the method body.
#
# WHY THE GUARD LIVES INSIDE THE METHOD
# -------------------------------------
# Because the body is unreachable to the agent, whatever you put there runs on EVERY
# invocation and cannot be bypassed — not by a confused model, not by a jailbroken one,
# not by prompt injection. Wrapping the sensitive call in `warrant.guard` makes the
# human-approval gate unbypassable: there is no path to the transfer that skips the guard.
#
# The agent can still change the arguments — but that only changes the action FINGERPRINT,
# producing a different approval request for a different action. An approval for one action
# can never be spent on another.
#
# (The opposite, broken design is a separate `request_approval` tool the agent must call
# first. Nothing forces the order, so the agent can just skip it.)
#
# NOTE: `Warrant`, `Payments`, and the framework here are illustrative — this shows the
# protocol's shape, not a published gem. See ../WARRANT.md.

warrant = Warrant::Client.new(api_key: ENV["WARRANT_API_KEY"])

# This schema is the ENTIRE surface the model can act on: a name, a description, and the
# argument shape. Notice what is NOT here — no "skip approval" flag, and no mention of
# Warrant. The gate is an implementation detail the model is unaware of.
TOOL_SCHEMA = {
  name: "transfer_funds",
  description: "Transfer money from the company account to a destination account.",
  parameters: {
    type: "object",
    properties: {
      amount: { type: "integer", description: "Amount to transfer, in dollars." },
      to:     { type: "string",  description: "Destination account id, e.g. acct_123." }
    },
    required: ["amount", "to"]
  }
}.freeze

# The method the runtime invokes with the model-supplied arguments.
# Everything inside this method is invisible and unreachable to the agent.
def transfer_funds(amount:, to:)
  # The action is what the committee signs. Its fingerprint binds the approval to THIS
  # exact transfer; params are strings so the hash is identical in every language (§4.1).
  action = { type: "transfer_funds", params: { amount: amount.to_s, to: } }

  # The block runs ONLY after a valid, matching proof is verified locally — i.e. only
  # after the committee approved this exact action. The agent cannot reach it.
  result = warrant.guard("cmte_finance_approvals", action:, message: "Transfer $#{amount} to #{to}.") do |grant|
    # grant.idempotency_key (the fingerprint) makes an accidental double-run a single
    # real transfer; thread it into whatever performs the side effect.
    Payments.transfer!(amount:, to:, idempotency_key: grant.idempotency_key)
  end

  # The return value goes back to the model as the tool result — plain text it acts on.
  case result
  when Warrant::Approved
    "Done — transferred $#{amount} to #{to}."
  when Warrant::Pending
    # Not decided yet. The model's natural next step — call this tool again with the SAME
    # arguments — IS the resume: same args -> same fingerprint -> same request.
    "Awaiting committee approval. The approvers have been notified. " \
      "Call this tool again with the same arguments in a few minutes."
  when Warrant::Denied
    "The committee rejected this transfer. Do not retry."
  end
end

# How a runtime dispatches a tool call (illustrative). Every framework reduces to this:
# look up the tool by name, call it with the model's arguments, return the result to the
# model. The agent never touches the method body above.
TOOLS = { "transfer_funds" => method(:transfer_funds) }.freeze

def handle_tool_call(name, arguments)
  TOOLS.fetch(name).call(**arguments.transform_keys(&:to_sym))
end
