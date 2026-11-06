# Ingress HTTPS des services (#32)

Dépend de : cert-manager (#31), Traefik (#30).

Tous les services exposés le sont par **un seul chart**, `platform/ingress/` : même convention de
noms, même TLS, et l'IP publique écrite **à un seul endroit**.

## 1. Convention de noms

`<service>.<IP publique de kube-1>.sslip.io` : sslip.io renvoie l'IP contenue dans le nom, sans
DNS à gérer. En local : `<service>.127.0.0.1.sslip.io`.

| Service | Hostname (prod) | Namespace / Service:port | Ticket |
|---|---|---|---|
| application | `app.<IP>.sslip.io` | `app` / `app:80` | #55 |
| ArgoCD | `argocd.<IP>.sslip.io` | `argocd` / `argocd-server:80` | #35 |
| Grafana | `grafana.<IP>.sslip.io` | `monitoring` / `kube-prometheus-stack-grafana:80` | #47 |
| Headlamp | `headlamp.<IP>.sslip.io` | `headlamp` / `headlamp:80` | #50 |
| dex | `dex.<IP>.sslip.io` | `dex` / `dex:5556` | #41 |
| Keycloak | `keycloak.<IP>.sslip.io` | `keycloak` / `keycloak:80` | #39 |

Le hostname est le **nom de la route** dans `values.yaml` : pas de hostname écrit à la main ailleurs.
Les noms de Service/port sont ceux des charts officiels ; à corriger dans `values.yaml` par le
propriétaire du ticket si son chart en crée un autre.

## 2. Le chart `platform/ingress/`

| Fichier | Rôle |
|---|---|
| `values.yaml` | `baseDomain`, issuer par défaut, une route par service (désactivées par défaut) |
| `values-local.yaml` | kind : `127.0.0.1.sslip.io`, sans cert-manager |
| `templates/ingress.yaml` | une Ingress par route activée, dans le namespace du service |

Chaque Ingress générée :
- classe `traefik`, hostname `<route>.<baseDomain>`, chemin `/` (ou `path`) ;
- bloc `tls` + annotation `cert-manager.io/cluster-issuer` : cert-manager crée le `Certificate`,
  le certificat arrive dans le Secret `<route>-tls`, Traefik le sert (voir [cert-manager.md](cert-manager.md)) ;
- le port 80 redirige vers 443 (configuration de Traefik).

Le chart refuse de s'afficher si une route est activée sans `baseDomain`, `namespace`, `service` ou `port`.

## 3. Exposer un service

Dans sa PR, le propriétaire du service active sa route, une fois le Service déployé :

```yaml
routes:
  grafana:
    enabled: true
    issuer: letsencrypt-prod   # après un premier passage en staging (quotas)
```

Options d'une route : `issuer`, `path`, `annotations`. Ne pas activer l'Ingress intégrée au chart
du service (`ingress.enabled: false` dans ses values) : il n'y aurait plus une seule convention.

Cas particuliers :
- **ArgoCD** : `argocd-server` sert du HTTPS par défaut ; mettre `server.insecure: true`
  (values `configs.params`) pour qu'il parle HTTP à Traefik, qui termine le TLS.
- **Keycloak / dex** : leur URL publique (`https://keycloak.<IP>.sslip.io`, `https://dex.<IP>.sslip.io`)
  est aussi dans leur propre configuration (hostname Keycloak, `issuer` dex) : même valeur.

## 4. Déployer

```bash
# prod : base_domain dans ansible/inventory/group_vars/all/aws_outputs.yml
helm upgrade --install kube12-ingress platform/ingress -n kube-system \
  --set baseDomain=<IP publique>.sslip.io --wait

# local
helm upgrade --install kube12-ingress platform/ingress -n kube-system \
  -f platform/ingress/values-local.yaml --wait

kubectl get ingress -A
```

Avec ArgoCD (#36) : une Application sur `platform/ingress`, `baseDomain` passé en paramètre
Helm. **Nouvelle IP publique** (cluster recréé) : seule cette valeur change.

## 5. Tests réalisés

Cluster local kind (Kubernetes 1.36.4), Traefik 42.3.0 avec `platform/traefik/values.yaml`,
cert-manager v1.21.3, service de test `whoami` dans le namespace `app` :

| Test | Résultat |
|---|---|
| `helm lint` (défaut, et toutes les routes activées) | OK |
| rendu sans route activée | aucune ressource |
| route activée sans `baseDomain` | refusé : `baseDomain manquant` |
| `http://app.127.0.0.1.sslip.io/` | `301` vers `https://` |
| `https://app.127.0.0.1.sslip.io/` | réponse de `whoami`, `Host: app.127.0.0.1.sslip.io` |
| certificat servi en local | `TRAEFIK DEFAULT CERT` (attendu, § 6 de cert-manager.md) |
| `certManager: true` | annotation `letsencrypt-staging`, `Certificate app-tls` et Challenge créés par cert-manager |

À faire sur AWS : `issuer: letsencrypt-prod` sur une route, `Certificate` `READY=True`, cadenas valide.

## 6. Dépannage

| Symptôme | Cause | Solution |
|---|---|---|
| `404 page not found` (Traefik) | route non activée, ou hostname différent | `kubectl get ingress -A` |
| `Bad Gateway` | Service ou port faux, pods pas prêts | `kubectl -n <ns> get endpoints <service>` |
| `namespaces "<ns>" not found` à l'installation | route activée avant le déploiement du service | déployer le service d'abord |
| navigateur : « TRAEFIK DEFAULT CERT » en prod | certificat pas encore émis | `kubectl -n <ns> describe certificate <route>-tls` |
| boucle de redirections (ArgoCD) | `argocd-server` encore en HTTPS | `server.insecure: true` |
