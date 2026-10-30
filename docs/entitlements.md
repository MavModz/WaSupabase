# Plans, limits and entitlements: operator runbook

Entitlements are **off by default**. A self-hosted deployment that never turns them on
behaves exactly as if this feature did not exist: no limits, no plan errors, no extra
queries. This page is for the operator of a deployment that turns them on.

The customer-facing plan page, banners and upgrade prompts are not in this release
(Phase 2b). Until they ship, customers see limit errors but no usage page.

## The switch has two halves

| Half | Where | What it controls |
| --- | --- | --- |
| App | env `ENTITLEMENTS_ENABLED=true` | Every gate in the app code. Only the exact value `true` counts. |
| Database | `platform_settings.entitlements_enabled` | The enforcement triggers (enabled or disabled). |

Enforcement needs **both**. If they disagree:

- env on, DB off: the app enforces nothing and logs `entitlements.switch_mismatch` on each
  lookup.
- env off, DB on: the triggers still enforce, so limits hold and writes fail with plan
  errors. Don't leave a deployment in this state.

### Turning it on

Off-peak, because enabling the triggers takes a short lock on each table:

1. Set `ENTITLEMENTS_OPERATOR_SECRET` and redeploy.
2. Set the DB half (`set_enabled`, below). The first time, this is **go-live**: accounts
   that exist now stay on `legacy_beta`, and accounts created from now on start a trial.
3. Set `ENTITLEMENTS_ENABLED=true` and redeploy.
4. Run the inbound check below.

Turning it off is the same in reverse and deletes nothing. Plans, states and usage are as
you left them when it comes back on. The go-live time never moves.

### Check after turning it on

An inbound message must never be lost to a plan limit. The webhook marks its own requests
with an `x-wacrm-inbound` header, so that contacts it creates are exempt from the limit.
If your gateway strips that header, the webhook falls back to an exempt database function
and logs `webhook.inbound_exemption_header_lost`.

Send a message from an unknown number to an account at its contact limit, then confirm the
message is stored. If that log line appears, the fallback worked but the header isn't
reaching Postgres, so look at your gateway.

## Operator endpoint

`POST /api/internal/entitlements`, with header `x-operator-secret:
$ENTITLEMENTS_OPERATOR_SECRET`. It answers 503 until the secret is set. Every call needs
`op` and `actor` (who is doing this; it goes in the audit log), and takes an optional
`reason`.

| `op` | Other fields | What it does |
| --- | --- | --- |
| `status` | `account_id` | Current plan, state and limits |
| `usage` | `account_id` | Current usage per resource |
| `preview` | `account_id`, `plan` | Usage against a target plan, and seats to free |
| `set_plan` | `account_id`, `plan`, `keep?` | Change plan **now** and apply its limits |
| `schedule_change` | `account_id`, `plan`, `at?`, `keep?` | Downgrade at `at` (default: period end). Applies at once for an upgrade, or from `trial` or `legacy_beta` |
| `cancel_change` | `account_id` | Cancel a scheduled change |
| `set_state` | `account_id`, `state` | `trialing`, `active`, `past_due`, `restricted`, `locked` |
| `set_trial_end` | `account_id`, `trial_ends_at` | Set or extend a trial. A later date re-opens an ended trial |
| `set_override` | `account_id`, `overrides` | Per-account limits, for example `{"seats_max":120}`. `null` removes one |
| `set_enabled` | `enabled` | The DB half of the switch |

`keep` lists what stays active after a downgrade, for example
`{"automations":["<uuid>"],"flows":[],"api_keys":[],"webhook_endpoints":[]}`. A list means
"keep exactly these, up to the limit". A missing list means the default rule.

```bash
curl -X POST "$APP_URL/api/internal/entitlements" \
  -H "x-operator-secret: $ENTITLEMENTS_OPERATOR_SECRET" \
  -H 'content-type: application/json' \
  -d '{"op":"set_enabled","enabled":true,"actor":"you@example.com","reason":"go live"}'
```

The response has `env_enabled`, so a mismatch between the two halves is visible at once.

Each change writes one row to `entitlement_audit_log` in the same transaction: actor,
account, old value, new value, time. The table is service-role only.

To change a plan's limit for everyone, update its row in `plans`; a re-run of the
migrations won't overwrite it. To add a currency, insert rows in `currencies` and
`plan_prices`.

## What happens when

| Event | Effect |
| --- | --- |
| Trial ends | `locked`. Inbound is still stored; agents can't reply. Extend it with `set_trial_end` |
| Number already connected to another account | That account's trial ends on connection, reason `trial_number_reused` |
| You set `past_due` | Full access for 7 days, then `restricted` for 14, then `locked` (durations in `platform_settings`) |
| Downgrade takes effect | Excess automations and webhooks off, flows back to draft with active runs cancelled, excess API keys suspended (not revoked), AI bot off with a handoff note. **Nothing is deleted** |
| Upgrade | Applies at once. Suspended keys come back. Automations and flows that were switched off stay off, as after a manual switch-off |
| Broadcast runs out of allowance | Unsent recipients stay pending, `broadcasts.paused_reason = 'plan_limit'`. Resume sends them later |
| Inbound media above 110% of storage | Message stored, media served through the Meta proxy (Meta keeps it about 30 days). Upload limits ship in Phase 5 |

State changes apply on the next request, even if the cron isn't running: state is worked
out when it is read. The automations cron (`GET /api/automations/cron`) records those
changes with audit rows and applies due downgrades, so a downgrade's **deactivations wait
for the cron**, while its limits don't.

## Known limits

- **Don't open hosted signup before payments ship** (N-12). A trial that ends locks the
  account, and only you can extend it.
- A send that crashes between reserving and refunding can over-count a broadcast
  allowance by up to one reservation, which is 10 recipients on every path.
- With the switch on, the bucket for a key's API rate comes from its plan. On the default
  in-memory limiter that bucket is per process; set `RATE_LIMIT_BACKEND=postgres` so the
  plan rate holds across instances.
