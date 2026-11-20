#!/usr/bin/env bash
# Génère les identifiants MySQL et les chiffre en SealedSecret (#54). Voir docs/database.md.
#
#   ./platform/mysql/seal-credentials.sh
#
# - Crée deux mots de passe aléatoires (root et app_user), ou reprend ceux passés en
#   variables d'environnement : MYSQL_ROOT_PASSWORD, MYSQL_PASSWORD.
# - Les chiffre avec le certificat public de l'équipe (platform/sealed-secrets/team-cert.crt) :
#   pas besoin d'être connecté à un cluster.
# - Écrit platform/mysql/manifests/mysql-credentials.sealed.yaml (le seul fichier à commiter).
# - Affiche les mots de passe une seule fois : les garder hors de Git (gestionnaire de mots de passe).
#   Le mot de passe de app_user sert aussi au DB_PASSWORD de l'application (#55).
#
# ATTENTION, base déjà initialisée : ne jamais relancer ce script sans MYSQL_ROOT_PASSWORD et
# MYSQL_PASSWORD. MySQL garde les mots de passe de sa création ; un Secret différent fait
# échouer les sondes du pod (redémarrages en boucle). Procédure : docs/database.md § 4.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CERT="${KUBESEAL_CERT:-$ROOT/platform/sealed-secrets/team-cert.crt}"
OUT="$ROOT/platform/mysql/manifests/mysql-credentials.sealed.yaml"

for bin in kubectl kubeseal openssl; do
  command -v "$bin" >/dev/null || { echo "$bin introuvable" >&2; exit 1; }
done
[ -f "$CERT" ] || { echo "Certificat introuvable : $CERT" >&2; exit 1; }

gen() { openssl rand -base64 32 | tr -dc 'A-Za-z0-9' | head -c 24; }
ROOT_PW="${MYSQL_ROOT_PASSWORD:-$(gen)}"
APP_PW="${MYSQL_PASSWORD:-$(gen)}"

kubectl create secret generic mysql-credentials \
  --namespace database \
  --from-literal=mysql-root-password="$ROOT_PW" \
  --from-literal=mysql-password="$APP_PW" \
  --dry-run=client -o yaml |
  kubeseal --cert "$CERT" --format yaml > "$OUT"

echo "Écrit : ${OUT#"$ROOT"/}"
echo
echo "À conserver HORS de Git (affiché une seule fois) :"
echo "  root     : $ROOT_PW"
echo "  app_user : $APP_PW"
