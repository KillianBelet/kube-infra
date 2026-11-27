#!/usr/bin/env bash
# Scelle les secrets de l'application (namespace app). Voir docs/registry.md.
#
#   GHCR_USER=<login GitHub> GHCR_TOKEN=<token read:packages> ./platform/kube-app/seal-secrets.sh
#
# ghcr-pull : imagePullSecret pour ghcr.io/killianbelet/kube-app (#38). Le token est un token
# GitHub classique avec le seul droit read:packages.
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$DIR/../.." && pwd)"
CERT="${KUBESEAL_CERT:-$ROOT/platform/sealed-secrets/team-cert.crt}"
NAMESPACE=app

for bin in kubectl kubeseal; do
  command -v "$bin" >/dev/null || { echo "$bin introuvable" >&2; exit 1; }
done
[ -f "$CERT" ] || { echo "Certificat introuvable : $CERT" >&2; exit 1; }

# Ajoute le fichier à la liste resources du kustomization.yaml s'il n'y est pas.
add_resource() {
  local file="$DIR/kustomization.yaml"
  grep -q "^  - $1$" "$file" && return
  awk -v f="$1" '/^resources: \[\]$/ { print "resources:"; print "  - " f; next } { print }' "$file" > "$file.tmp"
  grep -q "^  - $1$" "$file.tmp" || printf '  - %s\n' "$1" >> "$file.tmp"
  mv "$file.tmp" "$file"
}

# seal <label name> <fichier> : scelle le Secret lu sur l'entrée standard
seal() {
  kubeseal --cert "$CERT" --format yaml |
    awk -v n="$1" '{ print } /^  name: / && !done { print "  labels:"; print "    app.kubernetes.io/name: " n; done = 1 }' > "$DIR/$2"
  add_resource "$2"
  echo "Écrit : ${DIR#"$ROOT"/}/$2"
}

if [ -n "${GHCR_TOKEN:-}" ]; then
  : "${GHCR_USER:?GHCR_USER manquant (login GitHub du token)}"
  kubectl create secret docker-registry ghcr-pull --namespace "$NAMESPACE" \
    --docker-server=ghcr.io --docker-username="$GHCR_USER" --docker-password="$GHCR_TOKEN" \
    --dry-run=client -o yaml | seal ghcr-pull ghcr-pull.sealed.yaml
else
  echo "GHCR_TOKEN absent : ghcr-pull non modifié"
fi
