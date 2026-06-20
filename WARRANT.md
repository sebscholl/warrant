# The Warrant Protocol

**Version:** `warrant/1.0` · **Status:** Released · 2026-06-20 · **License:** [Apache-2.0](LICENSE)

A **warrant** is a signed authorization bound to one specific action. The Warrant Protocol lets a developer gate a chosen agent action behind a configurable group of humans — a **committee** — who must reach a defined consensus before the action may execute. Each approval is **cryptographically signed** and **bound to the exact action** (an action fingerprint), and the resulting **proof** is verifiable by the developer's own code, independent of the platform's say-so. A prompt-injected or jailbroken agent cannot fabricate a warrant, and a warrant for one action cannot be spent on another.

---

## 1. Introduction

Agentic systems guard destructive actions with prompt engineering — "only delete if the user explicitly confirms." That is not security; it is a speed bump. Prompt injection, jailbreaks, model quirks, or a cleverly framed request bypass it. The blast radius of an autonomous agent deleting records, sending mass communications, pushing to production, or wiring money is real and irreversible.

> **A prompt is an inconvenience. It is not a security boundary.**

Every major agent framework has *some* human-in-the-loop (LangGraph `interrupt()`, CrewAI `human_input`, OpenAI Agents SDK `needs_approval`, MCP proxy allow/reject, AutoGen conversational confirmation), but none treats **multi-party cryptographic approval** as a first-class primitive with a verifiable, action-bound proof that can be asynchronously obtained by the agent.

The Warrant Protocol fills that gap. It defines:

- a small **`guard` primitive** for client code (declared action **data** + a **block** of code that runs only against a matching warrant);
- a **REST wire protocol** for creating approval requests, casting signed decisions, and retrieving proofs;
- three **canonical byte-strings** (fingerprint, decision payload, webhook signature) that independent implementations reproduce byte-for-byte; and
- **conformance requirements** that pin down exactly what a compliant *platform* and a compliant *client* must do — most importantly, that the **client re-validates the proof locally**.

The protocol is the contract. Any platform and any SDK in any language interoperate as long as both satisfy §10.

---

## 2. Conventions & Terminology

### 2.1 Requirement levels

The key words **MUST**, **MUST NOT**, **SHOULD**, **SHOULD NOT**, and **MAY** are to be interpreted as described in [RFC 2119].

### 2.2 Actors

1. **Client** — the developer's server, agent, or CLI. Creates approval requests and **verifies proofs before executing guarded code**. Holds an API key.
2. **Committee Member** — a human approver. Reviews an action and casts a signed decision, usually through the platform's hosted signing session.
3. **Platform** — orchestrates notification, threshold evaluation, proof assembly, and webhook delivery. It **never executes the guarded action**; it only gates it.

### 2.3 Glossary

- **Committee** — a named group of members (e.g. `cmte_finance_approvals`) with threshold rules. Referenced from client code only by its identifier.
- **Action** — declared data `{ type, params }` describing what will run. Hashed into the fingerprint; never the code itself.
- **Action fingerprint** — a hash of the action (§4.1) that always comes out the same for the same action. Binds approval to exactly one action, and doubles as the **idempotency key** — a stable id that marks a repeat as the *same* call.
- **Approval request** — one record per guarded-action attempt (`areq_…`).
- **Decision** — a member's signed vote (`approve` / `reject`) on a request.
- **Proof** — the bundle of signed decisions that produced a terminal outcome; the executable *warrant*. Derived, not a bearer secret.
- **Threshold** — independent **approval** and **rejection** vote counts.
- **Response window** — the only platform-managed clock: how long a request stays open before it auto-`expires`.
- **Acknowledgement** — a caller-driven flag marking a decided request "spent," freeing its fingerprint for a future identical action.

---

## 3. Core Concepts

### 3.1 The guard primitive

A client passes two **separable** things: a declared **action** (data) and a **block** (code). The block MUST NOT execute until the committee has produced a valid proof for *that exact action*.

- The **action** is hashed into the fingerprint the committee signs. Its `params` leaves are strings (or booleans/null — never raw numbers, see §4.1) so hashing is identical across languages.
- The **block** is the code. It is **never sent to the platform** and runs only against a proof whose fingerprint matches the action about to run.

### 3.2 Bind the signature to the action

**The signature is bound to the action, not just to "yes."** A human approval is worthless unless bound to *exactly* what executes — otherwise approval for "transfer $10" is spent on "transfer $10M" and the committee is theater. So every request carries an **action fingerprint** (§4.1), and members sign a payload that **includes that fingerprint** (§4.2).

**The dual risk.** Binding the signature to `params` is only half the job. The member must approve based on the **same `params` that are fingerprinted** — not on free-text the client controls independently. A signing surface **MUST** render a faithful, structured view of the fingerprinted `params` as the primary decision surface; `message`/`context` are supplementary narration, never a substitute.

### 3.3 Content-addressed, stateless resume

The fingerprint is a pure function of `{ version, committee, type, params }` — the same action always hashes to the same key, in any process, after any crash. So the client carries **no `request_id` and no token** across the async gap. To resume, it **re-invokes the same action**; `POST /approval-requests` is a complete **find-or-create-or-resume** (§6.1). This lets most integrations run with **zero developer-maintained storage**.

Exactly-once execution belongs to the system performing the side effect, not the approval. The SDK yields the fingerprint as a `grant.idempotency_key` to be threaded into the downstream call, which dedupes it (§12).

### 3.4 A proof is a warrant, not a bearer capability

