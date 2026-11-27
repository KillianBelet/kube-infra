#!/usr/bin/env bash
# Tests de dex (#41). Voir docs/dex.md § 5.
#
#   ./platform/dex/test-dex.sh
#   DEX_URL=https://dex.<IP>.sslip.io ./platform/dex/test-dex.sh
#
# Connexion du compte demo sur le client kubernetes, en passant par Keycloak.
# Secrets lus dans le cluster, sauf si CLIENT_SECRET et TEST_PASSWORD sont définis.
set -euo pipefail

URL="${DEX_URL:-https://dex.127.0.0.1.sslip.io}"
URL="${URL%/}"
CLIENT_ID=kubernetes
REDIRECT_URI=http://localhost:8000
TEST_USER="${TEST_USER:-demo}"
EXPECTED_GROUP="${EXPECTED_GROUP:-kube-viewers}"

PY=""
for p in python3 python; do
  if "$p" -c '' >/dev/null 2>&1; then PY="$p"; break; fi
done
[ -n "$PY" ] || { echo "python3 introuvable" >&2; exit 1; }

CURL=(curl -sS -m 20)
if [ "${DEX_INSECURE:-}" = 1 ] || [[ "$URL" == *127.0.0.1* ]]; then CURL+=(-k); fi

secret() { kubectl -n "$1" get secret "$2" -o "jsonpath={.data.$3}" | base64 -d; }
[ -n "${CLIENT_SECRET:-}" ] || CLIENT_SECRET="$(secret dex dex-secrets KUBERNETES_CLIENT_SECRET)"
[ -n "${TEST_PASSWORD:-}" ] || TEST_PASSWORD="$(secret keycloak keycloak-realm-secrets REALM_SECRET_DEMO_PASSWORD)"

fails=0
ok()   { printf '  OK    %s\n' "$1"; }
ko()   { printf '  ÉCHEC %s\n' "$1"; fails=$((fails + 1)); }
check() { if [ "$2" = "$3" ]; then ok "$1"; else ko "$1 (attendu : $3, obtenu : $2)"; fi; }
json() { "$PY" -c "import sys,json; d=json.load(sys.stdin); print($1)"; }
stop() { ko "$1"; echo; echo "$fails test(s) en échec."; exit 1; }

jar="$(mktemp)"
trap 'rm -f "$jar"' EXIT
SESSION=("${CURL[@]}" -b "$jar" -c "$jar")

echo "dex : $URL"

issuer="$("${CURL[@]}" --fail-with-body "$URL/.well-known/openid-configuration" | json "d['issuer']")"
check "issuer HTTPS de dex" "$issuer" "$URL"

state="t41-$RANDOM"
page="$("${SESSION[@]}" -L -w '\n%{url_effective}' \
  "$URL/auth?client_id=$CLIENT_ID&redirect_uri=$REDIRECT_URI&response_type=code&scope=openid+profile+email+groups&state=$state")"
login_url="${page##*$'\n'}"
case "$login_url" in
  */realms/kube/protocol/openid-connect/auth*) ok "redirection vers Keycloak" ;;
  *) ko "redirection vers Keycloak (arrivé sur $login_url)" ;;
esac

action="$(printf '%s' "$page" | grep -o 'id="kc-form-login"[^>]*' | grep -o 'action="[^"]*"' | head -1 |
  sed 's/^action="//; s/"$//; s/&amp;/\&/g')"
[ -n "$action" ] || stop "formulaire de login Keycloak introuvable"

loc="$("${SESSION[@]}" -o /dev/null -w '%{redirect_url}' \
  --data-urlencode "username=$TEST_USER" --data-urlencode "password=$TEST_PASSWORD" "$action")"
for _ in 1 2 3 4 5; do
  case "$loc" in "$REDIRECT_URI"* | "") break ;; esac
  loc="$("${SESSION[@]}" -o /dev/null -w '%{redirect_url}' "$loc")"
done
case "$loc" in
  "$REDIRECT_URI"*) ok "retour sur le client après le login de $TEST_USER" ;;
  *) stop "pas de retour sur $REDIRECT_URI (${loc:-pas de redirection : mauvais mot de passe ?})" ;;
esac

code="$(printf '%s' "$loc" | "$PY" -c "
import sys, urllib.parse as u
q = u.parse_qs(u.urlparse(sys.stdin.read()).query)
print(q['code'][0] if q.get('state') == ['$state'] and 'code' in q else '')")"
[ -n "$code" ] || stop "code absent ou state différent"

id_token="$("${CURL[@]}" --fail-with-body -u "$CLIENT_ID:$CLIENT_SECRET" -d grant_type=authorization_code \
  --data-urlencode "code=$code" --data-urlencode "redirect_uri=$REDIRECT_URI" "$URL/token" | json "d['id_token']")"
claims="$(printf '%s' "$id_token" | "$PY" -c "
import sys, json, base64
p = sys.stdin.read().split('.')[1]
print(json.dumps(json.loads(base64.urlsafe_b64decode(p + '=' * (-len(p) % 4)))))")"

check "iss de l'ID token" "$(echo "$claims" | json "d['iss']")" "$URL"
check "aud de l'ID token" "$(echo "$claims" | json "d['aud']")" "$CLIENT_ID"
check "claim groups" "$(echo "$claims" | json "','.join(d.get('groups', ['<absent>']))")" "$EXPECTED_GROUP"
email="$(echo "$claims" | json "d.get('email', '')")"
case "$email" in
  *@*) ok "claim email : $email" ;;
  *) ko "claim email absent" ;;
esac

echo
if [ "$fails" -eq 0 ]; then echo "Tous les tests passent."; else echo "$fails test(s) en échec."; exit 1; fi
