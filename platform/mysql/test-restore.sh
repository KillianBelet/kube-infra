#!/usr/bin/env bash
# Test de restauration (#57). Voir docs/database.md § 10.
#
#   ./platform/mysql/test-restore.sh
#
# Écrit une ligne de test, la sauvegarde avec le CronJob, la modifie, restaure le dump
# et vérifie que la ligne d'origine est revenue. La table de test est supprimée à la fin.
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
NS=database
TABLE=restore_test_57
JOB="mysql-backup-test-$(date +%Y%m%d%H%M%S)"

fails=0
ok()   { printf '  OK    %s\n' "$1"; }
ko()   { printf '  ÉCHEC %s\n' "$1"; fails=$((fails + 1)); }
check() { if [ "$2" = "$3" ]; then ok "$1"; else ko "$1 (attendu : $3, obtenu : $2)"; fi; }
stop() { ko "$1"; echo; echo "$fails test(s) en échec."; exit 1; }

sql() {
  kubectl -n "$NS" exec mysql-0 -c mysql -- bash -c \
    'MYSQL_PWD="$(cat "$MYSQL_ROOT_PASSWORD_FILE")" mysql -u root -N -B app_database -e "$1"' _ "$1"
}

cleanup() {
  sql "DROP TABLE IF EXISTS $TABLE" >/dev/null 2>&1 || true
  kubectl -n "$NS" delete job "$JOB" --ignore-not-found --wait=false >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "Cluster : $(kubectl config current-context 2>/dev/null || echo '?')"
kubectl -n "$NS" wait --for=condition=Ready pod/mysql-0 --timeout=120s >/dev/null

value="avant-$(date +%s)"
sql "CREATE TABLE IF NOT EXISTS $TABLE (id INT PRIMARY KEY, v VARCHAR(40));
     REPLACE INTO $TABLE VALUES (1, '$value');"
check "ligne de test écrite" "$(sql "SELECT v FROM $TABLE WHERE id = 1")" "$value"

kubectl -n "$NS" create job "$JOB" --from=cronjob/mysql-backup >/dev/null
kubectl -n "$NS" wait --for=condition=complete "job/$JOB" --timeout=300s >/dev/null ||
  stop "sauvegarde en échec : kubectl -n $NS logs job/$JOB"
dump="$(kubectl -n "$NS" logs "job/$JOB" | sed -n 's|^Dump écrit : /backups/\([^ ]*\) .*|\1|p' | tail -1)"
[ -n "$dump" ] || stop "nom du dump absent des logs du job"
ok "sauvegarde : $dump"

sql "UPDATE $TABLE SET v = 'modifiee' WHERE id = 1; INSERT INTO $TABLE VALUES (2, 'apres-dump');"
check "base modifiée après le dump" "$(sql "SELECT COUNT(*) FROM $TABLE")" "2"

"$DIR/restore.sh" -y --no-backup "$dump" >/dev/null || stop "restore.sh en échec"
ok "restauration de $dump"

check "valeur d'origine retrouvée" "$(sql "SELECT v FROM $TABLE WHERE id = 1")" "$value"
check "ligne ajoutée après le dump supprimée" "$(sql "SELECT COUNT(*) FROM $TABLE")" "1"

echo
if [ "$fails" -eq 0 ]; then echo "Tous les tests passent."; else echo "$fails test(s) en échec."; exit 1; fi