A leaked proof does not let an attacker *do* anything: execution lives in the client's code (which the platform never sees), and the fingerprint binds the proof to one action. A proof in a log is an audit artifact, not a breach. Protect the **client's execution path** and (in V2) the **signing keys** — not the proof bytes (though acknowledge promptly: an unacknowledged held approval keeps authorizing retries, §6.5).

### 3.5 The server offers; the client enforces

The platform can only *offer* material; the client *enforces* the guarantee.

| Property | Provided by | Enforced by |
|---|---|---|
| Real signatures exist over the action | Platform (collects votes) | **Client** (re-verifies sigs) |
| Approved action == executed action | — | **Client** (recompute fingerprint, compare) |
| Approval is fresh enough to act on | Platform (signed `signed_at`) | **Client** (freshness policy) or committee (`valid_until` in params) |
| Who is on the committee / threshold | **Platform** (live config) | Client *only if* it pins (V2+) |
| Action runs at most once | — | **Client** (downstream idempotency key) |
| Member identity / authentication | **Platform** | Platform |

Everything the client doesn't independently check is, ultimately, platform trust. A conformant SDK makes the client-enforced column the **default, lowest-effort path**.

---

## 4. Canonical Byte-Strings (normative)

Every byte-string that is hashed or signed MUST be reproducible **byte-identically by an independent party in another language**. A one-byte divergence makes verification silently fail. There are exactly three. Each is **versioned** and **MUST ship conformance test vectors** before production (§10.4, Appendix C).

| # | String | Scheme | Produced by | Verified by |
|---|---|---|---|---|
| 1 | Action fingerprint | `fp-jcs-strings-v1` | platform + client (independently) | client |
| 2 | Decision signing payload | `sig-jcs-v1` | member key (platform-held in V1, device in V2) | client |
| 3 | Webhook signature | `v1` | platform webhook secret | client |

### 4.1 Action fingerprint — `fp-jcs-strings-v1`

```rb
fingerprint = "sha256:" + lowercase_hex(
  SHA256(
    JCS({ version, committee, type, params })
  )
)
```

