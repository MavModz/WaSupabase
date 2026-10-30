#!/bin/sh
# Entitlements race check (REQ-X4). pgTAP runs on one session, so it can't
# show that parallel requests respect a limit; this runs real parallel
# connections and asserts the outcome.
#
#   DATABASE_URL=postgresql://postgres:postgres@127.0.0.1:54322/postgres \
#     sh supabase/ci/entitlements-concurrency.sh
#
# LOCAL / CI DATABASES ONLY. It commits fixtures and flips the switch, then
# puts both back. Never point it at a shared or production database.
set -u
URL="${DATABASE_URL:-postgresql://postgres:postgres@127.0.0.1:54322/postgres}"
PSQL="${PSQL:-psql}"
TMP="$(mktemp -d)"
U='43000000-0000-4000-8000-00000000000a'
q() { "$PSQL" "$URL" -X -q -t -A -v ON_ERROR_STOP=1 "$@"; }

cleanup() {
  q -c "DELETE FROM public.accounts WHERE owner_user_id = '$U'" \
    -c "DELETE FROM public.profiles WHERE user_id = '$U'" \
    -c "DELETE FROM auth.users WHERE id = '$U'" \
    -c "SELECT public.entitlements_set_enabled(false, 'ci-concurrency')" \
    -c "UPDATE public.platform_settings SET entitlements_first_enabled_at = NULL" \
    -c "DELETE FROM public.entitlement_audit_log WHERE actor = 'ci-concurrency'" >/dev/null 2>&1
  rm -rf "$TMP"
}
trap cleanup EXIT

q -c "INSERT INTO auth.users (instance_id, id, aud, role, email, raw_user_meta_data, created_at, updated_at)
      VALUES ('00000000-0000-0000-0000-000000000000', '$U', 'authenticated', 'authenticated', 'conc@example.test', '{\"full_name\":\"C\"}', now(), now())" >/dev/null || exit 1
ACCOUNT="$(q -c "SELECT account_id FROM public.profiles WHERE user_id = '$U'")"
[ -n "$ACCOUNT" ] || { echo "FAIL: no account was provisioned"; exit 1; }
q -c "SELECT public.entitlements_set_enabled(true, 'ci-concurrency')" \
  -c "SELECT public.ent_set_plan('$ACCOUNT', 'starter', 'ci-concurrency')" >/dev/null || exit 1

FAILED=0

# 1. One contact slot left, 5 parallel inserts: exactly 1 wins (AC of REQ-X4).
q -c "SELECT public.ent_set_override('$ACCOUNT', '{\"contacts_max\":1}'::jsonb, 'ci-concurrency')" >/dev/null || exit 1
for i in 1 2 3 4 5; do
  ( "$PSQL" "$URL" -X -q -c "INSERT INTO public.contacts (user_id, account_id, phone, name)
      VALUES ('$U', '$ACCOUNT', '1555300000$i', 'c$i')" >"$TMP/c$i.out" 2>&1; echo $? >"$TMP/c$i.rc" ) &
done
wait
WON=0; LIMITED=0
for i in 1 2 3 4 5; do
  [ "$(cat "$TMP/c$i.rc")" = "0" ] && WON=$((WON + 1))
  grep -q 'plan_limit_reached' "$TMP/c$i.out" && LIMITED=$((LIMITED + 1))
done
ROWS="$(q -c "SELECT count(*) FROM public.contacts WHERE account_id = '$ACCOUNT'")"
if [ "$WON" = "1" ] && [ "$LIMITED" = "4" ] && [ "$ROWS" = "1" ]; then
  echo "ok - contacts: 1 of 5 parallel inserts won, 4 got plan_limit_reached, 1 row exists"
else
  echo "FAIL - contacts: won=$WON limited=$LIMITED rows=$ROWS"; FAILED=1
fi

# 2. 50 recipients left, 5 parallel reservations of 40: exactly 50 granted (REQ-X5).
q -c "SELECT public.ent_set_override('$ACCOUNT', '{\"broadcast_recipients_per_period\":50}'::jsonb, 'ci-concurrency')" >/dev/null || exit 1
for i in 1 2 3 4 5; do
  ( q -c "SELECT granted FROM public.entitlement_consume('$ACCOUNT', 'broadcast_recipients', 40)" >"$TMP/g$i.out" 2>&1 ) &
done
wait
GRANTED=0
for i in 1 2 3 4 5; do GRANTED=$((GRANTED + $(cat "$TMP/g$i.out"))); done
USED="$(q -c "SELECT used FROM public.account_usage_counters WHERE account_id = '$ACCOUNT'")"
if [ "$GRANTED" = "50" ] && [ "$USED" = "50" ]; then
  echo "ok - broadcast metering: 5 parallel reservations of 40 granted exactly 50"
else
  echo "FAIL - broadcast metering: granted=$GRANTED used=$USED"; FAILED=1
fi

# 3. Seat maximum 2 with 1 member, 5 parallel invitations: exactly 1 wins.
q -c "SELECT public.ent_set_override('$ACCOUNT', '{\"seats_max\":2}'::jsonb, 'ci-concurrency')" >/dev/null || exit 1
for i in 1 2 3 4 5; do
  ( "$PSQL" "$URL" -X -q -c "INSERT INTO public.account_invitations (account_id, token_hash, role, expires_at)
      VALUES ('$ACCOUNT', 'conc-$i', 'agent', now() + interval '1 day')" >"$TMP/i$i.out" 2>&1; echo $? >"$TMP/i$i.rc" ) &
done
wait
WON=0
for i in 1 2 3 4 5; do [ "$(cat "$TMP/i$i.rc")" = "0" ] && WON=$((WON + 1)); done
if [ "$WON" = "1" ]; then
  echo "ok - seats: 1 of 5 parallel invitations won"
else
  echo "FAIL - seats: won=$WON"; FAILED=1
fi

exit "$FAILED"
