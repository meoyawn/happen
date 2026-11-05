# MCP port inventory

Reference: Codex `5112ce6edeb95f2296a5ffec47dbab4764e65853`, paths relative
to `codex-rs/`. This inventory distinguishes executable proof from behavior
which merely exists in the implementation. It is not a completion claim.

Happen retains its YAML configuration and private per-server-name/full-URL
credential files. Config owns a stdio process across aliases, projects and
consumers; individual requests do not own it. Ordinary MCP OAuth is in scope.
ChatGPT connectors, enterprise-managed authorization and plugins are excluded.

## Discovery and HTTP recovery

Unless another owner is named, **ported** below means
`test/mcp_transport_test.dart`. Table-driven ports retain every vector of the
named upstream case, rather than selecting one convenient rejection.

| Upstream test (`rmcp-client/tests/`) | State / primary proof |
| --- | --- |
| `mcp_2026_discovery::read_only_tool_requests_preserve_host_policy_and_caller_metadata` | Partial: caller metadata/cursor/arguments survive modern and legacy requests; caller metadata cannot select the wire protocol. Host-enforced read-only/network policy remains pending |
| `modern_mode_uses_sdk_discovery_and_self_contained_request_metadata` | Ported, JSON/SSE variants |
| `modern_discovery_does_not_follow_redirects_with_sensitive_headers` | Ported: status is retained, destination is not contacted |
| `legacy_mcp_requests_follow_same_origin_redirects_with_configured_headers` | Ported: all five POST redirect statuses, method/body transformations, configured headers and referrer; plaintext redirect drops proxy authorization |
| `legacy_fallback_does_not_follow_cross_origin_tool_redirects` | Ported: both 307/308 after a real same-origin hop, with no destination contact; cycles stop at ten redirects |
| `modern_discovery_accepts_metadata_namespaced_server_identity` | Ported |
| `modern_discovery_accepts_missing_server_identity` | Ported |
| `modern_discovery_accepts_native_sse_responses` | Ported |
| `modern_discovery_accepts_metadata_namespaced_server_identity_over_sse` | Ported |
| `modern_http_rejects_oversized_discovery_and_tool_json_responses` | Ported, including the complete JSON/error/SSE matrix in `mcp_2026_message_limits.rs`; modern wire bound is 8 MiB |
| `legacy_http_keeps_existing_large_json_response_behavior` | Ported: the full modern-limit-crossing description is preserved, without a modern wire cap |
| `modern_discovery_retries_transient_service_unavailable` | Ported: 503 retry does not initialize a legacy session |
| `modern_discovery_retries_json_unsupported_protocol_errors` | Ported, new request ID asserted |
| `modern_sdk_emits_standard_headers_and_rejects_invalid_header_schemas` | Ported through the real manager/catalog/call owner, with default and configured user agents |
| `legacy_mode_never_probes_server_discovery` | Adaptation: Happen is modern-first with evidence-based legacy fallback, not Codex's rollout flag / explicit legacy mode |
| `modern_mode_falls_back_only_for_a_json_rpc_method_not_found` | Ported |
| `modern_legacy_fallback_preserves_authentication_required_error` | Ported: initialize's 401 survives without handshake replay |
| `modern_legacy_fallback_retries_transient_initialize_failures` | Ported |
| `modern_mode_falls_back_when_discovery_only_advertises_legacy_versions` | Ported |
| `modern_discovery_never_downgrades_without_valid_legacy_only_version_evidence` | Ported, missing/empty/unknown/invalid lists |
| `modern_mode_falls_back_when_legacy_server_explicitly_rejects_modern_version` | Ported, all three error codes |
| `modern_discovery_rejects_uncorrelated_legacy_version_rejection` | Ported |
| `modern_discovery_rejects_uncorrelated_method_not_found_errors` | Ported, null/foreign IDs over JSON/SSE |
| `modern_mode_falls_back_for_legacy_http_prevalidation_errors` | Ported, all MIME/message vectors |
| `modern_mode_negotiates_a_server_selected_legacy_protocol_version` | Ported, including `2024-11-05` |
| `modern_discovery_rejects_unrecognized_or_modern_null_id_errors` | Ported, complete message/version vectors |
| `modern_discovery_rejects_non_legacy_http_prevalidation_errors` | Ported, all status/code/ID/MIME vectors |
| `modern_mode_falls_back_for_plain_404_and_405_discovery_responses` | Ported |
| `modern_discovery_rejection_does_not_downgrade_to_legacy` | Ported |
| `stdio_protocol_marker_rejects_unknown_versions_before_launch` | Codex-specific opt-in variable is not interpreted by Happen; see stdio environment work below |
| `mcp_2026_sse_discovery::modern_sse_discovery_accepts_metadata_namespaced_server_identity` | Ported |
| `modern_sse_discovery_falls_back_for_correlated_method_not_found` | Ported positive vector, alongside the JSON positive and both SSE negative controls |
| `modern_sse_discovery_rejects_uncorrelated_method_not_found` | Ported, both IDs |
| `streamable_http_recovery::streamable_http_initialize_retries_remote_no_response_error` | Local adaptation ported with a real dropped TCP response; no remote-executor claim |
| `streamable_http_initialize_retries_transient_http_status` | Ported: upstream 502 plain-body vector, plus the existing 503 case |
| `streamable_http_initialize_retries_json_rpc_transient_status` | Ported: upstream HTTP 502 / JSON-RPC error vector |
| `streamable_http_retries_initialized_notification_status` | Ported: 502 during notification rebuilds the handshake |
| `streamable_http_tools_list_retries_transient_http_status` | Ported: 502 plain-body vector |
| `streamable_http_tools_list_retries_json_rpc_transient_status` | Ported: 502 JSON-RPC vector |
| `streamable_http_404_session_expiry_recovers_and_retries_once` | Ported, rebuilt session header asserted |
| `streamable_http_session_recovery_retries_initialize_failure` | Ported |
| `streamable_http_401_does_not_trigger_recovery` | Ported |
| `streamable_http_401_challenge_is_a_tool_error_without_replay` | Ported: both challenge vectors preserve `mcp/www_authenticate`, return an error result and allow a later user call. OAuth owner may refresh without replaying the rejected call |
| `streamable_http_403_scope_challenge_returns_insufficient_scope` | Ported; all 16 valid/invalid/ambiguous scope vectors from `src/www_authenticate_tests.rs` run at the real HTTP boundary |
| `streamable_http_403_finds_bearer_challenge_in_later_header_value` | Ported, plus all five unrelated/malformed negative controls from the parser suite |
| `streamable_http_404_recovery_only_retries_once` | Ported, later user call also checked |
| `streamable_http_non_session_failure_does_not_trigger_recovery` | Ported |
| `mcp_2026_discovery/tool_call_session_meta_tests::recovered_tool_calls_use_current_session_capabilities` | Partial: protocol/session envelope rebuilt; changed capabilities/caller metadata pending |
| `streamable_http_recovery/telemetry_tests::recovery_retains_originator_without_initial_credentials` | Pending originator metadata adaptation |

