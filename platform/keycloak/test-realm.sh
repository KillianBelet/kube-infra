#!/usr/bin/env bash
# Tests du realm kube (#40). Voir docs/keycloak.md § 5.
#
#   ./platform/keycloak/test-realm.sh
#   KEYCLOAK_URL=https://keycloak.<IP>.sslip.io ./platform/keycloak/test-realm.sh
#
# Compte admin lu dans le Secret keycloak-admin, sauf si KEYCLOAK_ADMIN_USER et
# KEYCLOAK_ADMIN_PASSWORD sont définis.
set -euo pipefail

URL="${KEYCLOAK_URL:-https://keycloak.127.0.0.1.sslip.io}"
URL="${URL%/}"
REALM=kube
TEST_USER="${TEST_USER:-demo}"
EXPECTED_GROUP="${EXPECTED_GROUP:-kube-viewers}"

PY=""
for p in python3 python; do
  if "$p" -c '' >/dev/null 2>&1; then PY="$p"; break; fi
done
[ -n "$PY" ] || { echo "python3 introuvable" >&2; exit 1; }

CURL=(curl -sS --fail-with-body -m 20)
if [ "${KEYCLOAK_INSECURE:-}" = 1 ] || [[ "$URL" == *127.0.0.1* ]]; then CURL+=(-k); fi

if [ -z "${KEYCLOAK_ADMIN_USER:-}" ] || [ -z "${KEYCLOAK_ADMIN_PASSWORD:-}" ]; then
  secret() { kubectl -n keycloak get secret keycloak-admin -o "jsonpath={.data.$1}" | base64 -d; }
  KEYCLOAK_ADMIN_USER="$(secret KC_BOOTSTRAP_ADMIN_USERNAME)"
  KEYCLOAK_ADMIN_PASSWORD="$(secret KC_BOOTSTRAP_ADMIN_PASSWORD)"
fi

fails=0
ok()   { printf '  OK    %s\n' "$1"; }
ko()   { printf '  ÉCHEC %s\n' "$1"; fails=$((fails + 1)); }
check() { if [ "$2" = "$3" ]; then ok "$1"; else ko "$1 (attendu : $3, obtenu : $2)"; fi; }
json() { "$PY" -c "import sys,json; d=json.load(sys.stdin); print($1)"; }

echo "Keycloak : $URL (realm $REALM)"

issuer="$("${CURL[@]}" "$URL/realms/$REALM/.well-known/openid-configuration" | json "d['issuer']")"
check "issuer HTTPS du realm" "$issuer" "$URL/realms/$REALM"

TOKEN="$("${CURL[@]}" -d grant_type=password -d client_id=admin-cli \
  --data-urlencode "username=$KEYCLOAK_ADMIN_USER" --data-urlencode "password=$KEYCLOAK_ADMIN_PASSWORD" \
  "$URL/realms/master/protocol/openid-connect/token" | json "d['access_token']")"
api() { "${CURL[@]}" -H "Authorization: Bearer $TOKEN" "$URL/admin/realms/$REALM$1"; }
ok "connexion admin (realm master)"

groups="$(api "/groups" | json "','.join(sorted(g['name'] for g in d))")"
check "groupes" "$groups" "kube-admins,kube-devs,kube-viewers"

client="$(api "/clients?clientId=dex")"
cid="$(echo "$client" | json "d[0]['id']")"
check "client dex confidentiel" "$(echo "$client" | json "d[0]['publicClient']")" "False"
redirect="$(echo "$client" | json "d[0]['redirectUris'][0]")"
case "$redirect" in
  'https://dex.${'*) ko "redirect URI de dex : placeholder non résolu ($redirect)" ;;
  https://dex.*/callback) ok "redirect URI de dex : $redirect" ;;
  *) ko "redirect URI de dex inattendue : $redirect" ;;
esac
dex_secret="$(api "/clients/$cid/client-secret" | json "d.get('value','')")"
case "$dex_secret" in
  '' | '${'*) ko "secret du client dex non résolu" ;;
  *) ok "secret du client dex résolu (${#dex_secret} caractères)" ;;
esac
mapper="$(api "/clients/$cid/protocol-mappers/models" |
  json "[m['config'].get('full.path') for m in d if m['protocolMapper']=='oidc-group-membership-mapper' and m['config'].get('claim.name')=='groups']")"
check "mapper groups (chemin complet désactivé)" "$mapper" "['false']"

uid="$(api "/users?username=$TEST_USER&exact=true" | json "d[0]['id']")"
for kind in id access; do
  claim="$(api "/clients/$cid/evaluate-scopes/generate-example-$kind-token?scope=openid&userId=$uid" |
    json "','.join(d.get('groups', ['<absent>']))")"
  check "claim groups de l'$kind token de $TEST_USER" "$claim" "$EXPECTED_GROUP"
done

echo
if [ "$fails" -eq 0 ]; then echo "Tous les tests passent."; else echo "$fails test(s) en échec."; exit 1; fi
