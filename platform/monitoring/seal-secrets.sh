#!/usr/bin/env bash
# Scelle les secrets du monitoring (namespace monitoring). Voir docs/monitoring.md.
#
#   ./platform/monitoring/seal-secrets.sh
#
# grafana-admin (#47) : compte admin local de Grafana. Mot de passe généré si le fichier n'existe
# pas, ou pris dans GRAFANA_ADMIN_PASSWORD. Affiché une seule fois : le garder hors de Git.
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$DIR/../.." && pwd)"
CERT="${KUBESEAL_CERT:-$ROOT/platform/sealed-secrets/team-cert.crt}"
OUT="$DIR/manifests"
NAMESPACE=monitoring

for bin in kubectl kubeseal openssl; do
  command -v "$bin" >/dev/null || { echo "$bin introuvable" >&2; exit 1; }
done
[ -f "$CERT" ] || { echo "Certificat introuvable : $CERT" >&2; exit 1; }

gen() { openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | head -c 32; }

# seal <label name> <fichier> : scelle le Secret lu sur l'entrée standard
seal() {
  kubeseal --cert "$CERT" --format yaml |
    awk -v n="$1" '{ print } /^  name: / && !done { print "  labels:"; print "    app.kubernetes.io/name: " n; done = 1 }' > "$OUT/$2"
  echo "Écrit : ${OUT#"$ROOT"/}/$2"
}

if [ -n "${GRAFANA_ADMIN_PASSWORD:-}" ] || [ ! -f "$OUT/grafana-admin.sealed.yaml" ]; then
  pw="${GRAFANA_ADMIN_PASSWORD:-$(gen)}"
  kubectl create secret generic grafana-admin --namespace "$NAMESPACE" \
    --from-literal=admin-user=admin --from-literal=admin-password="$pw" \
    --dry-run=client -o yaml | seal grafana grafana-admin.sealed.yaml
  [ -n "${GRAFANA_ADMIN_PASSWORD:-}" ] || echo "Mot de passe admin Grafana (affiché une seule fois) : $pw"
else
  echo "Inchangé : grafana-admin"
fi