The shared-owner extension additionally checks coalesced HTTP-session recovery
with and without cancellation of the initiating caller. A modern 404 must not
be treated as legacy session expiry.

### Transport completion batch evidence

- Expanded HTTP baseline: **79 passed / 33 failed**, before its matching
  implementation changes. Failures included all four modern limit vectors,
  legacy redirects, resource error preservation and authentication classification.
- Stdio baseline: **1 passed / 2 failed**. Modern oversized lines were accepted;
  discovery timeout caused an unsupported `initialize` instead of staying modern.
- A separate caller-metadata regression reproduced a legacy request acquiring
  modern HTTP headers from caller-supplied `_meta`. The selected version is now
  captured by the transport, never inferred from that untrusted field.
- Default user-agent regression reproduced `Dart/3.13 (dart:io)` instead of the
  MCP client identity. Explicit configured user agents remain authoritative.
- Focused HTTP/stdio/OAuth/pooling/inventory/reload/model-output siblings:
  **184 passed**. Logs are `happen-mcp-http-completion-{baseline,siblings}.txt`,
  `happen-mcp-stdio-completion-baseline.txt`,
  `happen-mcp-metadata-authority-baseline.txt`, and
  `happen-mcp-user-agent-baseline.txt` in the session's approved tool-log directory.
- A later UTF-8 configured-header port exposed Dart IO's ASCII-only public
  header API. **User excluded cases requiring changes to Dart's HTTP stack on
  2026-11-05.** The byte-level test remains explicitly skipped, not claimed as
  supported or ported. The proposed separate HTTP codec was removed; the owned
  `third_party/http/` fork and Dart IO path are unchanged. Redirect body lengths
  were fixed without changing that stack. Current wire/stdio verification:
  **118 passed / 1 explicit scope skip**, `happen-mcp-wire-user-exclusion.txt`.

This is not completion of the remaining OAuth, process-ownership, policy,
continuation or Events durability work below. Wire bounds are distinct from
Happen's IPC/catalog and model-facing output bounds.

## Ordinary OAuth

All nine tests in `rmcp-client/tests/mcp_2026_oauth_discovery.rs` have ordinary
OAuth ports in `test/mcp_oauth_discovery_test.dart`:

- `oauth_discovery_uses_get_first_without_starting_a_legacy_mcp_session`
- `legacy_oauth_discovery_follows_same_origin_metadata_redirects`
- `legacy_oauth_discovery_rejects_cross_origin_authorization_metadata_redirects`
- `legacy_oauth_discovery_rejects_authorization_metadata_redirect_cycles`
- `legacy_oauth_discovery_rejects_cross_origin_resource_metadata_redirects`
- `legacy_oauth_discovery_accepts_authorization_metadata_without_an_issuer`
- `legacy_oauth_discovery_rejects_an_explicit_mismatched_issuer`
- `oauth_discovery_does_not_invent_support_for_an_unauthenticated_legacy_server`
- `interactive_oauth_rejects_untrusted_authorization_metadata`: complete eight
  metadata scenarios × DCR/pre-registered client. Plugin redirect policy is
  excluded, not substituted for ordinary OAuth.

These ports also check resource-header isolation, no contact with a rejected
redirect destination, callback-specific paths and resource-bound code exchange.
All 26 cases failed before the implementation port.

`test/mcp_auth_test.dart` separately owns real client API/CLI login,
callback state/issuer rejection, private persistence, refresh across owners,
cancellation/listener cleanup and logout. `test/mcp_oauth_recovery_test.dart`
owns the applicable ordinary startup/runtime matrices, with 29 real-client
cases. Remaining OAuth work is listed separately, not implied by those passes:

