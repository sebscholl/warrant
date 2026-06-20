"""
transfer_funds — a guarded agent tool (Python)
===============================================

WHAT AN AGENT TOOL IS
---------------------
An LLM agent cannot execute code; it only produces text. To let it act, you give it
*tools*. A tool is:

    - a NAME            -> "transfer_funds"
    - a DESCRIPTION     -> natural language the model reads to decide WHEN to use it
    - a PARAMETERS schema -> the typed arguments the model is allowed to fill in
    - a FUNCTION        -> the code your runtime runs when the model picks the tool

At run time the model emits a *tool call* — the name plus a JSON object of arguments:

    {"name": "transfer_funds", "arguments": {"amount": 10000, "to": "acct_123"}}

Your agent runtime parses that, calls the function below with those arguments, and feeds
the function's RETURN VALUE back to the model as the tool result. The model reads that
string and decides what to do next.

So the agent controls exactly two things: WHICH tool, and the ARGUMENT VALUES.
It never sees, edits, reorders, or skips the function body.

WHY THE GUARD LIVES INSIDE THE FUNCTION
---------------------------------------
Because the body is unreachable to the agent, whatever you put there runs on EVERY
invocation and cannot be bypassed — not by a confused model, not by a jailbroken one,
not by prompt injection. Wrapping the sensitive call in `warrant.guard(...)` therefore
makes the human-approval gate unbypassable: there is no path to the transfer that does
not pass through the guard.

The agent can still change the arguments — but that only changes the action FINGERPRINT,
producing a different approval request for a different action. An approval for one action
can never be spent on another.

(The opposite, broken design is a separate `request_approval` tool the agent must call
first. Nothing forces the order, so the agent can just skip it. Guard-inside-the-tool
removes that possibility.)

NOTE: `warrant`, `payments`, and the agent framework here are illustrative — this file
shows the protocol's shape, not a published package. See ../WARRANT.md.
"""

import os
from warrant import Client, Approved, Pending, Denied  # illustrative SDK

warrant = Client(api_key=os.environ["WARRANT_API_KEY"])


# This schema is the ENTIRE surface the model can act on: a name, a description, and the
# argument shape. Notice what is NOT here — there is no "skip approval" flag, and no
# mention of Warrant at all. The gate is an implementation detail the model is unaware of.
TOOL_SCHEMA = {
    "name": "transfer_funds",
    "description": "Transfer money from the company account to a destination account.",
    "parameters": {
        "type": "object",
        "properties": {
            "amount": {"type": "integer", "description": "Amount to transfer, in dollars."},
            "to": {"type": "string", "description": "Destination account id, e.g. acct_123."},
        },
        "required": ["amount", "to"],
    },
}


def transfer_funds(amount: int, to: str) -> str:
    """The function the runtime invokes with the model-supplied arguments.

    Everything inside this function is invisible and unreachable to the agent.
    """
    # The ACTION is the data the committee signs. Its fingerprint binds the approval to
    # THIS exact transfer. params are strings so the hash is identical in every language
    # (see spec §4.1 — no raw numbers).
    action = {
        "type": "transfer_funds",
        "params": {"amount": str(amount), "to": to},
    }

    # The sensitive operation. `guard` calls this back ONLY after a valid, matching proof
    # has been verified locally — i.e. only after the committee approved this exact action.
    # It is the Python equivalent of the "block" in the Ruby example.
    def execute(grant):
        # `grant.idempotency_key` (the action fingerprint) makes an accidental double-run
        # a single real transfer; thread it into whatever performs the side effect.
        return payments.transfer(amount=amount, to=to, idempotency_key=grant.idempotency_key)

    result = warrant.guard(
        "cmte_finance_approvals",            # which committee must approve
        action,                              # what they're approving (fingerprinted)
        message=f"Transfer ${amount} to {to}.",   # human-readable context; NOT fingerprinted
        on_grant=execute,                    # runs only after approval
    )

    # The return value goes back to the model as the tool result — plain text it acts on.
    match result:
        case Approved():
            return f"Done — transferred ${amount} to {to}."
        case Pending():
            # Not decided yet. The model's natural next step — call this tool again with
            # the SAME arguments — IS the resume: same args -> same fingerprint -> same
            # request. So we just tell it to retry.
            return (
                "Awaiting committee approval. The approvers have been notified. "
                "Call this tool again with the same arguments in a few minutes."
            )
        case Denied():
            return "The committee rejected this transfer. Do not retry."


# ---------------------------------------------------------------------------
# How a runtime dispatches a tool call (illustrative). Every framework reduces
# to this: look up the function by name, call it with the model's arguments,
# return the result to the model. The agent never touches the body above.
# ---------------------------------------------------------------------------
TOOLS = {"transfer_funds": transfer_funds}

def handle_tool_call(name: str, arguments: dict) -> str:
    return TOOLS[name](**arguments)
