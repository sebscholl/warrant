"""
transfer_funds — a guarded agent tool with NO SDK (Python, raw API)
===================================================================

Everything the other examples delegate to `warrant.guard(...)`, this file does by hand
against a compliant Warrant REST API. It is deliberately long: that length IS the point.

    There is no SDK requirement. An SDK is pure convenience over a compliant API —
    it computes the fingerprint, opens/resumes the request, and re-validates the proof
    for you. You can do all of it yourself, in any language with HTTP + SHA-256 +
    Ed25519, and interoperate with the exact same platform.

This is still the same agent tool as the others (see ./README.md for what an agent tool
is, and why the guard logic must live INSIDE this function where the agent cannot reach,
skip, or edit it). The only difference is that the body talks to the API directly.

The client's non-negotiable job is **local re-validation** (spec §6.7): never trust the
platform's `status` flag or its returned `action_fingerprint`. Recompute and re-verify
everything yourself before performing the side effect.

NOTE: `requests`, `Payments`, and the base URL are illustrative. `hashlib`, `base64`, and
`cryptography` are real. See ../WARRANT.md for the normative byte-strings and flow.
"""

import base64
import hashlib
import json
import os
from datetime import datetime, timezone

import requests  # illustrative HTTP client
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PublicKey

BASE_URL = "https://api.warrant.example/v1"
COMMITTEE = "cmte_finance_approvals"
FP_VERSION = "fp-jcs-strings-v1"
MAX_PROOF_AGE_SECONDS = 15 * 60  # our freshness policy (§6.7); a client choice, not the platform's

AUTH = {"Authorization": f"Bearer {os.environ['WARRANT_API_KEY']}"}

# The three replies the model can get back — short instructions it will act on.
APPROVED = "Done — the transfer completed."
PENDING = "Awaiting committee approval. Call this tool again with the same arguments shortly."
DENIED = "The committee rejected this transfer. Do not retry."


class ProofError(Exception):
    """Raised when local re-validation fails. We then MUST NOT execute the action."""


# --- Canonical byte-strings (spec §4) ---------------------------------------------------

def jcs(obj) -> str:
    """RFC 8785 (JCS) canonicalization for our domain.

    The Warrant byte-strings only ever contain strings, booleans, and null (no raw numbers,
    §4.1), so a key-sorted, whitespace-free dump is byte-identical to full JCS here. A
    production client MAY use a vetted RFC 8785 library; for these payloads it is equivalent.
    """
    return json.dumps(obj, sort_keys=True, separators=(",", ":"), ensure_ascii=False)


def fingerprint(committee: str, action_type: str, params: dict) -> str:
    """The action fingerprint — `fp-jcs-strings-v1` (spec §4.1). The content address the
    committee signs, and our idempotency key. WE compute it; we never trust the server's."""
    canonical = jcs({"version": FP_VERSION, "committee": committee, "type": action_type, "params": params})
    return "sha256:" + hashlib.sha256(canonical.encode("utf-8")).hexdigest()


def _parse_rfc3339(ts: str) -> datetime:
    return datetime.fromisoformat(ts.replace("Z", "+00:00"))


# --- Local re-validation (spec §6.7) — the zero-trust property ---------------------------