| Upstream family | State / primary proof |
| --- | --- |
| `streamable_http_oauth_startup.rs` | Ported: direct metadata/OIDC fallback, negotiated confidential Basic/Post without storing configured secrets, client-ID mismatch before provider contact, discovered audience, issuer changes before startup / after an unexpired token's 401, no second discovery after failure, persisted auth status and expired-unrefreshable cases. Both tool-challenge vectors are adapted to Happen's stronger no-replay contract. Dynamic gateway helpers are absent |
| `streamable_http_oauth_tool_call.rs::runtime_oauth_recovery` | All ten vectors ported: no-refresh, rejected, malformed, transient, early-malformed, early-transient, refreshable, unexpired, unknown-expiry, revoked |
| `startup_oauth_recovery` | All three vectors ported: startup-malformed, startup-transient, startup-refreshable |
| `streamable_http_oauth_store_pinning.rs` | Ported single-file-authority adaptation in `test/mcp_oauth_credentials_test.dart`: real legacy session expiry with removed/directory/symlink authority and a live stale alternate credential. Every wire request retains the selected authority or fails safely; no stale/anonymous fallback. Plugin-only transport-provided-token mode is excluded |
| `src/oauth_client_registration_tests.rs` | Applicable ordinary matrix ported in `test/mcp_oauth_registration_test.dart`: native DCR selection/exact redirect preservation, all seven provider-exception vectors, verified endpoint delegation, same-origin registration redirect with SDK Basic winning over resource headers, issuer-bound metadata and missing registration rejection. A distinct DCR-secret Post vector is added. Codex-hosted automatic CIMD identity / explicit CIMD mode and configurable external callback URLs are absent; Happen's existing DCR/pre-registered-client scheme and config schema are retained |
| `src/oauth_http_client_security_tests.rs` | All six ordinary families ported through real login/HTTP boundaries in `test/mcp_oauth_http_security_test.dart`: five 503/OIDC fallback vectors, seven terminal failures, four unrelated-request/status negative controls, shared fallback deadline, both ordinary registration-header vectors, and both redirect timeout/body-limit vectors. AgentPluginV1 is excluded; no remote HTTP executor is simulated |
| `src/oauth_callback{,_input}_tests.rs`, applicable `perform_oauth_login.rs` callbacks | `test/mcp_oauth_callback_test.dart` owns pasted/loopback malformed/duplicate/state/error inputs, both native mix-up defenses, code decoding/PKCE/redirect binding, missing/wrong callback IDs and full-URL tenant identity. Existing API tests own missing/wrong issuer and client authority. Custom external redirect/query configuration is absent, not introduced to reproduce a Codex-only surface |
| `src/oauth/tests/`, `oauth/refresh_lock_tests.rs` | Real-file guard/rotation/failed-save/replacement/read-failure/cancellation/death/timeout matrices are ported in `test/mcp_oauth_credentials_test.dart`; see complete applicability and staged evidence below. Codex keyring/aggregate backend selection is not Happen's credential schema |
| `src/http_headers_tests.rs` | Dynamic gateway-header helpers are not in Happen's config. Startup ports prove literal/env resource headers and configured user agents do not escape to the authorization origin; the remaining helper-independent header matrix still needs classification |

### Startup/runtime recovery evidence

The settled baseline was **13 passed / 16 failed**
(`happen-mcp-oauth-recovery-settled-baseline.txt`). After startup-token reuse was
fixed, a staged baseline exposed four runtime classification failures among
seven cases (`happen-mcp-oauth-runtime-classification-baseline.txt`). Both
confidential-client negotiation vectors also failed before their repair
(`happen-mcp-oauth-confidential-baseline.txt`). All 29 now pass in
`happen-mcp-oauth-recovery-first.txt`. The preliminary baseline did not wait for
terminal connection ownership; its counts are not the canonical baseline.

OAuth prepares one access-token snapshot before MCP connection and reuses it
through discovery/catalog initialization, including zero-expiry responses.
Expired/rejected credential failures require authentication; a failed proactive
refresh of a still-valid token is an ordinary error and never consumes the MCP
HTTP retry budget. One issuer/resource-bound metadata snapshot serves refresh;
authorization-code PKCE support is not required to refresh. Failures/revocation
preserve credential bytes. Successful responses carry omitted refresh tokens
and scopes forward. Actual rejected tool calls retain their wire challenge and
are never replayed; repaired credentials benefit a later explicit call only.

Expanded HTTP/stdio/OAuth/pooling/inventory/reload/model-output siblings passed
**223 tests / 1 explicit scope skip**
(`happen-mcp-oauth-recovery-siblings.txt`). An owned offscreen Dart VM probe was
hot-reloaded and returned
`{"startupRefreshes":1,"totalRefreshes":2,"toolCalls":0,"isError":true,"credentialsPreserved":true}`.
It was explicitly stopped afterward. This does not prove the unported
registration/callback, locking/rotation/failed-save or store-pinning races.

