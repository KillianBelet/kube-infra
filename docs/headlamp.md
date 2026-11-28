# Headlamp (#50)

Tableau de bord web du cluster : pods, logs, événements, ressources de chaque namespace.

| | |
|---|---|
| URL | `https://headlamp.<IP>.sslip.io` (local : `https://headlamp.127.0.0.1.sslip.io`) |
| Chart | `headlamp` 0.46.0 (https://kubernetes-sigs.github.io/headlamp/) |
| Namespace | `headlamp`, Service `headlamp:80` |
| Application Argo CD | `headlamp` (wave 2), `apps/local/headlamp.yaml` et `apps/prod/headlamp.yaml` |
| Values | `platform/headlamp/values.yaml` |

## 1. Droits

Headlamp n'a aucun droit à lui : chaque appel à l'apiserver part avec le jeton de la personne connectée. Ce que
l'on voit et ce que l'on peut modifier, c'est le RBAC de son compte (#43).

Le chart donne `cluster-admin` au compte de service de Headlamp par défaut : c'est désactivé
(`clusterRoleBinding.create: false`). Sans jeton, l'API répond 403.

## 2. Se connecter

Avant le SSO (#51), Headlamp demande un jeton Kubernetes. Par exemple, un compte en lecture seule :

```bash
kubectl -n headlamp create serviceaccount viewer
kubectl create clusterrolebinding headlamp-viewer --clusterrole=view --serviceaccount=headlamp:viewer
kubectl -n headlamp create token viewer --duration=8h      # à coller dans Headlamp
```

## 3. Vérifier

```bash
kubectl -n argocd get application headlamp
kubectl -n headlamp get pods,svc
curl -s -o /dev/null -w '%{http_code}\n' https://headlamp.<IP>.sslip.io/                                   # 200
curl -s -o /dev/null -w '%{http_code}\n' https://headlamp.<IP>.sslip.io/clusters/main/api/v1/namespaces    # 403 sans jeton
curl -s -o /dev/null -w '%{http_code}\n' -H "Authorization: Bearer $TOKEN" \
  https://headlamp.<IP>.sslip.io/clusters/main/api/v1/namespaces                                           # 200
```

Testé sur kind : UI en 200 par la route HTTPS, API en 403 sans jeton, compte `view` : lecture 200 et suppression
d'un pod refusée (403), aucun ClusterRoleBinding créé par le chart.

## 4. Dépannage

| Symptôme | Piste |
|---|---|
| tout est vide ou « forbidden » après connexion | le compte n'a pas de droits : RBAC (#43) |
| `404` sur la route | Service absent : `kubectl -n headlamp get svc headlamp`, route `headlamp` de `platform/ingress` |
| jeton refusé | jeton expiré (`kubectl create token` : 1 h par défaut, `--duration` pour plus) |
