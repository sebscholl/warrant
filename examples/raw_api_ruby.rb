# frozen_string_literal: true

# transfer_funds — a guarded agent tool with NO SDK (Ruby, raw API)
# =================================================================
#
# Everything the other examples delegate to `warrant.guard(...)`, this file does by hand
# against a compliant Warrant REST API. It is deliberately long: that length IS the point.
#
#     There is no SDK requirement. An SDK is pure convenience over a compliant API — it
#     computes the fingerprint, opens/resumes the request, and re-validates the proof for
#     you. You can do all of it yourself and interoperate with the exact same platform.
#
# Notably, this uses only the Ruby standard library — `json`, `digest`, `base64`,
# `openssl` (Ed25519), `net/http`, `time`, `set`. No gems.
#
# This is still the same agent tool as the others (see ./README.md for what an agent tool
# is, and why the guard logic must live INSIDE this method, where the agent cannot reach,
# skip, or edit it). The only difference is that the body talks to the API directly.
#
# The client's non-negotiable job is LOCAL RE-VALIDATION (spec §6.7): never trust the
# platform's `status` flag or its returned `action_fingerprint`. Recompute and re-verify
# everything yourself before performing the side effect.
#
# NOTE: the base URL and `Payments` are illustrative; everything else is real, runnable
# stdlib. Ed25519 via OpenSSL needs OpenSSL >= 1.1.1 (Ruby >= 3.0). See ../WARRANT.md.

require "json"
require "digest"
require "base64"
require "openssl"
require "net/http"
require "time"
require "set"

BASE_URL  = "https://api.warrant.example/v1"
COMMITTEE = "cmte_finance_approvals"
FP_VERSION = "fp-jcs-strings-v1"
MAX_PROOF_AGE_SECONDS = 15 * 60 # our freshness policy (§6.7) — a client choice, not the platform's

# The three replies the model can get back — short instructions it will act on.
APPROVED = "Done — the transfer completed."
PENDING  = "Awaiting committee approval. Call this tool again with the same arguments shortly."
DENIED   = "The committee rejected this transfer. Do not retry."

# Raised when local re-validation fails. We then MUST NOT execute the action.
class ProofError < StandardError; end

# --- Canonical byte-strings (spec §4) -------------------------------------------------

# RFC 8785 (JCS) for our domain. The Warrant byte-strings only ever contain strings,
# booleans, and null (no raw numbers, §4.1), so deep-sorting keys and generating compact
# JSON is byte-identical to full JCS here. A production client MAY use a vetted RFC 8785
# library; for these payloads it is equivalent.
def jcs(obj)
  JSON.generate(deep_sort(obj))
end

def deep_sort(obj)
  case obj
  when Hash  then obj.keys.sort.each_with_object({}) { |k, h| h[k] = deep_sort(obj[k]) }
  when Array then obj.map { |e| deep_sort(e) }
  else obj
  end
end

# The action fingerprint — `fp-jcs-strings-v1` (§4.1). The content address the committee
# signs, and our idempotency key. WE compute it; we never trust the server's.
def fingerprint(committee, type, params)
  canonical = jcs({ "version" => FP_VERSION, "committee" => committee, "type" => type, "params" => params })
  "sha256:#{Digest::SHA256.hexdigest(canonical)}"
end

# --- Tiny REST helper -----------------------------------------------------------------

def api(method, path, body = nil)
  uri = URI("#{BASE_URL}#{path}")
  request = (method == :get ? Net::HTTP::Get : Net::HTTP::Post).new(uri)
  request["Authorization"] = "Bearer #{ENV.fetch('WARRANT_API_KEY')}"
  request["Content-Type"] = "application/json"
  request.body = JSON.generate(body) if body
  response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https") { |http| http.request(request) }
  JSON.parse(response.body)
end

# --- Local re-validation (spec §6.7) — the zero-trust property -------------------------

