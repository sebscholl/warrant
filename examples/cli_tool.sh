#!/usr/bin/env bash
#
# transfer_funds — a guarded agent tool (Shell / CLI)
# ===================================================
#
# WHAT AN AGENT TOOL IS (CLI edition)
# -----------------------------------
# An LLM agent cannot execute code; it only produces text. Some agent runtimes let the
# model act by running a *command* — a registered script is the "tool," the model supplies
# the arguments, the runtime executes it and feeds stdout + the exit code back to the model.
#
# This script IS that tool. The model controls only the arguments it passes (amount, to);
# it does not get to edit or skip the body below. So putting `warrant guard` here makes the
# approval gate unbypassable, exactly as in the Python/Ruby/TypeScript examples.
#
# WHY `warrant guard` WRAPS THE REAL COMMAND
# ------------------------------------------
# `warrant guard <committee> --type ... --param ... -- <real command>` does this:
#   1. computes the action fingerprint from --type + --param (the same content address the
#      committee signs),
#   2. opens or resumes the approval request for that fingerprint,
#   3. runs `<real command>` ONLY after a valid, matching proof verifies locally.
#
# The real side effect (./do_transfer.sh) is never reachable except through the guard.
# The agent can change --param values, but that just changes the fingerprint -> a different
# approval for a different action. An approval for one action can't be spent on another.
#
# HOW WAITING WORKS (resume == re-run)
# ------------------------------------
# The command does not block for minutes. It exits with a status the agent acts on, and
# the agent's natural retry — running the SAME command with the SAME args — is the resume,
# because the same args hash to the same fingerprint.
#
#   exit 0   approved and ran      -> stdout "Done."        (agent stops)
#   exit 75  pending (EX_TEMPFAIL) -> "awaiting approval"   (agent re-runs same args later)
#   exit 1   denied                -> "do not retry"        (agent stops)
#
# NOTE: `warrant` and ./do_transfer.sh are illustrative — this shows the protocol's shape,
# not a published CLI. See ../WARRANT.md.

set -euo pipefail

# The arguments the agent supplies. In a real harness these arrive as the tool-call's
# parameters; here they are positional for clarity.
amount="$1"   # e.g. 10000
to="$2"       # e.g. acct_123

# The guard wraps the real, sensitive command. `--param` values are stringified into the
# fingerprint (no raw numbers; see spec §4.1). Everything after `--` is the command that
# runs ONLY once the committee has approved this exact action.
warrant guard cmte_finance_approvals \
  --type  transfer_funds \
  --param "amount=${amount}" \
  --param "to=${to}" \
  --message "Transfer \$${amount} to ${to}." \
  -- ./do_transfer.sh "${amount}" "${to}"

# The exit code from `warrant guard` is what the agent reads:
#   - 0  -> ./do_transfer.sh ran (the SDK set WARRANT_IDEMPOTENCY_KEY for it); print "Done."
#   - 75 -> still pending; the agent should re-run this exact command shortly.
#   - 1  -> denied; the agent should not retry.
# `warrant guard` prints the matching human-readable status to stdout itself, so there is
# nothing more to do here — the same command, re-run, is the entire resume mechanism.