The full startup/runtime verification then passed **828 backend tests / 2
intentional skips**, workspace analysis with **0 errors/warnings** (120 infos),
and all **46/46** deterministic context cases. Evidence logs:
`happen-oauth-{analysis,backend,e2e}.txt`; request-equality report:
`.local/context-contract/1793847389882903/report.json`. These results precede the
callback/HTTP-security batch, whose baseline is recorded separately.

### Callback and HTTP-security completion batch

The first 50 ports ran before the repair. After correcting one fixture assertion
to distinguish an initial metadata GET from a failed registration POST to the
same path, the settled baseline was **25 passed / 25 failed**:
`happen-mcp-oauth-security-settled-baseline.txt`. No failing product case was
removed. Five additional callback-ID/tenant checks exercise the already-working
native redirect identity, bringing this batch to **55 cases**.

Pasted URLs trim surrounding whitespace and reject credentials, fragments,
oversized input, duplicate parameters (including percent-encoded duplicate
names), missing/empty codes, invalid state, and mixed code/error responses.
The loopback path uses the same ambiguity/state gate. Invalid input is rejected
before consuming the login, and a later valid callback exchanges exactly one
code. Provider error descriptions and callback values are not echoed. Both
issuer-bound and server-specific native redirect modes retain their security
contract; Happen does not add Codex's configurable external redirect URLs.

503 recovery only tries the same issuer's OIDC candidates, skips malformed
candidate metadata, retains meaningful terminal status/issuer failures, and
does not follow fallback redirects or contact their cross-origin destinations.
Unrelated POST/protected-resource/other-path/status failures do not acquire
this fallback. Candidates share one discovery deadline. DCR follows bounded
same-origin redirects while preserving resource headers; ordinary uncredentialed
DCR may follow a cross-origin redirect without carrying resource-only headers.
Each redirect body is bounded before following, and all hops share one deadline.
Code/token exchanges never opt into redirect replay.

The first repair passed **108 / 110** OAuth-focused cases and reached both real
20-second deadlines. The remaining failures exposed that Dart's timeout token
throws `TimeoutException`, not `CancelledException`. The assertions were
corrected to require a redacted, identifiable OAuth timeout (not just any
failure), retaining exact contacted-candidate/hop counts. Both failed on the
generic diagnostic before its repair:
`happen-mcp-oauth-timeout-diagnostic-baseline.txt`. The real fixed deadlines are
used rather than adding a production-only test timeout knob.

Final callback/HTTP-security/discovery/startup/runtime/API/CLI siblings:
**115 passed**, `happen-mcp-oauth-security-repaired.txt`. An owned offscreen VM
hot reload returned
`{"invalidCallbackRejected":true,"codeExchanges":1,"authenticated":true}`;
the earlier startup/non-replay probe still returned its exact five fields.
The probe was explicitly stopped. Workspace analysis had no errors/warnings
(132 infos). The following full backend run was **882 passed / 2 scope skips /
1 failed**: an empty result in the retained interrupted-session listing test.
That failure remains visible and the sequential E2E stage did not run. Evidence:
`happen-oauth-security-{analysis,backend}.txt`; the earlier 828-test green
snapshot must not be used as this batch's full-suite verdict. Ordinary
lock/rotation/failed-save and store-pinning matrices remain open. The subsequent
registration batch is recorded below.

### Ordinary registration completion batch

`test/mcp_oauth_registration_test.dart` adds **17** real-client cases. The
complete upstream file is classified as follows:

| Upstream case | Happen boundary / adaptation |
| --- | --- |
| `automatic_cimd_uses_stable_or_callback_specific_identity` | Codex's hosted `chatgpt.com/oauth/codex/.../client.json` identity has no Happen-owned metadata document or registration selector. It is not invented or fetched. Both native mix-up defenses are already ported; the new advertised-CIMD case proves Happen still selects its own DCR client |
| `registration_selection_preserves_dcr_capabilities_and_exact_redirects` | All four native vectors: CIMD unsupported, auth-method metadata omitted, private-key auth advertised, and issuer-bound native callback. Happen always owns its `127.0.0.1` listener; custom HTTPS redirect / localhost host selection are not exposed by its schema. Exact dynamic URI equality is asserted at registration, browser authorization and code exchange |
| `legacy_provider_exceptions_require_exact_issuer_and_endpoint_origins` | All seven vectors reach the real OAuth owner. Six HTTPS vectors use a local TLS peer while preserving the complete original URI/Host. The plaintext non-loopback vector is rejected before contact under Happen's stricter HTTPS rule |
| `verified_issuer_can_delegate_authorization_and_token_to_one_origin` | Real issuer metadata, delegated registration/token endpoints and PKCE exchange. Resource credentials never reach the delegate |
| `resource_headers_follow_same_origin_registration_redirect_and_sdk_auth_wins` | Both registration POSTs retain resource headers and the exact redirect URI; token Basic authorization overrides the resource bearer. Additional DCR-returned-secret Post negotiation asserts the form credentials while leaving the resource gateway header on its own origin |
| `invalid_cimd_metadata_and_redirects_fail_without_dynamic_registration` | Ordinary issuer-bound-without-issuer and missing-DCR-endpoint guards run before registration/exchange. Explicit CIMD-only auth/redirect restrictions are not rebranded as DCR restrictions; callback URL security is owned by the callback matrix |

