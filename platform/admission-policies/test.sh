#!/usr/bin/env bash
# Tests des ValidatingAdmissionPolicy (#52). Voir docs/admission-policies.md.
# Rien n'est créé dans le cluster : tout passe en --dry-run=server, qui exécute l'admission.
#
#   ./platform/admission-policies/test.sh           # manifests refusés / acceptés
#   ./platform/admission-policies/test.sh --audit   # workloads déjà déployés qui seraient refusés
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
SYSTEM_NS=" kube-system kube-public kube-node-lease local-path-storage "
fails=0
ok()   { printf '  OK    %s\n' "$1"; }
ko()   { printf '  ÉCHEC %s\n' "$1"; fails=$((fails + 1)); }

for p in disallow-latest-tag require-resources disallow-privileged; do
  kubectl get validatingadmissionpolicy "kube12-$p" -o name >/dev/null
  kubectl get validatingadmissionpolicybinding "kube12-$p" -o name >/dev/null
done

if [ "${1:-}" = --audit ]; then
  # Modifie (à blanc) une annotation du modèle de pod : l'apiserver réévalue alors le modèle.
  list="$(kubectl get deployments,statefulsets,daemonsets,cronjobs -A --no-headers \
    -o custom-columns=NS:.metadata.namespace,KIND:.kind,NAME:.metadata.name)"
  while read -r ns kind name; do
    [ -n "$ns" ] || continue
    case "$SYSTEM_NS" in *" $ns "*) continue ;; esac
    tpl='{"metadata":{"annotations":{"kube12/audit":"1"}}}'
    if [ "$kind" = CronJob ]; then
      patch="{\"spec\":{\"jobTemplate\":$tpl}}"
    else
      patch="{\"spec\":{\"template\":$tpl}}"
    fi
    if out="$(kubectl -n "$ns" patch "$kind" "$name" --type=merge -p "$patch" --dry-run=server 2>&1)"; then
      ok "$ns $kind/$name"
    else
      ko "$ns $kind/$name"
      printf '        %s\n' "$out"
    fi
  done <<<"$list"
  echo
  if [ "$fails" -eq 0 ]; then echo "Tous les workloads sont conformes."; else echo "$fails workload(s) en échec."; exit 1; fi
  exit 0
fi

echo "Manifests refusés"
for f in "$DIR"/tests/refused/*.yaml; do
  case_name="$(basename "$f" .yaml)"
  policy="kube12-${case_name%%--*}"
  if out="$(kubectl create --dry-run=server -f "$f" 2>&1)"; then
    ko "$case_name : accepté alors qu'il devait être refusé"
  elif [[ "$out" == *"ValidatingAdmissionPolicy '$policy'"* ]]; then
    ok "$case_name"
    printf '        %s\n' "${out##*denied request: }"
  else
    ko "$case_name : refusé, mais pas par $policy"
    printf '        %s\n' "$out"
  fi
done

echo "Manifests acceptés"
for f in "$DIR"/tests/accepted/*.yaml; do
  case_name="$(basename "$f" .yaml)"
  if out="$(kubectl create --dry-run=server -f "$f" 2>&1)"; then
    ok "$case_name"
  else
    ko "$case_name"
    printf '        %s\n' "$out"
  fi
done

echo
if [ "$fails" -eq 0 ]; then echo "Tous les tests passent."; else echo "$fails test(s) en échec."; exit 1; fi
