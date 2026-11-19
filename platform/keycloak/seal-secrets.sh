#!/usr/bin/env bash
# Génère et scelle les secrets de Keycloak. Voir docs/keycloak.md § 3.
#
#   ./platform/keycloak/seal-secrets.sh
#
# Seules les clés absentes sont créées. Pour forcer une valeur, la passer en variable
# d'environnement du même nom que la clé :
#   REALM_SECRET_DEX_CLIENT=... ./platform/keycloak/seal-secrets.sh
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$DIR/../.." && pwd)"
CERT="${KUBESEAL_CERT:-$ROOT/platform/sealed-secrets/team-cert.crt}"
REALM_FILE="$DIR/manifests/realm-kube.json"
NAMESPACE=keycloak

for bin in kubectl kubeseal openssl; do
  command -v "$bin" >/dev/null || { echo "$bin introuvable" >&2; exit 1; }
done
[ -f "$CERT" ] || { echo "Certificat introuvable : $CERT" >&2; exit 1; }

gen() { openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | head -c 24; }

has_key() { [ -f "$1" ] && awk -v k="$2" '
  /^  encryptedData:/ { in_data = 1; next }
  in_data && /^  [^ ]/ { in_data = 0 }
  in_data && $1 == k ":" { found = 1 }
  END { exit !found }' "$1"; }

SHOWN=()

# seal <fichier> <secret> <clé>=<variable>[=<défaut>] ...
seal() {
  local file="$1" name="$2"; shift 2
  local literals=() entry key var default value
  for entry in "$@"; do
    IFS='=' read -r key var default <<<"$entry"
    if [ -n "${!var:-}" ]; then
      value="${!var}"
    elif has_key "$file" "$key"; then
      continue
    else
      value="${default:-$(gen)}"
    fi
    literals+=("--from-literal=$key=$value")
    SHOWN+=("$name / $key : $value")
  done
  [ "${#literals[@]}" -gt 0 ] || { echo "Inchangé : ${file#"$ROOT"/}"; return; }

  local merge=()
  [ -f "$file" ] && merge=(--merge-into "$file")
  kubectl create secret generic "$name" --namespace "$NAMESPACE" "${literals[@]}" --dry-run=client -o yaml |
    if [ "${#merge[@]}" -gt 0 ]; then
      kubeseal --cert "$CERT" --format yaml "${merge[@]}"
    else
      kubeseal --cert "$CERT" --format yaml > "$file"
    fi
  echo "Écrit   : ${file#"$ROOT"/} (${#literals[@]} clé(s))"
}

seal "$DIR/db/keycloak-db-credentials.sealed.yaml" keycloak-db-credentials \
  "mysql-root-password=KEYCLOAK_DB_ROOT_PASSWORD" \
  "mysql-password=KEYCLOAK_DB_PASSWORD"

seal "$DIR/manifests/keycloak-admin.sealed.yaml" keycloak-admin \
  "KC_BOOTSTRAP_ADMIN_USERNAME=KC_BOOTSTRAP_ADMIN_USERNAME=kube12-admin" \
  "KC_BOOTSTRAP_ADMIN_PASSWORD=KC_BOOTSTRAP_ADMIN_PASSWORD"

# une clé par ${REALM_SECRET_*} trouvé dans le realm
mapfile -t realm_keys < <(grep -o '\${REALM_SECRET_[A-Z0-9_]*}' "$REALM_FILE" | tr -d '${}' | sort -u)
[ "${#realm_keys[@]}" -gt 0 ] || { echo "Aucun placeholder REALM_SECRET_* dans $REALM_FILE" >&2; exit 1; }
realm_entries=()
for key in "${realm_keys[@]}"; do realm_entries+=("$key=$key"); done
seal "$DIR/manifests/keycloak-realm-secrets.sealed.yaml" keycloak-realm-secrets "${realm_entries[@]}"

if [ "${#SHOWN[@]}" -gt 0 ]; then
  echo
  echo "Nouvelles valeurs (affichées une seule fois, ne pas les mettre dans Git) :"
  printf '  %s\n' "${SHOWN[@]}"
fi