Settled baseline: **13 passed / 4 failed**,
`happen-mcp-oauth-registration-settled-baseline.txt`. Both allowed provider
exceptions were rejected; both DCR-returned-secret exchanges silently used
public-client authentication when the response omitted its auth method. The
preliminary baseline had a broken TLS socket route; its negative controls
correctly failed for not reaching metadata, so its counts are not product
evidence. The fixture now uses the public secure-socket connection factory,
trusts only the checked-in certificate, and never contacts real providers. No
HTTP-stack code, codec or owned fork was changed.

Production matches the complete HTTPS issuer plus both endpoint origins for
the two narrow Codex provider exceptions. Confidential DCR replies without an
explicit method negotiate Basic/Post from the same metadata snapshot, then
retain the selection for future refresh. Explicit configured authentication and
provider-selected methods remain authoritative. Native callback redirects are
not rewritten, and authorization-origin metadata requests remain free of
resource-only headers.

Registration/callback/HTTP-security/discovery/startup/runtime/API/CLI siblings,
plus both retained session-listing tests, pass **134 tests**:
`happen-mcp-oauth-registration-first.txt`. The earlier full-suite listing failure
did not reproduce in this focused run; its cause is not declared fixed. Final
analysis/backend/E2E verification is backgrounded with
`happen-oauth-registration-{analysis,backend,e2e}.txt`. Ordinary OAuth locking,
rotation, failed-save and store-pinning races remain unproven by this batch.

An owned offscreen Dart VM hot reload also succeeded. The real DCR/307/token
probe returned
`{"registrations":2,"codeExchanges":1,"basicOverridesResourceAuth":true,"resourceKeyPreserved":true}`.
The startup/non-replay probe still returned one startup refresh, two total
refresh attempts, zero tool calls, an error result and unchanged credentials.
The owned probe was explicitly stopped; no desktop app was reloaded.

The subsequent full sequence completed: **900 backend tests passed / 2
intentional skips**, workspace analysis had **0 errors/warnings** (132 infos),
and the deterministic context matrix passed **46/46**. Logs:
`happen-oauth-registration-{analysis,backend,e2e}.txt`; report:
`.local/context-contract/1793849256176171/report.json`. The prior full-run
interrupted-session listing failure did not recur; its cause is not claimed
fixed by the unrelated OAuth changes.

No OpenCode MCP-auth implementation or tests remain. `packages/opencode/` is
still a model provider; it is unrelated to MCP's reference implementation.

### Credential transaction matrix — applicability

`test/mcp_oauth_credentials_test.dart` ports these real-file boundaries, with
staged verification recorded below. No public guard API,
backend selector, keyring or aggregate-store substitute was added just for tests.

| Codex family / cases | Happen boundary |
| --- | --- |
| `persistor_tests::{login_and_logout_follow_the_completed_refresh,concurrent_refreshes_call_provider_once_and_carry_omitted_fields}` | Same owner, distinct owners, another isolate and another process; login/logout follow durable refresh. Actual contention/provider/file observations gate the races |
| `fresh_preparation_skips_storage_and_refresh_lock` | Fresh pinned authority remains usable during another owner's guarded refresh |
| `coordinated_401_refresh_rereads_and_persists_before_retry` | Guarded reread, issuer/client/resource generation checks and durable publication. The startup/runtime owner retains Happen's stronger challenged-tool non-replay contract |
| `missing_authoritative_credentials_require_reauthorization`, `credential_store_tests::replacement_or_removal_does_not_acknowledge_a_new_runtime_snapshot` | Removal, changed client, changed issuer and missing issuer cannot authorize provider contact or overwrite credentials |
| `caller_cancellation_does_not_cancel_refresh_persistence` | Caller stops waiting while shared provider work finishes and persists |
| `failed_refresh_adopts_login_completed_during_request`, `failed_refresh_does_not_adopt_unbound_replacement_credentials` | Complete absolute/unknown-expiry and missing/changed-issuer vectors, expanded across malformed/rejected provider responses |
| `expired_refresh_failure_preserves_credentials_for_a_later_retry`, rejected-token/failed-retirement diagnostics | Malformed/transient failures preserve retryable grants; invalid-grant retirement stays local, never rewrites credentials or reuses a rejected token, and redacts corrupt-store/provider data |
| `credential_store_tests::save_publishes_only_persisted_credentials` | Successful/failed refresh and login saves use the actual rename boundary and an independently created destination-directory blocker. Unsaved provider tokens cannot become runtime authority |
| `pinned_read_failure_does_not_adopt_fallback_credentials`, resolved-keyring-read-error adaptation | The selected file may fail to read without publishing an empty/new snapshot; no other alias/backend is consulted |
| `streamable_http_oauth_store_pinning::auto_store_remains_pinned_across_session_recovery` | Real legacy HTTP session expiry with missing/directory/symlink authority and a live stale alternate file. Safe cached authority or an error is permitted, never stale/anonymous fallback |
| `provider_timeout_releases_lock_and_preserves_durable_credentials`, `coordinated_provider_timeout_excludes_lock_wait` | Real fixed 20-second provider deadline and a longer competing transaction, not a test-only timeout knob or injected HTTP adapter |
| `store_lock_tests::store_lock_is_released_when_holder_process_exits`, `refresh_lock_tests::acquisition_times_out_without_stealing` | A test-owned real process death/suspension holds the actual transaction. Timeout cannot steal a live holder; another owner reacquires after release. Suspension is Unix-only |
| `file_credentials_keep_repeated_local_prefixes_isolated`, different-server update preservation | Complete name/full-URL keys and concurrent distinct-file refreshes, without aggregate JSON storage |
| `storage_roundtrip_preserves_absolute_and_unknown_expiry` | Existing runtime unexpired/unknown-expiry cases own exact byte preservation/startup reuse; no duplicate normalized-credential API is invented |

