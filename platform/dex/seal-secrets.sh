#!/usr/bin/env bash
# Génère et scelle les secrets de dex (#41). Voir docs/dex.md § 3.
#
#   ./platform/dex/seal-secrets.sh
#
# Seules les clés absentes sont créées. Pour forcer une valeur, la passer en variable
# d'environnement du même nom que la clé :
#   GRAFANA_CLIENT_SECRET=... ./platform/dex/seal-secrets.sh
#
# KEYCLOAK_CLIENT_SECRET est aussi le secret du client dex dans Keycloak : quand il est
# écrit ici, il est rescellé dans platform/keycloak (REALM_SECRET_DEX_CLIENT).
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$DIR/../.." && pwd)"
CERT="${KUBESEAL_CERT:-$ROOT/platform/sealed-secrets/team-cert.crt}"
FILE="$DIR/config/templates/dex-secrets.sealed.yaml"
NAME=dex-secrets
NAMESPACE=dex
KEYS=(KEYCLOAK_CLIENT_SECRET KUBERNETES_CLIENT_SECRET ARGOCD_CLIENT_SECRET GRAFANA_CLIENT_SECRET HEADLAMP_CLIENT_SECRET)

for bin in kubectl kubeseal openssl; do
  command -v "$bin" >/dev/null || { echo "$bin introuvable" >&2; exit 1; }
done
[ -f "$CERT" ] || { echo "Certificat introuvable : $CERT" >&2; exit 1; }

gen() { openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | head -c 32; }

has_key() { [ -f "$1" ] && awk -v k="$2" '
  /^  encryptedData:/ { in_data = 1; next }
  in_data && /^  [^ ]/ { in_data = 0 }
  in_data && $1 == k ":" { found = 1 }
  END { exit !found }' "$1"; }

literals=()
shown=()
keycloak_secret=""
for key in "${KEYS[@]}"; do
  if [ -n "${!key:-}" ]; then
    value="${!key}"
  elif has_key "$FILE" "$key"; then
    continue
  else
    value="$(gen)"
  fi
  literals+=("--from-literal=$key=$value")
  shown+=("$key : $value")
  if [ "$key" = KEYCLOAK_CLIENT_SECRET ]; then keycloak_secret="$value"; fi
done

if [ "${#literals[@]}" -eq 0 ]; then
  echo "Inchangé : ${FILE#"$ROOT"/}"
  exit 0
fi

secret="$(kubectl create secret generic "$NAME" --namespace "$NAMESPACE" "${literals[@]}" --dry-run=client -o yaml)"
if [ -f "$FILE" ]; then
  printf '%s\n' "$secret" | kubeseal --cert "$CERT" --format yaml --merge-into "$FILE"
else
  # créé avant le Deployment de dex
  printf '%s\n' "$secret" | kubeseal --cert "$CERT" --format yaml |
    awk '{ print } /^metadata:$/ { print "  annotations:"; print "    argocd.argoproj.io/sync-wave: \"-1\"" }' > "$FILE"
fi
echo "Écrit   : ${FILE#"$ROOT"/} (${#literals[@]} clé(s))"

if [ -n "$keycloak_secret" ]; then
  REALM_SECRET_DEX_CLIENT="$keycloak_secret" "$ROOT/platform/keycloak/seal-secrets.sh"
fi

echo
echo "Nouvelles valeurs (affichées une seule fois, ne pas les mettre dans Git) :"
printf '  %s\n' "${shown[@]}"
