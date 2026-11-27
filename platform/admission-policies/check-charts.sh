#!/usr/bin/env bash
# Rend les charts du repo avec LEURS values locales et soumet le résultat à l'apiserver en
# --dry-run=server : vérifie avant le merge que chaque composant respecte les policies (#52).
# Prérequis : cluster avec les policies appliquées et les namespaces des composants.
# Versions à garder identiques à celles de apps/.
#
#   ./platform/admission-policies/check-charts.sh
set -euo pipefail
cd "$(dirname "$0")/../.."

for p in disallow-latest-tag require-resources disallow-privileged; do
  kubectl get validatingadmissionpolicybinding "kube12-$p" -o name >/dev/null
done

fails=0
ko() { printf '  ÉCHEC %s\n' "$1"; fails=$((fails + 1)); }

# check <release> <namespace> <arguments de helm template...>
check() {
  local release=$1 ns=$2 manifests out denied
  shift 2
  if ! manifests="$(helm template "$release" "$@" -n "$ns")"; then ko "$release : helm template"; return; fi
  # create, pas apply : l'admission évalue l'objet complet, même s'il existe déjà.
  out="$(kubectl create --dry-run=server -n "$ns" -f - <<<"$manifests" 2>&1 || true)"
  denied="$(grep ValidatingAdmissionPolicy <<<"$out" || true)"
  if [ -n "$denied" ]; then
    ko "$release"; printf '%s\n' "$denied"
  elif ! grep -qE '^(deployment|statefulset|daemonset|job|cronjob)|(deployments|statefulsets|daemonsets|jobs|cronjobs)\.[a-z]+ .* already exists' <<<"$out"; then
    ko "$release : aucun workload évalué"; printf '%s\n' "$out"
  else
    printf '  OK    %s\n' "$release"
  fi
}

check argocd argocd argo-cd --repo https://argoproj.github.io/argo-helm --version 10.18.0 \
  -f platform/argocd/values.yaml
check sealed-secrets sealed-secrets sealed-secrets --repo https://bitnami.github.io/sealed-secrets --version 2.22.0 \
  -f platform/sealed-secrets/values.yaml
check traefik traefik traefik --repo https://traefik.github.io/charts --version 42.3.0 \
  -f platform/traefik/values.yaml
check cert-manager cert-manager oci://quay.io/jetstack/charts/cert-manager --version v1.21.3 \
  -f platform/cert-manager/values.yaml
check mysql database oci://registry-1.docker.io/bitnamicharts/mysql --version 12.3.5 \
  -f platform/mysql/values.yaml
check keycloak-db keycloak oci://registry-1.docker.io/bitnamicharts/mysql --version 12.3.5 \
  -f platform/keycloak/values-db.yaml
check keycloak keycloak keycloakx --repo https://codecentric.github.io/helm-charts --version 7.4.0 \
  -f platform/keycloak/values.yaml --set baseDomain=127.0.0.1.sslip.io

echo
if [ "$fails" -eq 0 ]; then echo "Tous les charts sont conformes."; else echo "$fails chart(s) en échec."; exit 1; fi