Internal `CredentialStore` guard-required mutations and aggregate retirement
cancellation have no Happen caller/API; guarded login/refresh/logout, failed
publication and replacement preservation own their observable effects. Aggregate
reader/writer lock mechanics are absent because Happen atomically replaces
separate credential files. Actual fresh readers and simultaneous different-file
writers are exercised instead. Keyring migration, Secrets/Direct selection,
fallback policy and keyring-specific retirement scopes are not Happen features.
Codex's OTel metric names/backend labels are not copied; corrupt credential and
provider diagnostics remain subject to Happen's real trace redaction contract.

### Credential transaction repair evidence

The runnable 40-case baseline was **28 passed / 12 failed**:
`happen-mcp-oauth-credentials-runnable-baseline.txt`. It retains actual
WouldBlock contention diagnostics through the existing trace channel; that
diagnostic instrumentation preceded functional repairs. The preliminary command
had an incorrect test import and is not product-failure evidence. The live-holder
test correctly reached the outer safety timeout because acquisition itself had
no bound; the fixture's additional timeout-on-teardown diagnostic was then
suppressed without changing the lock/deadline assertion.

The failures exposed same-process owner/isolate lock bypass, login/logout
overtaking admitted refresh, same-owner logout cancelling refresh persistence,
changed client-ID adoption, failure to adopt independently completed bound
logins, cached snapshot loss after a read failure, and an unbounded lock wait.
All original 40 cases pass after repair:
`happen-mcp-oauth-credentials-first.txt` (**40 passed**).

Unix locking now uses descriptor-owned `flock`, not Dart's process-scoped
`fcntl` file lock. Native descriptors are private, no-follow and close-on-exec;
Windows retains its handle-scoped `FileLock`. Acquisition alone is bounded at
60 seconds; provider deadlines begin after admission, and process death releases
the kernel lock. No lock is stolen or removed while another owner holds it.
The `ffi` dependency was already present in the workspace; offline resolution
made no lockfile/version change.

Credential reads no longer temporarily clear live authority. Guarded rereads
validate the expected client/issuer/resource generation before refresh; only
successful persistence or an independently completed, usable, bound replacement
can publish a new runtime snapshot. Failed saves and unbound/corrupt replacements
remain untouched. Caller cancellation only stops waiting; logout queues behind
the admitted refresh before retiring the owner and deleting its credential.

A further retained regression exposed byte-order-sensitive generation checks:
reformatting the same JSON made a rejected refresh return `old-access` as if a
new login had completed (`happen-mcp-oauth-credential-format-baseline.txt`).
Generation comparison now uses semantic JSON equality, not encoded key order.
The final **41-case rerun passed** in `happen-mcp-oauth-credentials-repaired.txt`.
The separate formatting/non-replay run also passed all three cases in
`happen-mcp-oauth-credentials-non-replay.txt`.

An owned offscreen VM hot reload succeeded and the real concurrent-owner probe
returned
`{"refreshCalls":1,"bothUsePersistedToken":true,"refreshTokenPreserved":true,"scopePreserved":true}`.
All owned probe processes were explicitly stopped. Expanded MCP siblings
passed **335 tests / 1 scope skip** in
`happen-mcp-oauth-credentials-siblings.txt`; that staged run predates the extra
formatting regression. The sequential check then stopped at strict analysis:
two indexing type errors and one inference warning in the new semantic comparer
(`happen-oauth-credentials-analysis.txt`). Its `Iterable<int>` type is now
explicit; repaired workspace analysis has **0 errors/warnings** (143 infos), and
all **3** formatting/non-replay cases pass in
`happen-mcp-oauth-credentials-non-replay-final.txt`. Evidence:
`happen-oauth-credentials-analysis-repaired.txt`. The final siblings/backend/E2E
sequence is backgrounded in `happen-mcp-oauth-credentials-final-siblings.txt`
and `happen-oauth-credentials-{backend,e2e}.txt`. No failed analyzer result is
treated as green. The final-source rerun completed: **336 MCP siblings / 1
scope skip**, **941 backend tests / 2 intentional skips**, and **46/46** context
cases. Evidence: the final-siblings/backend/E2E logs above and
`.local/context-contract/1793851664562612/report.json`. These results do not
establish the still-open stdio/Events/native/storage/whole-workflow contracts.

## Stdio, resources and shared ownership

