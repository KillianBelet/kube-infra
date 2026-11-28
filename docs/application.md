# Application : déploiement sur le cluster (#55)

L'application (repo `kube-app`) tourne en 3 copies, une par nœud, derrière Traefik en HTTPS.
Les manifests sont dans le repo applicatif (`deploy/`, kustomize base + overlays, voir son `deploy/README.md`) ;
ce repo garde l'Application Argo CD, les secrets scellés et la route.

| | |
|---|---|
| URL | `https://app.<IP>.sslip.io` (local : `https://app.127.0.0.1.sslip.io`) |
| Application Argo CD | `kube-app` (wave 3), `apps/local/kube-app.yaml` et `apps/prod/kube-app.yaml` |
| Sources | `kube-app` : `deploy/overlays/<env>` (branche `develop`) ; ce repo : `platform/kube-app` |
| Namespace | `app` |
| Base de données | `mysql.database.svc.cluster.local:3306`, base `app_database`, compte `app_user` ([database.md](database.md)) |
| Image | `ghcr.io/killianbelet/kube-app:<SHA>`, privée ([registry.md](registry.md)) |

## 1. Ordre de déploiement

Dans l'Application `kube-app` (sync waves) :

1. wave -1 : secrets scellés (`kube-app-secrets`, `ghcr-pull`) et ConfigMap ;
2. wave 0 : Job `kube-app-migrate` (`php artisan migrate --force`), attendu jusqu'à la fin ;
3. wave 1 : Deployment (3 replicas), puis Service et PodDisruptionBudget.

La migration tourne une seule fois par synchronisation, pas dans chaque replica.

## 2. Secrets

`platform/kube-app/kube-app-secrets.sealed.yaml` : `APP_KEY` (clé Laravel) et `DB_PASSWORD` (mot de passe de
`app_user`, le même que `mysql-password` du secret `mysql-credentials`).

```bash
DB_PASSWORD=<mot de passe de app_user> ./platform/kube-app/seal-secrets.sh   # APP_KEY générée
git add platform/kube-app
```

Si le mot de passe MySQL change (docs/database.md § 4), resceller avec la nouvelle valeur. Passer aussi `APP_KEY`
(valeur actuelle) pour ne pas invalider les cookies de session.

## 3. Vérifier

```bash
kubectl -n argocd get application kube-app
kubectl -n app get pods -o wide              # 3 pods Running, NODE différent pour chacun
kubectl -n app get job kube-app-migrate      # COMPLETIONS 1/1
curl -s https://app.<IP>.sslip.io/healthz    # ok, certificat valide
curl -s -o /dev/null -w '%{http_code}\n' https://app.<IP>.sslip.io/metrics   # 403 : pas de métriques via l'Ingress
./platform/admission-policies/test.sh --audit | grep " app "                   # OK
```

Testé sur kind (MySQL, Traefik et route du repo, image construite en local) : migrations jouées par le Job,
3 pods sur 3 nœuds, un 4e replica reste `Pending` (anti-affinité), `/` et `/healthz` en 200 via HTTPS, `/metrics`
en 403 via l'Ingress et lu sur le port 9090 dans le cluster (`app_db_up 1`), `rollout restart` sans coupure,
aucun refus des policies.

## 4. Dépannage

| Symptôme | Piste |
|---|---|
| `CreateContainerConfigError` | `kube-app-secrets` absent : `kubectl -n app describe sealedsecret kube-app-secrets` |
| `ErrImagePull` | [registry.md](registry.md) § 4 |
| Job de migration en erreur, `Access denied for user 'app_user'` | `DB_PASSWORD` différent du mot de passe MySQL (§ 2) |
| un pod reste `Pending` | un nœud est absent ou plein : l'anti-affinité interdit 2 copies sur un même nœud |
| page en 500 | `kubectl -n app logs deploy/kube-app` (logs Laravel sur stderr) |