# Re-derive the verdict from the signed decisions, WITHOUT trusting the platform.
# Raises ProofError if anything fails — in which case the caller MUST NOT run the side
# effect. Mirrors the numbered steps in §6.7.
def verify_proof!(proof, committee_keys, expected_fingerprint)
  threshold = committee_keys["threshold"]

  # Step 1: resolve the member key set (live config here; a zero-trust client would verify
  # against its own PINNED copy instead — §9). Build public_key -> member_id.
  pubkey_to_member = {}
  committee_keys["members"].each do |member|
    member["keys"].each { |key| pubkey_to_member[key["public_key"]] = member["id"] }
  end

  # Step 3: the binding step. Recompute the fingerprint of the action we are ABOUT TO RUN
  # and confirm it equals the proof's. This is what stops "approve $10, execute $10M".
  unless proof["action_fingerprint"] == expected_fingerprint
    raise ProofError, "fingerprint mismatch: the approved action is not the one about to execute"
  end

  # Steps 2 + 4: verify each approve signature and count DISTINCT members.
  approving = Set.new
  latest_signed_at = nil

  proof["decisions"].each do |decision|
    next unless decision["vote"] == "approve"

    member = pubkey_to_member[decision["public_key"]]
    next if member.nil? # signer is not a current committee member -> ignore this decision

    # Reconstruct the exact sig-jcs-v1 payload (§4.2): the constant `v`, plus committee /
    # request / fingerprint / fingerprint_version FROM THE PROOF ENVELOPE, and vote /
    # signed_at from the decision itself.
    payload = {
      "v" => "sig-jcs-v1",
      "committee" => proof["committee"],
      "request" => proof["request"],
      "vote" => decision["vote"],
      "signed_at" => decision["signed_at"],
      "fingerprint" => proof["action_fingerprint"],
      "fingerprint_version" => proof["fingerprint_version"]
    }
    digest = Digest::SHA256.digest(jcs(payload)) # the 32 bytes that were signed

    # Plain Ed25519 over the 32-byte digest (§4.2, "what gets signed").
    public_key = OpenSSL::PKey.new_raw_public_key("ED25519", Base64.decode64(decision["public_key"]))
    next unless public_key.verify(nil, Base64.decode64(decision["signature"]), digest)

    approving << member # at most one per distinct member id (a member may hold several keys)
    signed_at = Time.iso8601(decision["signed_at"])
    latest_signed_at = latest_signed_at.nil? ? signed_at : [latest_signed_at, signed_at].max
  end

  if approving.size < threshold["approve"]
    raise ProofError, "not enough valid approvals from distinct members to meet the threshold"
  end

  # Step 5: freshness — a client policy, not a platform guarantee. Anchor on the LATEST
  # signature (when the approval completed under first-to-threshold-wins).
  if latest_signed_at && (Time.now.utc - latest_signed_at) > MAX_PROOF_AGE_SECONDS
    raise ProofError, "approval is stale; acknowledge it and request a fresh one"
  end
end

# --- The tool -------------------------------------------------------------------------

# Same tool, no SDK. The agent supplies amount/to; this body is unreachable to it.
def transfer_funds(amount:, to:)
  action = { "type" => "transfer_funds", "params" => { "amount" => amount.to_s, "to" => to } }

  # We compute the fingerprint ourselves: it is the idempotency key, and we re-bind the
  # proof to this exact action before executing.
  fp = fingerprint(COMMITTEE, action["type"], action["params"])

  # POST is find-or-create-or-resume (§6.1): the platform derives the dedup key from
  # `action`, so the SAME action always lands on the SAME request. No request id to carry.
  created = api(:post, "/approval-requests",
                committee: COMMITTEE, action: action, message: "Transfer $#{amount} to #{to}.")

  case created["status"]
  when "denied"
    DENIED
  when "approved"
    # Re-validate locally BEFORE doing anything irreversible (§6.7).
    proof = created["proof"]
    committee_keys = api(:get, "/committees/#{COMMITTEE}/keys") # live config (or a pinned copy)
    verify_proof!(proof, committee_keys, fp) # raises ProofError -> we never execute

    # Only now, with a verified, action-bound proof, perform the side effect — threading
    # the fingerprint as the downstream idempotency key so a retry can't double-spend.
    Payments.transfer!(amount:, to:, idempotency_key: fp)

    # Mark the request spent so a future identical action opens a fresh approval (§6.5).
    api(:post, "/approval-requests/#{created['id']}/acknowledge", {})

    APPROVED
  else
    # pending — or a brand-new pending the POST just opened because the prior request had
    # expired/been canceled. Either way the agent should retry the same call later.
    PENDING
  end
end