| Upstream family / case | State / adaptation |
| --- | --- |
| `codex-mcp/src/connection_pool_tests.rs::shared_startup_survives_first_chat_cancellation_and_rejects_released_bindings` | `test/mcp_pool_test.dart`: first waiter cancellation does not restart shared startup; removed bindings cancel their calls |
| `new_chat_relists_tools_without_invalidating_or_waiting_for_existing_calls` | New scopes discover catalogs without waiting on another call; alias catalog revisions remain isolated |
| `releasing_lease_cancels_pending_call_before_release`, drop/timed-out lease cases | Adapted to config binding retirement, not private per-chat lease RPCs. Final ownership reaps the process; client disconnect alone does not release it |
| Startup callback authority / connection-owner account key / stateless negotiation cases | No connector account authority or Codex lease extension. Ordinary OAuth belongs to the configured URL; legacy stdio also shares physically |
| Happen executable-generation adaptation | Global-first and local-first reload ports observe predecessor liveness from the independent child. Every equivalent binding retires before replacement starts |
| `app-server/tests/suite/v2/mcp_server_status.rs::mcp_server_status_list_uses_thread_project_local_config` | Both stdio/URL ports use saved-thread cwd without running a turn; threadless inventory remains global |
| `config/src/{merge,loader/mod}.rs`, `core/src/config/config_loader_tests.rs` | Root-to-cwd layers, recursive tables, replacement arrays/scalars, declaring-file-relative cwd, invalid-layer retention and removed-layer inheritance have ports |
| Project trust / symlink-worktree discovery | Explicit Codex trust-policy parity and full root-discovery matrix remain pending; Happen has no copied Codex trust schema |
| `mcp_2026_stdio_discovery.rs::local_stdio_inherits_ca_certificate_variables` | All five local vectors ported: inherited paths resolve against the host cwd before launching in another cwd; explicit CA overrides preserve their literal paths and replace casing variants |
| `modern_local_and_executor_stdio_discover_metadata_identity_and_catalogs` | Full local metadata identity/tools/resources/templates round trip ported. Remote-executor transport is absent and is not claimed |
| `legacy_stdio_preserves_existing_protocol_marker_environment` | Both local literal-env marker vectors ported, including an unknown marker. Happen preserves rather than interprets Codex's marker |
| `process_group_cleanup.rs` | Both cases ported in `test/mcp_stdio_cleanup_test.dart`: final manager disposal during an uninitialized wrapper's startup, and explicit initialized shutdown with an independently observed admitted call. Fixture-owned descendants must exit, not just the direct child |
| `stdio_descriptor_boundary.rs` | Complete sentinel oracle, absolute/relative/executable-text fallback launches, descendant probes, exact stdio output, parent FD preservation and missing-interpreter exec-error ports in `test/mcp_stdio_cleanup_test.dart` |
| `stdio_stderr_cleanup.rs` | Both shutdown and final configuration-owner disposal ports: queued native stderr write while the owner isolate cannot run its reader, FD return to baseline while an independently escaped setsid child remains alive, and retained diagnostics |
| `stdio_message_limits.rs`, `mcp_2026_message_limits.rs` | Local modern rejection / legacy uncapped-line compatibility and the complete HTTP matrix are ported. Remote-executor and Windows console/job-object vectors are not proven by local macOS tests |
| `resources.rs::rmcp_client_can_list_and_read_resources` | HTTP JSON/SSE and modern/legacy stdio listings, full resource/template metadata and read payloads ported |
| `rmcp_client_preserves_each_resource_error` | Both distinct missing-resource messages/codes/data ported over HTTP JSON/SSE and modern/legacy stdio on the same connection |
| `streamable_http_user_agent.rs` | Ported; explicit user agent is preserved and the default uses the MCP client identity |
| `streamable_http_remote.rs`, `foreign_stdio_cwd.rs` | Codex remote exec transport is absent; local URL/stdio contracts must not be counted as remote-executor proof |
| `mcp_2026_mrtr.rs`, `mcp_2026_stdio.rs`, native verification tests | Full ordinary request-continuation/elicitation support remains unported. Happen currently advertises no elicitation/sampling/roots capabilities and must reject unadvertised input, not fake UI responses |

Stdio discovery timeout now fails without attempting `initialize` on the same
process. Only recognized correlated legacy evidence authorizes that downgrade;
Happen does not implement Codex's separate unmarked-helper process-restart mode.

### Local environment / catalog completion evidence

`test/mcp_stdio_contract_test.dart` runs a separate real Dart client with a
controlled environment and cwd, then inspects its independently launched MCP
child. The baseline passed five cases and failed three: SSL/Requests CA paths
were missing, default variables were absent and host-only credentials leaked
through explicit inheritance/overrides. The fix shares the effective environment
with stdio pool identity. All eleven upstream CA names are supported; empty
inherited CA values are omitted. Happen's `inherit_env` remains its config field.

Resource ports retain the complete upstream resource/template metadata, text
contents and both missing-resource errors. Additional prompt list/get/error
round trips exercise the existing public request path over modern and legacy
stdio. These are not elicitation/continuation support claims.

Focused stdio/wire/pooling/inventory run: **146 passed / 1 explicit scope skip**.
Evidence: `happen-mcp-stdio-env-baseline.txt` and
`happen-mcp-stdio-env-catalogs.txt` in the approved tool-log directory. Windows
and non-UTF-8 OS-string environment vectors are not proven by these Dart/macOS
ports; Codex remote-executor cases remain outside Happen's transport surface.

### Unix stdio cleanup matrix

The complete three upstream files were ported before functional repair. Six
owner-boundary tests retain all eight vectors (including the three descriptor
launch variants). Happen's explicit manager/config retirement replaces Rust
`Drop`; no fake GC, test-only launch hook or private cleanup API is introduced.
All peers and descendants are real Dart processes, with native calls only for
the independent descriptor oracle, process IDs/groups and queued stderr write.