def verify_proof(proof: dict, committee_keys: dict, expected_fingerprint: str) -> None:
    """Re-derive the verdict from the signed decisions, WITHOUT trusting the platform.

    Raises ProofError if anything fails to check out — in which case the caller MUST NOT
    run the side effect. Mirrors the numbered steps in spec §6.7.
    """
    # Step 1: resolve the member key set + threshold (live config here; a zero-trust client
    # would instead verify against its own PINNED copy — spec §9).
    threshold = committee_keys["threshold"]
    pubkey_to_member = {
        key["public_key"]: member["id"]
        for member in committee_keys["members"]
        for key in member["keys"]
    }

    # Step 3: the binding step. Recompute the fingerprint of the action we are ABOUT TO RUN
    # and confirm it equals the proof's. This is what stops "approve $10, execute $10M".
    if proof["action_fingerprint"] != expected_fingerprint:
        raise ProofError("fingerprint mismatch: the approved action is not the one about to execute")

    # Step 2 + 4: verify each approve signature and count DISTINCT members.
    approving_members: set[str] = set()
    latest_signed_at: datetime | None = None

    for decision in proof["decisions"]:
        if decision["vote"] != "approve":
            continue

        member = pubkey_to_member.get(decision["public_key"])
        if member is None:
            continue  # signer is not a current committee member -> ignore this decision

        # Reconstruct the exact sig-jcs-v1 payload (spec §4.2): the constant `v`, plus
        # committee / request / fingerprint / fingerprint_version FROM THE PROOF ENVELOPE,
        # and vote / signed_at from the decision itself.
        payload = {
            "v": "sig-jcs-v1",
            "committee": proof["committee"],
            "request": proof["request"],
            "vote": decision["vote"],
            "signed_at": decision["signed_at"],
            "fingerprint": proof["action_fingerprint"],
            "fingerprint_version": proof["fingerprint_version"],
        }
        digest = hashlib.sha256(jcs(payload).encode("utf-8")).digest()

        # Plain Ed25519 over the 32-byte digest (spec §4.2, "what gets signed").
        public_key = Ed25519PublicKey.from_public_bytes(base64.b64decode(decision["public_key"]))
        try:
            public_key.verify(base64.b64decode(decision["signature"]), digest)
        except Exception:
            continue  # signature does not verify -> ignore this decision

        approving_members.add(member)  # at most one per distinct member id (a member may hold several keys)
        signed_at = _parse_rfc3339(decision["signed_at"])
        latest_signed_at = signed_at if latest_signed_at is None else max(latest_signed_at, signed_at)

    if len(approving_members) < threshold["approve"]:
        raise ProofError("not enough valid approvals from distinct members to meet the threshold")

    # Step 5: freshness — a client policy, not a platform guarantee. Anchor on the LATEST
    # signature (when the approval completed under first-to-threshold-wins).
    if latest_signed_at is not None:
        age = (datetime.now(timezone.utc) - latest_signed_at).total_seconds()
        if age > MAX_PROOF_AGE_SECONDS:
            raise ProofError("approval is stale; acknowledge it and request a fresh one")


# --- The tool ---------------------------------------------------------------------------

def transfer_funds(amount: int, to: str) -> str:
    """Same tool, no SDK. The agent supplies amount/to; this body is unreachable to it."""
    action = {"type": "transfer_funds", "params": {"amount": str(amount), "to": to}}

    # We compute the fingerprint ourselves and use it as the idempotency key. We will also
    # use it to re-bind the proof to this exact action before executing.
    fp = fingerprint(COMMITTEE, action["type"], action["params"])

    # POST is find-or-create-or-resume (spec §6.1): the platform derives the dedup key from
    # `action`, so the SAME action always lands on the SAME request. No request id to carry.
    created = requests.post(
        f"{BASE_URL}/approval-requests",
        headers=AUTH,
        json={"committee": COMMITTEE, "action": action, "message": f"Transfer ${amount} to {to}."},
    ).json()

    status = created["status"]

    if status == "denied":
        return DENIED
    if status != "approved":
        # pending — or a brand-new pending the POST just opened because the prior request
        # had expired/been canceled. Either way the agent should retry the same call later.
        return PENDING

    # status == "approved": re-validate locally BEFORE doing anything irreversible (§6.7).
    proof = created["proof"]
    committee_keys = requests.get(f"{BASE_URL}/committees/{COMMITTEE}/keys", headers=AUTH).json()
    verify_proof(proof, committee_keys, expected_fingerprint=fp)  # raises -> we never execute

    # Only now, with a verified, action-bound proof in hand, perform the side effect — and
    # thread the fingerprint as the downstream idempotency key so a retry can't double-spend.
    Payments.transfer(amount=amount, to=to, idempotency_key=fp)

    # Mark the request spent so a future identical action opens a fresh approval (§6.5).
    requests.post(f"{BASE_URL}/approval-requests/{created['id']}/acknowledge", headers=AUTH, json={})

    return APPROVED
