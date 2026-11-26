#!/usr/bin/env bash
# Restaure la base de l'application depuis une sauvegarde (#57). Voir docs/database.md § 10.
#
#   ./platform/mysql/restore.sh                     # liste les dumps de /backups
#   ./platform/mysql/restore.sh latest              # restaure le plus récent
#   ./platform/mysql/restore.sh app_database-20261120-020000.sql.gz
#   ./platform/mysql/restore.sh --file ./app_database-20261120-020000.sql.gz   # dump copié hors du cluster
#
# Avant de restaurer : sauvegarde de l'état actuel (sauf --no-backup) et confirmation (sauf -y).
set -euo pipefail

NS=database
POD=mysql-0
DATABASE=app_database
NAME_RE="^${DATABASE}-[0-9]{8}-[0-9]{6}\.sql\.gz$"

yes=0
backup=1
file=""
dump=""
while [ $# -gt 0 ]; do
  case "$1" in
    -y | --yes) yes=1 ;;
    --no-backup) backup=0 ;;
    --file) file="${2:?--file attend un chemin}"; shift ;;
    -h | --help) sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) echo "Option inconnue : $1" >&2; exit 1 ;;
    *) dump="$1" ;;
  esac
  shift
done

command -v kubectl >/dev/null || { echo "kubectl introuvable" >&2; exit 1; }

in_pod() { kubectl -n "$NS" exec "$POD" -c mysql -- "$@"; }
# mysql root dans le pod, mot de passe lu dans le fichier monté par le chart
MYSQL_ROOT='MYSQL_PWD="$(cat "$MYSQL_ROOT_PASSWORD_FILE")" mysql -u root'
dumps() { in_pod ls -1 /backups | grep -E "$NAME_RE" | sort || true; }

kubectl -n "$NS" wait --for=condition=Ready "pod/$POD" --timeout=60s >/dev/null

if [ -z "$dump" ] && [ -z "$file" ]; then
  echo "Dumps disponibles dans /backups :"
  in_pod ls -lh /backups | grep -E "${DATABASE}-.*\.sql\.gz$" || echo "  aucun"
  echo
  echo "Restaurer : $0 latest | $0 <dump> | $0 --file <dump local>"
  exit 0
fi

if [ -n "$file" ]; then
  [ -f "$file" ] || { echo "Fichier introuvable : $file" >&2; exit 1; }
  gzip -t "$file" || { echo "Dump illisible : $file" >&2; exit 1; }
  source_label="$file (local)"
else
  [ "$dump" = latest ] && dump="$(dumps | tail -1)"
  [ -n "$dump" ] || { echo "Aucun dump dans /backups" >&2; exit 1; }
  [[ "$dump" =~ $NAME_RE ]] || { echo "Nom de dump invalide : $dump" >&2; exit 1; }
  dumps | grep -qx "$dump" || { echo "Dump absent de /backups : $dump" >&2; exit 1; }
  in_pod gzip -t "/backups/$dump" || { echo "Dump illisible : $dump" >&2; exit 1; }
  source_label="/backups/$dump"
fi

context="$(kubectl config current-context 2>/dev/null || echo '?')"
echo "Cluster : $context"
echo "Dump    : $source_label"
echo "Les tables du dump vont remplacer celles de $DATABASE."
if [ "$yes" -ne 1 ]; then
  read -r -p "Continuer ? [o/N] " answer
  case "$answer" in o | O | oui | y | yes) ;; *) echo "Annulé."; exit 1 ;; esac
fi

if [ "$backup" -eq 1 ]; then
  job="mysql-backup-avant-restore-$(date +%Y%m%d%H%M%S)"
  echo "Sauvegarde de l'état actuel ($job)..."
  kubectl -n "$NS" create job "$job" --from=cronjob/mysql-backup >/dev/null
  if ! kubectl -n "$NS" wait --for=condition=complete "job/$job" --timeout=300s >/dev/null; then
    kubectl -n "$NS" logs "job/$job" --tail=20 >&2 || true
    echo "Sauvegarde en échec : restauration annulée." >&2
    exit 1
  fi
  kubectl -n "$NS" logs "job/$job" | grep '^Dump écrit' || true
  kubectl -n "$NS" delete job "$job" --wait=false >/dev/null
fi

echo "Restauration..."
start=$SECONDS
if [ -n "$file" ]; then
  gunzip -c "$file" | kubectl -n "$NS" exec -i "$POD" -c mysql -- bash -c "$MYSQL_ROOT"
else
  in_pod bash -c "set -o pipefail; gunzip -c /backups/$dump | $MYSQL_ROOT"
fi
echo "Terminé en $((SECONDS - start)) s. Tables de $DATABASE :"
in_pod bash -c "$MYSQL_ROOT -t -e \"SELECT table_name AS 'table', table_rows AS 'lignes (approx.)'
  FROM information_schema.tables WHERE table_schema = '$DATABASE' ORDER BY table_name\""