Qualified pre-repair baseline: **2 passed / 4 failed**,
`happen-mcp-stdio-cleanup-qualified-baseline.txt`. The inherited-FD oracle first
proves that a descriptor reserved with `F_DUPFD >= 200` reaches the same Dart
executable when launched without MCP policy. All three actual MCP launches
then run before the result is asserted; cleanup must preserve the original
parent descriptor. The native oracle runs before its owner's first Dart
`Process.start` to avoid Dart's process-wide `waitpid(-1)` reaper. Raw directory
entry enumeration, not Dart's per-entry stat, measures devfs FDs. The initial
fixture qualification failures remain in `happen-mcp-stdio-cleanup-{baseline,settled-baseline}.txt`
and are not counted as product failures.

The qualified baseline exposes a wrapper disposal hang on descendant-held
stdout, an inheritable descriptor leaking into both the server and descendant,
and queued stderr diagnostics discarded on both teardown paths. In-flight
direct shutdown and missing-interpreter error reporting already pass. Every
fixture is independently bounded; failed-run cleanup signals only fixture-file
PIDs individually, never a parent/test process group. Windows job-object and
remote-executor behavior is outside these local Unix ports.

The Unix repair uses `posix_spawn` to establish a child-owned group and explicit
stdio descriptors atomically. Darwin uses close-on-exec-default, Linux closes
all non-stdio descriptors in spawn actions, and executable-text shell fallback
retains those same policies. Public Dart socket APIs adopt the owned Unix
socketpair ends via SCM_RIGHTS; no Dart VM fork, detached double-fork ownership,
SDK-private descriptor API or extra executable is required. Queued stderr is a
bounded local diagnostic stream, never an MCP response or history/telemetry
payload, and teardown has a bounded drain. Verification is recorded separately;
writing this implementation alone is not a completed cleanup claim.

All original six tests passed in `happen-mcp-stdio-cleanup-second.txt`, after the
first repair attempt exposed the SDK's unsupported `ResourceHandle.toSocket`
conversion. The supported `toRawSocket` path now supplies bounded reads and
backpressured writes. Pooling/environment/catalog/reload siblings then passed
**45 tests** in `happen-mcp-stdio-cleanup-siblings.txt`. Strict analysis still
found six dropped close futures and three dynamic fixture-ID type errors
(`happen-mcp-stdio-cleanup-analysis.txt`); closes are now awaited and IDs typed.

Four additional native-boundary regressions each failed before their repair:
NUL in command, argument, cwd or environment silently truncated and actually
launched a child (`happen-mcp-stdio-native-nul-baseline.txt`). The launcher now
rejects these before allocating or executing, preserving the public Dart
process-string boundary. The complete **10-case rerun passes** in
`happen-mcp-stdio-cleanup-repaired.txt`. Repaired workspace analysis has **0
errors/warnings** (151 infos), `happen-mcp-stdio-cleanup-analysis-repaired.txt`.

An owned offscreen backend probe was hot-reloaded after the final source edit
and returned
`{"sharedProcess":true,"isolatedGroup":true,"pendingCallInterrupted":true,"wrapperDescendantExited":true,"stderrFdRestored":true,"queuedStderrLogged":true,"escapedAliveAtClose":true}`.
It was explicitly stopped, and only its fixture-owned escaped PID was cleaned
up. No desktop app was reloaded. The final expanded MCP/full-backend/context
sequence is backgrounded in `happen-mcp-stdio-cleanup-{final-siblings,backend,e2e}.txt`;
The completed sequence passed **346 expanded MCP siblings / 1 scope skip**,
**951 backend tests / 2 intentional skips**, and **46/46** deterministic context
cases. Context report:
`.local/context-contract/1793872907311203/report.json`. This snapshot predates
the Events restart matrix. The root test
package now declares the already-resolved `ffi` dev dependency; the only
lockfile change is its direct-dev annotation, not a version/hash change.
`third_party/http/` remains untouched.

## Events

`rmcp-client/tests/mcp_events.rs` uses a plugin runtime, which is excluded.
Happen's independent Events implementation lives in `packages/mcp/` and follows
the Events proposal, not that plugin host. `test/mcp_test.dart` owns push/poll/
webhook transport behavior; `packages/server/test/thread_unsubscribe_test.dart`
owns server-hosted admission, duplicate/invalid/control handling, client
disconnect, unloading/wake-up and archive cleanup.

Subscription and cursor restoration after **server-process restart** remains
unimplemented. In-memory reconnect and thread unloading are not substitutes for
that durability requirement.

The next matrix, `test/mcp_events_restart_test.dart`, uses separately launched
server processes over real WebSockets/HTTP and the actual per-session SQLite
files. It covers all three modes across graceful stop and process kill, saved
project-local server configuration, stable local IDs/cursors/webhook signing
material, duplicate replay, durable unsubscribe/archive, and acknowledged input
left pending behind an interrupted turn. Independent SQLite fault triggers and
physical WAL commit markers require inbox/receipt/cursor rollback together,
one accepted admission commit and zero unchanged-duplicate commits. Its baseline
is isolated from concurrent analysis; these are test contracts, not yet a
restoration-completion claim.