- **JCS** is [RFC 8785] (JSON Canonicalization Scheme): object keys sorted by UTF-16 code unit, no inter-token whitespace, ECMA-262 string escaping. Implementations MUST NOT invent their own canonicalization.
- `version` MUST be the literal `"fp-jcs-strings-v1"` and is part of the hashed input.
- `params` leaf values MUST be **strings, booleans, or null** — **never raw numbers**. (JCS's one cross-language weak spot is float serialization; forbidding numbers removes the entire risk class.) A platform **MUST reject** a create request whose `params` contain a raw number. Money is `"10000"` or `{ "value": "10000", "currency": "USD" }`.
- `message`/`context` are **never** part of the fingerprint.

**Reference vectors** (normative — a conformant implementation MUST reproduce each `canonical` string and `fingerprint` below, byte for byte):

*Flat string params:*

```json
{
  "version": "fp-jcs-strings-v1",
  "committee": "cmte_finance_approvals",
  "type": "transfer_funds",
  "params": {
    "amount": "10000",
    "to": "acct_123"
  }
}
```

```text
{"committee":"cmte_finance_approvals","params":{"amount":"10000","to":"acct_123"},"type":"transfer_funds","version":"fp-jcs-strings-v1"}
→ sha256:e0320dce244b9576a54a12f7507c7930ca858439668e91e8793cdcb313ef5c35
```

*Nested object, boolean, and null — keys sorted at every level:*

```json
{
  "version": "fp-jcs-strings-v1",
  "committee": "cmte_finance_approvals",
  "type": "transfer_funds",
  "params": {
    "amount": {
      "value": "10000",
      "currency": "USD"
    },
    "urgent": true,
    "memo": null
  }
}
```

```text
{"committee":"cmte_finance_approvals","params":{"amount":{"currency":"USD","value":"10000"},"memo":null,"urgent":true},"type":"transfer_funds","version":"fp-jcs-strings-v1"}
→ sha256:21db0f9a78ca91df90704add4f4d862e4eb4a929cd2f47482af135ca01d46e67
```

*String escaping: quote, backslash, control char; an astral emoji stays literal UTF-8:*

```json
{
  "version": "fp-jcs-strings-v1",
  "committee": "cmte_finance_approvals",
  "type": "note",
  "params": {
    "note": "a\"b\\c\nd\te\u0001f😀"
  }
}
```

```text
{"committee":"cmte_finance_approvals","params":{"note":"a\"b\\c\nd\te\u0001f😀"},"type":"note","version":"fp-jcs-strings-v1"}
→ sha256:5c2518c6187c0184a02dda0eccc949a52e4cfbd5917a8c6ad36a833ee62e7679
```

### 4.2 Decision signing payload — `sig-jcs-v1`

```rb
signing_payload = SHA256(
  JCS({
    "v":                   "sig-jcs-v1",
    "committee":           "cmte_finance_approvals",
    "request":             "areq_8f3a",
    "vote":                "approve",          // or "reject"
    "signed_at":           "2026-06-16T18:05:00Z",
    "fingerprint":         "sha256:e0320dce244b9576a54a12f7507c7930ca858439668e91e8793cdcb313ef5c35",
    "fingerprint_version": "fp-jcs-strings-v1"
  })
)

signature = sign(member_private_key, signing_payload)
```

- `fingerprint` ties the vote to the exact action; `request` pins it to this request; `signed_at` anchors freshness.
- The payload does **not** name the signing key — there is no `key_id`. The signature inherently commits to the keypair; *which* key signed is whatever public key verifies it, attributed to a member via the committee's member→key map (§6.8).
- **What gets signed:** `sign`/`verify` operate over the raw 32-byte SHA-256 digest above — for `ed25519`, plain EdDSA over those 32 bytes (not Ed25519ph). Signer and verifier MUST agree on this exactly, or every signature silently fails.
- `public_key` and `signature` are **base64** ([RFC 4648] §4 standard alphabet, padded).

**Reference vector.** Reproducible end to end. The key below is a **published test key — never use it in production.** Signing is plain Ed25519 over the 32-byte SHA-256 digest (see "What gets signed," above).

```text
# Member signing key (Ed25519). The seed is published only so this vector is reproducible.
private key seed (hex):  0102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f20
public_key (base64):     ebVWLo/mVPlAeLES6KmLp5AfhTrmlb7X4OORC60ElmQ=

# 1. JCS-canonicalize the decision payload (keys sorted, no whitespace):
{"committee":"cmte_finance_approvals","fingerprint":"sha256:e0320dce244b9576a54a12f7507c7930ca858439668e91e8793cdcb313ef5c35","fingerprint_version":"fp-jcs-strings-v1","request":"areq_8f3a","signed_at":"2026-06-16T18:05:00Z","v":"sig-jcs-v1","vote":"approve"}

# 2. SHA-256 of that canonical string = the exact 32 bytes that get signed (hex):
8f5ca50a7ed139784441f8e9cf97c3d5d00745c0d8098096d9b00058ade28af2

# 3. Ed25519 signature over those 32 bytes, base64 — this is the decision's `signature`:
mU3iRTXUyfeeU3f9ErxucYFxZFA+mQhPNiYoRYVkKx+fWtfciSxDc1UEtVc8QbHAvwlnRZXKYOlaVDgsVWIPBA==
```

A verifier reconstructs steps 1–2 from the decision's own fields and checks the signature against `public_key`. The `fingerprint` here is the §4.1 flat-params vector, so the two examples chain into one verifiable approval.

### 4.3 Webhook signature — `v1`

```rb
signed_payload = "<t>" + "." + <raw_request_body_bytes>

v1             = lowercase_hex( 
  HMAC-SHA256(endpoint_secret, signed_payload) 
)

header         = "X-Warrant-Signature: t=<unix_seconds>,v1=<hex>"
```

The client recomputes `v1` over the **raw** body (not a re-serialized copy), constant-time-compares, then rejects if `t` is outside a small tolerance (e.g. ±5 min) to bound replay. This authenticates *delivery* only; it is **not** a substitute for re-validating the proof (§6.7).

**Reference vector.** The HMAC covers the **raw received bytes**, never a re-serialized copy.

```text
# Inputs:
endpoint_secret:  whsec_0123456789abcdef0123456789abcdef
t (unix seconds): 1781633191
raw request body: {"event":"approval_request.approved","data":{"id":"areq_8f3a","status":"approved"}}

# 1. signed_payload = t + "." + raw_body:
1781633191.{"event":"approval_request.approved","data":{"id":"areq_8f3a","status":"approved"}}

# 2. v1 = lowercase_hex(HMAC-SHA256(endpoint_secret, signed_payload)):
4eaa8f19eee8a035b64eb9521ff6650249e38bd9a1b24e96273b8edb16881ae7

# Delivered header:
X-Warrant-Signature: t=1781633191,v1=4eaa8f19eee8a035b64eb9521ff6650249e38bd9a1b24e96273b8edb16881ae7
```

### 4.4 Shared JCS rules (#1, #2)

RFC 8785 canonicalization; keys sorted per JCS; **no raw numbers** (all leaves are strings/booleans/null); timestamps are RFC 3339, UTC, whole seconds, trailing `Z`; the `sha256:`-prefixed fingerprint is lowercase hex.

### 4.5 Intentionally NOT signed

- **The proof container** (§6.7) — an unsigned bundle of individually-signed decisions; the client re-derives the verdict from the decisions.
- **The committee configuration** (§8) — its members, keys, and threshold, platform-governed and signed by no one. This is the documented V1 trust boundary (§9); client-side pinning is the V2 fix.

---

## 5. Resources

| Resource | Purpose |
|---|---|
| `approval-requests` | The core object. One per guarded-action attempt. |
| `decisions` | A member's signed vote on a request. |
| `committees` | Read-only from the client's view. Exposes member public keys for offline verification. |
| `webhooks` | Delivery of terminal-state events to the client. |

All client-facing endpoints are authenticated with `Authorization: Bearer <api_key>` unless noted. The base path is `/v1`. An API key is scoped to one or more committees; creating, cancelling, or acknowledging a request is authorized only if the key is scoped to that request's committee.

---

## 6. Wire Protocol

### 6.1 Create (find-or-create-or-resume)

```
POST /approval-requests
Authorization: Bearer <api_key>

{ 
  "committee": "cmte_finance_approvals",
  "action":  { 
    "type": "transfer_funds", 
    "params": { 
      "amount": "10000", 
      "to": "acct_123" 
    } 
  },
  "message": "Pay vendor invoice #4471 — $10,000 to acct_123.",
  "context": [{ 
    "role": "user", 
    "content": "Pay all outstanding vendor invoices." 
  }],
  "response_window": 3600 
}
```

- There is **no `Idempotency-Key` header**; the platform derives the dedup key by computing the fingerprint from `action` server-side. A client that wants a distinct request for an otherwise-identical action puts a distinguishing value in `params`.
- The platform MUST compute and store the fingerprint, but the client MUST recompute it independently at verification time (§6.7) and MUST NOT trust the returned `action_fingerprint`.
- `response_window` is the seconds the request stays open; if omitted, the committee's configured default applies. It is surfaced as an absolute `response_expires_at`.

**Response** `201 Created`:

```json
{ 
  "id": "areq_8f3a", 
  "status": "pending",
  "committee": "cmte_finance_approvals",
  "action_fingerprint": "sha256:e0320dce244b9576a54a12f7507c7930ca858439668e91e8793cdcb313ef5c35",
  "fingerprint_version": "fp-jcs-strings-v1",
  "threshold": { 
    "type": "m_of_n",
    "n": 3, 
    "approve": 2, 
    "reject": 2 
  },
  "decisions_count": { 
    "approve": 0, 
    "reject": 0 
  },
  "signing_url": "https://app.example.com/s/areq_8f3a",
  "created_at": "2026-06-16T18:00:00Z", 
  "response_expires_at": "2026-06-16T19:00:00Z" 
}
```

`decisions_count` reports running tallies (counts only, never who voted which way); per-member votes appear only in the final proof.

**Idempotency resolution (state-driven, no clocks).** The fingerprint is a content address, so `POST` is find-or-create-or-resume:

| Existing request for this fingerprint | `POST` resolves to |
|---|---|
| `pending` | that request (resume the wait) |
| `approved`, not acknowledged | that request **+ proof** (resume to execute) |
| `approved`, acknowledged | **create a new** `pending` |
| `denied`, not acknowledged | that request **+ proof** (caller learns the denial) |
| `denied`, acknowledged | **create a new** `pending` |
| only `expired` / `canceled` (nothing live) | **create a new** `pending` |

`pending`, unacknowledged `approved`, and unacknowledged `denied` **hold** the fingerprint; acknowledging (§6.5), or an `expired`/`canceled` outcome, frees it. A platform MUST keep at most one *held* request per `(committee, fingerprint)`. Create-new rows return `201 Created`; resume rows return `200 OK` (same request, no re-notification), so the client can distinguish a new request from a resumed one. Composition is **live**, not snapshotted (§8).

### 6.2 Poll

```
GET /approval-requests/areq_8f3a
```

Returns current state; when terminal, the body includes the **proof** (§6.7). Polling is the universal fallback for clients that can't receive webhooks. `status` is one of `pending` (non-terminal) → `approved | denied | expired | canceled` (terminal, final).

### 6.3 List (recovery)

```
GET /approval-requests?status=pending&committee=cmte_finance_approvals
```

For reconciliation after client state loss. Filterable by `status`, `committee`, and creation time; paginated. With content-addressing this is rarely needed (the client just re-issues the action) but remains useful for human dashboards and cancelling abandoned requests.

### 6.4 Cancel

```
POST /approval-requests/areq_8f3a/cancel
```

Withdraws a pending request ("actually, don't send that payment"). It transitions to terminal `canceled` (distinct from `expired`); **MUST succeed only while `pending`** — if already terminal it MUST return `409` with the current state (cancellation can never undo an approval). No proof is issued. Any valid API key for the committee MAY cancel. (Members do not cancel; a member who objects casts a `reject` vote.)

### 6.5 Acknowledge

```
POST /approval-requests/areq_8f3a/acknowledge
→ 200 { 
  "id": "areq_8f3a", 
  "status": "approved", 
  "acknowledged": true 
}
```

Marks a held request **spent** so its fingerprint frees up; the next identical `POST` then creates a fresh `pending`. Properties: optional and caller-driven (the platform MUST NOT auto-acknowledge); sets a flag, not a status (`status` stays `approved` / `denied` for audit); idempotent; works on `approved` or `denied`; any valid API key for the committee MAY acknowledge. Acknowledge is **not** an exactly-once mechanism — it frees a fingerprint for *future* reuse, it does not gate *this* execution (§12).

### 6.6 Cast a decision (member side)

Driven by the hosted signing session: the member authenticates to the platform, reviews the **rendered `params`** + context, and submits a vote. They do **not** handle a key.

```
POST /approval-requests/areq_8f3a/decisions
Authorization: Bearer <member_session_token>

{ 
  "vote": "approve", 
  "comment": "Verified against PO #4471." 
}
```

**V1 — platform-custodied keys.** The platform generates and holds a signing keypair per member and signs the `sig-jcs-v1` payload (§4.2) on their behalf; the member's authenticated session *is* their authorization to sign.

**V2 — self-custodied keys (additive).** The member's device constructs and signs the payload locally and submits the signature:

```json
{ 
  "vote": "approve", 
  "alg": "ed25519", 
  "public_key": "base64…",
  "signature": "base64(sign(member_privkey, signing_payload))", "comment": "…"
}
```

Same proof shape, same verification path; only *who holds the private key* moves. A committee MAY be all-custodied, all-self-custodied, or mixed. The device sets its own `signed_at` (stored as-is, since the signature covers it) and takes the `request` id and `committee` from the signing session it was handed.

> **Hard V2 constraint:** the signing device MUST itself render the `params` and itself compute the fingerprint from exactly those rendered params; it MUST NEVER sign a fingerprint the platform hands it. Otherwise the dual-risk hole (§3.2) moves down a layer. This implies raw `params` reach each member's device in V2.

**Vote & threshold semantics.**

- **One vote per member, immutable.** A vote cannot be changed or withdrawn.
- **Eligibility** = current membership. Against live config a vote verifies only while its signer is still a member with that key; **pinning** preserves an in-flight vote across composition changes (§9).
- **No late votes.** Once terminal, further votes are rejected.
- **Two independent thresholds** — separate `approve` and `reject` counts; they need not be equal (a reject threshold may be deliberately lower so a small bloc can veto).
- **First threshold reached wins.** The instant `approve` meets its threshold the request is `approved`; the instant `reject` meets its threshold it is `denied`. Whichever happens first makes the request terminal.
- **Deadlock → expiry.** If neither threshold can still be reached, or not enough members vote before `response_expires_at`, the request becomes `expired` (no proof).
- **Threshold shape.** `type` is `m_of_n` (the only type in `warrant/1.0`); `n` is informational (the active member count at issue time). Verification depends only on the `approve`/`reject` counts and distinct-member validity, never on `n`.

### 6.7 Resolve: verdict + proof + re-validation

A **proof** is issued for any **vote-decided** outcome — `approved` **or** `denied` — and carries the signed decisions that produced it. `expired`/`canceled` never carry a proof.

```json
{
  "id": "areq_8f3a",
  "status": "approved",
  "proof": {
    "committee": "cmte_finance_approvals",
    "request": "areq_8f3a",
    "action_fingerprint": "sha256:e0320dce244b9576a54a12f7507c7930ca858439668e91e8793cdcb313ef5c35",
    "fingerprint_version": "fp-jcs-strings-v1",
    "outcome": "approved",
    "threshold": {
      "type": "m_of_n",
      "n": 3,
      "approve": 2,
      "reject": 2
    },
    "decisions": [
      {
        "member": "mbr_a",
        "alg": "ed25519",
        "public_key": "base64…",
        "vote": "approve",
        "signed_at": "2026-06-16T18:05:00Z",
        "signature": "base64…"
      },
      {
        "member": "mbr_b",
        "alg": "ed25519",
        "public_key": "base64…",
        "vote": "approve",
        "signed_at": "2026-06-16T18:06:30Z",
        "signature": "base64…"
      }
    ],
    "issued_at": "2026-06-16T18:06:31Z"
  }
}
```

**Local re-validation (the zero-trust property).** Verifying a signature means checking, with a member's public key, that only the holder of the matching private key could have produced it — so the client confirms real humans signed, without taking the platform's word. Before running the block, the client MUST, **without trusting the platform's `status` flag**:

1. Resolve the member key set and threshold from the committee (§6.8) — or, for verification stable across composition changes, from the client's own **pinned** set.
2. For each decision, reconstruct the `sig-jcs-v1` payload — the constant `v: "sig-jcs-v1"`, plus `committee`, `request`, `fingerprint` (= the proof's `action_fingerprint`), and `fingerprint_version` taken from the proof, and the decision's own `vote` and `signed_at` — verify the signature against that decision's stated `public_key`, and confirm that key belongs to a current committee member (in live config, or in the client's pinned set).
3. **Recompute the `action_fingerprint` from the action about to execute and confirm it equals the proof's.** ← the binding step.
4. Confirm enough valid `approve` signatures **from distinct members** to satisfy the committee's threshold. Count at most one `approve` per distinct **member id** (a member may hold several keys); two decisions mapping to one member count once.
5. *(SHOULD, client policy)* Confirm freshness and any committee-signed deadline.

Only if all pass does the block run. A platform that flips `status` without real signatures fails 2/4; a mismatched action fails 3.

The safe ordering is **execute, then acknowledge** (§6.5), and the SDK does both for you: it runs the block and, on success, acknowledges — so a held approval can't silently re-run on the next retry. The downstream idempotency key covers the only gap (executed-but-acknowledge-failed).

**Freshness is a client policy, not a platform guarantee.** There is no platform execution window; `approved` is permanent. The client decides:

```rb
age = now − latest(decision.signed_at)      // anchor on the LATEST signature
reject if age > client_freshness_threshold  // an SDK config, e.g. 15 min
```

`signed_at` is per-decision and covered by the signature. Anchor on the *latest* (when the approval completed under "first-to-threshold-wins"). A client enforcing freshness MUST also acknowledge (or use a nonce) to escape a stale-but-held approval. Because a held `approved` proof re-runs the block on every retry until acknowledged, replay-to-double-effect is prevented by the downstream idempotency key, not by the proof — a client with a non-idempotent downstream MUST keep an executed-fingerprint ledger. A committee that wants a *hard* deadline puts `valid_until` in `params` (signed, and checked by the block).

### 6.8 Committee public keys

```
GET /committees/cmte_finance_approvals/keys
```
```json
{
  "committee": "cmte_finance_approvals",
  "threshold": {
    "type": "m_of_n",
    "n": 3,
    "approve": 2,
    "reject": 2
  },
  "members": [
    {
      "id": "mbr_a",
      "keys": [{ "alg": "ed25519", "public_key": "base64…" }]
    },
    {
      "id": "mbr_b",
      "keys": [{ "alg": "ed25519", "public_key": "base64…" }]
    }
  ]
}
```

A key is identified by its `public_key` (+ `alg`) — no separate `key_id`. This endpoint returns the committee's **current** keys and threshold; a proof verifies against these. Consequently, removing a member or rotating a key can render an *earlier* proof unverifiable against live config — so clients that need durable or offline verification **pin** the key set + threshold (§9) and verify against the pinned copy. Keys are cacheable; **rotation is a new `public_key`**.

### 6.9 Webhooks

```
POST <developer_webhook_url>
X-Warrant-Signature: t=…,v1=…

{
  "event": "approval_request.approved",
  "data": { …full request object incl. proof… }
}
```

Events: `approval_request.{approved,denied,expired,canceled}`. The webhook is a **wake-up**: the client verifies the signature (§4.3), then resumes by **re-issuing the same action** (§6.1) and re-validating the returned proof locally. Webhooks are an optimization over polling, never a substitute for §6.7.

---

## 7. Lifecycle & State Machine

```
                 ┌──────────── approve threshold met ──────────► approved ─┐
   create ──► pending ─────────── reject threshold met ──────────► denied──┤ (proof)
                 │  ├── response window elapses / deadlock ────► expired   │
                 │  └── client cancels (pending only) ─────────► canceled  │ (no proof)
                 └───────────────────────────────────────────────────────► ┘
   terminal states are FINAL. `acknowledged` is a separate flag on approved/denied.
```

Because votes are immutable and late votes rejected, a proof's decision set is final and append-only — there is no "the vote changed after I verified" window.

---

## 8. Committee Composition

A committee is a set of **members**, each with one or more **signing keys** and **contact methods** (email/SMS/Slack), plus two thresholds and a default response window. `N` is the active member count.

Composition is **live**, not snapshotted: decisions, threshold evaluation (§6.6), and proof verification (§6.7) resolve against the committee's *current* members, keys, and threshold (§6.8). This keeps the model simple and the keys endpoint authoritative, at one cost — a composition change **applies immediately**, including to in-flight requests. If a member is removed or a key rotated while a request is pending, the new composition governs it, and an already-issued proof may no longer verify against live config once its signers or threshold change.

A client that needs an in-flight request (or an older proof) to stay verifiable across composition changes **pins** the expected key set + threshold out-of-band and verifies against the pinned copy (§9). Eligibility is simply: a current member. If a removal makes a threshold unreachable, the request expires (a safe non-approval).

---

## 9. Trust Model

**V1 blocks the day-one threat — an autonomous agent talking its way into a destructive action — and every client-side mistake. The one thing it does not defend is a compromised platform.** Self-custody (V2) removes the platform's ability to *forge* a signature; only client-side **pinning** removes its ability to *redefine who signs*. Zero-trust = self-custody **and** pinning; neither alone suffices.

| Threat | V1 (platform-custody) | V2 (self-custody) |
|---|---|---|
| Prompt-injected agent fabricates approval | **Blocked** (no valid signatures) | Blocked |
| Compromised client runs the block unchecked | Blocked *iff* SDK re-validation used | Same |
| Approval for action A spent on action B | **Blocked** (fingerprint binding) | Blocked |
| Compromised platform forges an existing member's signature | **Possible** (platform holds keys) | **Blocked** (keys never leave members) |
| Compromised platform adds an attacker key / lowers threshold | **Possible** | **Still possible** unless the client **pins** composition |

Committee membership and threshold are platform-governed and signed by no one, so the root of trust for *who must approve, and how many* is the platform in both V1 and V2 — which is exactly what client-side pinning overrides.

---

## 10. Conformance

### 10.1 A conformant Platform

- **MUST** compute the fingerprint per §4.1 and **reject** any `params` containing a raw number.
- **MUST** treat `POST /approval-requests` as find-or-create-or-resume per the §6.1 table, holding at most one live request per `(committee, fingerprint)`, with **no clock** in resolution.
- **MUST** evaluate decisions, threshold, and proofs against the committee's **live** configuration (§8) and expose current member keys via §6.8.
- **MUST** enforce vote semantics (§6.6): one immutable vote per eligible member, no late votes, two independent thresholds, first-to-threshold-wins, deadlock→`expired`.
- **MUST** issue a proof (§6.7) for `approved`/`denied` and none for `expired`/`canceled`; **MUST NOT** invalidate an `approved` proof on a clock.
- **MUST** sign decisions per §4.2 and webhooks per §4.3; **MUST NOT** include any raw number in a signed/hashed byte-string.
- **MUST** support `cancel` (pending-only, else `409`) and `acknowledge` (flag, not status; idempotent).
- **SHOULD** deliver webhooks for terminal events and **SHOULD** render the bound `params` as the primary signing surface (§3.2).
- **MUST NOT** execute, or claim to track execution of, the guarded action.

### 10.2 A conformant Client / SDK

- **MUST** recompute the fingerprint locally (§4.1) and **MUST NOT** trust the platform's returned `action_fingerprint` or `status` flag.
- **MUST** perform local re-validation steps 1–4 of §6.7 before executing the block, and **MUST NOT** execute on a fingerprint mismatch or insufficient valid signatures.
- **MUST** resume by re-issuing the same action (content-addressed), carrying no `request_id` or token.
- **SHOULD** enforce a proof freshness policy anchored on the latest `signed_at` (§6.7), and by default **acknowledge after a successful block** (configurable off), so a forgotten acknowledgement is never what leaves a held approval to re-run on later retries.
- **SHOULD** thread the fingerprint as the downstream idempotency key for exactly-once (§12), and **MUST**, for a non-idempotent downstream, keep a local executed-fingerprint ledger (else a held proof replays the block).
- **SHOULD** verify `X-Warrant-Signature` (§4.3) on webhooks and bound `t` for replay.
- **MAY** pin the expected member key set + threshold and verify against it instead of §6.8 (zero-trust, V2).

### 10.3 Responsibility matrix

See §3.5. A claim of conformance MUST state which trust mode (V1 custody / V2 self-custody / pinned) it implements.

### 10.4 Conformance test vectors

Reference vectors for all three canonical byte-strings are provided inline in §4 — `fp-jcs-strings-v1` (§4.1), `sig-jcs-v1` (§4.2), and the webhook `v1` (§4.3) — each fully reproducible from the values shown. A conformant implementation **MUST** reproduce them byte for byte, and **SHOULD** include them in its own test suite.

---

## 11. SDK Usage

The SDK lives **inside a tool you expose to the agent** — it is not something the agent decides to call. The agent calls an ordinary tool (say `transfer_funds`) with whatever arguments it judges necessary; inside that tool, the sensitive code is wrapped in a `guard`. The agent has no concept of "Warrant," of approval, or of a request id — it just calls the tool and reads the result.

When no valid proof is in hand yet, the SDK does the protocol work (open or resume the request, notify the committee, collect votes) and returns a **natural-language status the agent can act on** — e.g. *"This action requires committee approval. The approvers have been notified. Call this tool again with the exact same arguments in a few minutes."* Because the request is content-addressed (§3.3), the agent's natural next move — **retry the same tool with the same arguments** — *is* the resume. There is no token, no `request_id`, and no "approval" parameter for the agent to carry.

That is the ergonomic core: an agent's ordinary retry behavior drives an asynchronous, multi-party approval across minutes or hours, and the guarded code runs exactly when — and only when — a valid proof exists. The examples below show the body of the *same* guarded `transfer_funds` tool in three clients.

A `guard` resolves to one of three results — `Approved`, `Pending`, or `Denied`. The no-proof terminal states (`expired`, `canceled`) surface as `Pending`, because re-invoking the action simply opens a fresh request — so the three-way handling below is all a tool needs.

### 11.1 Ruby

```ruby
warrant = Warrant::Client.new(api_key: ENV["WARRANT_API_KEY"])

# The body of a `transfer_funds` tool you expose to the agent.
# The agent calls it with arguments and reads the returned string;
# it never sees Warrant.
def transfer_funds(amount:, to:)
  result = warrant.guard(
    "cmte_finance_approvals",
    action: {
      type:   "transfer_funds",
      params: { amount: amount.to_s, to: } # strings, per §4.1
    },
    message: "Transfer $#{amount} to #{to}."
  ) do |grant|
    # Runs only after a valid, matching proof is verified locally.
    Payments.transfer!(amount:, to:, idempotency_key: grant.idempotency_key)
  end

  case result
  when Warrant::Approved
    "Done — transferred $#{amount} to #{to}."
  when Warrant::Pending
    "This action requires committee approval. The approvers have been notified. Call this tool again with the exact same arguments in a few minutes."
  when Warrant::Denied
    "The committee rejected this transfer. Do not retry."
  end
end
```

The strings returned on `Pending`/`Denied` are the tool's result — the agent's cue to wait and retry the identical call, or to stop.

### 11.2 TypeScript

```ts
const warrant = new Warrant({ apiKey: process.env.WARRANT_API_KEY! });

// A `transfer_funds` tool you expose to the agent. The agent calls it
// with arguments and reads the string back; it never sees Warrant.
async function transferFunds({ amount, to }: { amount: number; to: string }) {
  const result = await warrant.guard(
    "cmte_finance_approvals",
    {
      type: "transfer_funds",
      params: { amount: String(amount), to }, // strings, per §4.1
    },
    { message: `Transfer $${amount} to ${to}.` },
    async (grant) => {
      // Runs only after a valid, matching proof is verified locally.
      return payments.transfer({ amount, to, idempotencyKey: grant.idempotencyKey });
    },
  );

  switch (result.status) {
    case "approved":
      return `Done — transferred $${amount} to ${to}.`;

    case "pending":
      return (
        "This action requires committee approval. The approvers have been notified. Call this tool again with the exact same arguments in a few minutes."
      );

    case "denied":
      return "The committee rejected this transfer. Do not retry.";
  }
}
```

### 11.3 CLI (fully stateless)

Wrap an existing command as a guarded tool. The agent runs the *same command with the same args* each time; "resume" is indistinguishable from "retry," and stdout is the agent-facing status.

**Pass 1 — first call**

```
warrant guard cmte_finance_approvals \
  --type transfer_funds \
  --param amount=10000 \
  --param to=acct_123 \
  -- ./do_transfer.sh
```

```
→ opens/resumes the request (idem-key = fingerprint) and notifies the committee
→ exit 75 (EX_TEMPFAIL)
→ stdout: Pending committee approval — approvers notified.
          Re-run with the exact same arguments shortly.
```

**Pass 2 — identical call, a few minutes later**

```
warrant guard cmte_finance_approvals \
  --type transfer_funds \
  --param amount=10000 \
  --param to=acct_123 \
  -- ./do_transfer.sh
```

```
→ request now approved; the SDK re-validates the proof locally
→ runs ./do_transfer.sh with WARRANT_IDEMPOTENCY_KEY set
→ exit 0
→ stdout: Done.
```

No `--approval` flag and no requests table: the action's own arguments are the handle, and the agent's retry is the resume. Exit codes make the signal unambiguous: **0** approved-and-ran, **75** pending (retry the same args), **1** denied (do not retry).

### 11.4 Acknowledging a spent request (Ruby)

Because the fingerprint is the idempotency key, a decided request keeps resolving to that same terminal outcome — re-invoking an *identical* action returns the prior decision rather than opening a fresh request. **Acknowledging** marks the request "spent" and frees its fingerprint, so the next identical action starts a new approval (§6.5).

The SDK **acknowledges automatically after a successful block** (§10.2), so the approved path needs no code. Call `result.acknowledge!` yourself only to acknowledge a **denial** — the block never ran, so nothing auto-acknowledged it — when you'd rather a future identical action be asked anew than keep reading the old rejection. Leaving a denial unacknowledged is the cheap default: repeat attempts return the cached denial without re-notifying the committee.

```ruby
warrant = Warrant::Client.new(api_key: ENV["WARRANT_API_KEY"])

def transfer_funds(amount:, to:)
  result = warrant.guard(
    "cmte_finance_approvals",
    action: {
      type:   "transfer_funds",
      params: { amount: amount.to_s, to: }
    },
    message: "Transfer $#{amount} to #{to}."
  ) do |grant|
    Payments.transfer!(amount:, to:, idempotency_key: grant.idempotency_key)
  end

  case result
  when Warrant::Approved
    # The SDK already acknowledged after the block succeeded — nothing to do here.
    "Done — transferred $#{amount} to #{to}."
  when Warrant::Denied
    # The block never ran, so nothing auto-acknowledged. Acknowledge by hand only if you
    # want a future identical action asked anew instead of re-reading this denial.
    result.acknowledge!
    "The committee rejected this transfer."
  when Warrant::Pending
    "This action requires committee approval. The approvers have been notified. Call this tool again with the exact same arguments in a few minutes."
  end
end
```

---

## 12. Security Considerations

- **Dual risk (§3.2).** The signing surface MUST render the fingerprinted `params`; free-text `message`/`context` MUST NOT be the decision surface.
- **Proof is a warrant, not a bearer secret (§3.4).** Execution lives in client code; the fingerprint binds the proof to one action. Don't over-rotate on protecting proofs; protect the execution path and (V2) the keys.
- **Freshness (§6.7).** `signed_at` is only as honest as whoever holds the key. In V1 the platform could forward/back-date it; clients SHOULD reject future-dated `signed_at` (minus skew) and cap absolute age — so in V1 freshness bounds accidental staleness, not a hostile platform. V2 moves the anchor to the device, making it platform-independent.
- **V1 platform compromise (§9).** A fully compromised platform can mint real signatures or rewrite composition. V1 is not a defense against this; pinning + self custody is.
- **Exactly-once is downstream (§3.3).** A valid proof authorizes execution; it does not guarantee a single execution. Thread the fingerprint as the downstream idempotency key so a double-run is a single real effect. `acknowledge` is **not** an exactly-once gate. The flip side: because that key *is* the fingerprint, two genuinely-distinct actions that are byte-identical (paying the same vendor the same amount twice) dedupe to one effect — when repeats are legitimate, put a distinguishing value (invoice id, nonce) in `params` so each intent gets its own fingerprint, approval, and key.
- **No raw numbers anywhere signed/hashed (§4).** Eliminates cross-language float drift, the only realistic way an honest implementation produces a non-matching hash.

---

## Appendix A — Scenarios

Condensed play-tests that exercise the protocol (committee `cmte_finance_approvals`, `m_of_n` 3, approve 2 / reject 2, V1 custody).

- **A1 Happy path (webhook).** Two members approve → request `approved`, proof assembled, webhook fires → client re-issues the action → proof re-validates (committee keys, signatures, fingerprint match, threshold, freshness) → block runs, then the client acknowledges so a retry won't re-resolve to this proof (single real effect guaranteed downstream, §12).
- **A2 Polling.** Same as A1 without webhooks; `GET` reaches `approved` + proof. The poll is not trusted — the client still re-validates.
- **A3 Retry while pending.** A re-`POST` of the identical action returns the same `pending` request (`200`, no re-notification). A one-character `params` change is a *different* fingerprint → a new request.
- **A4 Denial.** A reject count reaching its threshold before approve → `denied` + proof; the block never runs.
- **A5 Expiry by deadlock.** Votes stall such that neither threshold is reachable in time → `expired`, no proof.
- **A6 Cancel.** Client cancels a `pending` request → `canceled`; removes a dangling approvable request.
- **A7 Cancel races approval.** If approval lands first, `cancel` returns `409 approved` with the proof; the SDK SHOULD treat "409-approved-after-cancel" as *do not execute* (the caller's last intent was abort).
- **A8 Repeat later (no carry-over).** Yesterday's approved request, if acknowledged, frees the fingerprint → today's identical action creates a fresh request; if not acknowledged, the stale held proof is refused by freshness and must be acknowledged.
- **A9 Crash recovery.** Lost the `request_id`? Re-run the action; content-addressing lands on the same request. (List endpoint exists for dashboards.)
- **A10 Compromised platform (V1).** Garbage/absent signatures fail local re-validation. A *fully* compromised platform holding the keys can mint real signatures — the documented V1 boundary.
- **A11 Action-swap attack.** Approval obtained for `{amount:"10"}`, execution attempted for `{amount:"10000000"}` → recomputed fingerprint mismatches the proof → refuse. The whole point of fingerprint binding.
- **A12 Stale proof.** A proof unused for hours is refused by the client's freshness policy; the client acknowledges to free the fingerprint and starts a fresh cycle.

---

## Appendix B — Conformance Test Vectors

Reference vectors for all three canonical byte-strings live inline in §4: `fp-jcs-strings-v1` (§4.1) covers flat strings, nested objects with booleans/null, and string escaping (control char + astral UTF-8); `sig-jcs-v1` (§4.2) gives a full Ed25519 decision — canonical payload, signed digest, and signature — from a published test key; the webhook `v1` (§4.3) gives a complete HMAC example. Each is reproducible from the values shown. A conformant implementation MUST reproduce them byte for byte, and MAY republish them as machine-readable JSON for its own test suite.

---

## Appendix C — Versioning

- **Releases.** `warrant/1.0` — initial stable release (2026-06-20).
- **Protocol version** `warrant/MAJOR.MINOR`. Breaking wire changes bump MAJOR.
- **Byte-string schemes** are versioned independently and *inside* the hashed object (`fp-jcs-strings-v1`, `sig-jcs-v1`, webhook `v1`), so a verifier selects the algorithm from the artifact it is checking and old artifacts stay verifiable across upgrades. A future `fp-jcs-strings-v2` can change rules without breaking old proofs.

---

*References:* [RFC 2119] Key words for requirement levels · [RFC 8785] JSON Canonicalization Scheme (JCS) · [RFC 3339] Date and Time on the Internet.
