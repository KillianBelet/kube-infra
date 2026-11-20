# Argo CD (GitOps) exposé en HTTPS

Ticket #35. Dépend de : repo infra (#33), repo application (#34), chart `platform/ingress` (#32,
[ingress.md](ingress.md)) pour l'exposition HTTPS.

## 1. Ce qu'on obtient

Argo CD est le **seul composant installé à la main** (bootstrap). Une fois en place, il lit les
deux repos Git et déploie le reste du cluster. Son interface est servie en HTTPS sur
`https://argocd.<domaine>` : `127.0.0.1.sslip.io` en local, `<IP publique>.sslip.io` en prod.

| Élément | Valeur |
|---|---|
| Contrôleur | Argo CD v3.6.1 (chart `argo-cd` 10.18.0, `https://argoproj.github.io/argo-helm`), namespace `argocd` |
| Exposition | route `argocd` du chart `platform/ingress` (Ingress `traefik`, hostname `argocd.<baseDomain>`) : **pas d'Ingress dans le chart Argo CD** |
| TLS | terminé par Traefik ; le serveur Argo CD parle HTTP derrière (`server.insecure`, Service `argocd-server:80`) |
| Certificat | prod : Let's Encrypt via cert-manager (Secret `argocd-tls`) ; local : certificat par défaut de Traefik |
| Dépôts | repo infra (ce repo) et repo applicatif, un Secret par dépôt, lecture seule |
| Connexion | compte `admin` (mot de passe initial généré) ; Dex désactivé, SSO Keycloak prévu (ticket auth) |
| Désactivé | `dex`, `notifications` (inutiles pour l'instant, économie de mémoire) |

```
platform/argocd/
└── values.yaml                       values Helm (server.insecure, ressources, dex/notifications off)
ansible/
├── argocd.yml                        playbook de bootstrap (prod)
├── roles/argocd/                     helm + Secrets des dépôts
├── inventory/group_vars/all/argocd.yml   URL des dépôts, variables des jetons
└── tests/argocd.yml                  test de bout en bout en prod (HTTPS + dépôts « Successful »)
```

`global.domain` (values) est l'URL publique d'Argo CD, utilisée dans sa configuration (SSO, liens).
Elle doit rester égale au hostname de la route : `argocd.<baseDomain>`.

## 2. Local (kind) : parcours de développement

On développe tout en local ; la prod AWS n'est allumée que pour l'intégration (§ 4).

Prérequis : `ansible-playbook local.yml` (cluster kind-kube-12 prêt) et Traefik installé avec
`platform/traefik/values.yaml` (voir [cert-manager.md](cert-manager.md) § 2). Si Traefik n'est pas
encore installé dans le cluster :

```bash
helm upgrade --install traefik traefik --repo https://traefik.github.io/charts --version 42.3.0 \
  -n traefik --create-namespace -f platform/traefik/values.yaml --wait
```

Depuis la racine du repo, `kubectl` sur le contexte `kind-kube-12` :

```bash
# 1. Argo CD (d'abord : la route argocd vise le namespace argocd)
helm upgrade --install argocd argo-cd --repo https://argoproj.github.io/argo-helm --version 10.18.0 \
  -n argocd --create-namespace -f platform/argocd/values.yaml --wait

# 2. Exposition : route argocd du chart ingress (enabled: true dans platform/ingress/values.yaml)
helm upgrade --install kube12-ingress platform/ingress -n kube-system \
  -f platform/ingress/values-local.yaml --wait

# 3. Les deux dépôts (publics : pas de jeton)
for r in kube-infra kube-app; do
kubectl -n argocd apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: repo-$r
  namespace: argocd
  labels:
    argocd.argoproj.io/secret-type: repository
stringData:
  type: git
  name: $r
  url: https://github.com/KillianBelet/$r
EOF
done
```

Vérifier :

```bash
kubectl -n argocd get pods                               # tous Running
kubectl get ingress -A                                   # argocd : argocd.127.0.0.1.sslip.io
curl -sI  http://argocd.127.0.0.1.sslip.io/  | head -1   # 308 vers https
curl -skI https://argocd.127.0.0.1.sslip.io/ | head -1   # 200
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo
```

Puis dans le navigateur : `https://argocd.127.0.0.1.sslip.io` (avertissement de certificat :
c'est le certificat par défaut de Traefik, Let's Encrypt ne peut pas joindre 127.0.0.1, voir
[cert-manager.md](cert-manager.md) § 6), utilisateur `admin`, puis **Settings > Repositories** :
`kube-infra` et `kube-app` en `Successful`.

## 3. Dépôts Git

Chaque dépôt est un Secret du namespace `argocd` portant le label
`argocd.argoproj.io/secret-type: repository` : Argo CD le détecte sans redémarrage.

| Champ | Contenu |
|---|---|
| `type` / `name` / `url` | `git`, nom affiché, URL HTTPS du dépôt |
| `username` / `password` | `argocd` et le jeton de lecture ; **absents** pour un dépôt public |

Les deux dépôts du projet sont publics : aucun jeton nécessaire. Pour un dépôt privé, créer un
*fine-grained personal access token* limité à ce seul repo, permission **Contents : Read-only**,
et ajouter `--from-literal=username=argocd --from-literal=password="$TOKEN"` (ou les deux champs
`stringData` ci-dessus). **Jamais de jeton dans Git** : seul un `SealedSecret`
(`platform/sealed-secrets/README.md`) peut y être versionné.

En prod, la liste est dans `ansible/inventory/group_vars/all/argocd.yml` (`argocd_repos`) ;
les jetons éventuels sont lus dans l'environnement de la machine qui lance Ansible :

```bash
export ARGOCD_INFRA_REPO_TOKEN=...   # repo infra, si privé
export ARGOCD_APP_REPO_TOKEN=...     # repo applicatif, si privé
```

Renouveler un jeton : l'exporter et relancer `argocd.yml` : le Secret est mis à jour.

## 4. Prod (AWS)

Prérequis : cluster construit par `site.yml` (avec `helm` sur kube-1), Traefik et cert-manager
avec ses ClusterIssuers ([cert-manager.md](cert-manager.md) § 2 et 3), `base_domain` dans
`ansible/inventory/group_vars/all/aws_outputs.yml` (IP publique de kube-1, **change à chaque
recréation de l'infra**).

Depuis `ansible/` :

```bash
ansible-playbook -i inventory argocd.yml        # installe Argo CD, enregistre les dépôts
ansible-playbook -i inventory argocd.yml        # 2e passage : changed=0
```

Puis, depuis la racine du repo avec `KUBECONFIG=~/.kube-12/kubeconfig-aws`, l'exposition (route
`argocd` du chart ingress) :

```bash
helm upgrade --install kube12-ingress platform/ingress -n kube-system \
  --set baseDomain=<IP publique>.sslip.io --wait                       # certificat staging
helm upgrade --install kube12-ingress platform/ingress -n kube-system \
  --set baseDomain=<IP publique>.sslip.io --set routes.argocd.issuer=letsencrypt-prod --wait   # puis prod
```

Règle des certificats ([cert-manager.md](cert-manager.md) § 4) : **un nouvel hostname passe d'abord
par `letsencrypt-staging`**, puis `letsencrypt-prod` une fois `READY=True`. Si d'autres routes sont
activées, passer aussi leurs `issuer` (ou utiliser un fichier de values) pour ne pas les repasser en
staging à chaque `helm upgrade`.

**Nouvelle IP publique** (infra recréée) : 1) `base_domain` dans `aws_outputs.yml`, 2) relancer
`argocd.yml` (il met à jour `global.domain`), 3) relancer le chart ingress avec le nouveau `baseDomain`.

## 5. Première connexion

```bash
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo
```

Ouvrir `https://argocd.<domaine>`, utilisateur `admin`. Puis, sans attendre :

```bash
argocd login argocd.<domaine> --grpc-web --username admin     # --insecure en local (certificat Traefik par défaut)
argocd account update-password --grpc-web
kubectl -n argocd delete secret argocd-initial-admin-secret   # n'est plus valable
```

`--grpc-web` est nécessaire derrière Traefik. Après le changement de mot de passe,
`tests/argocd.yml` demande `-e argocd_test_password=...`. Le mot de passe ne va jamais dans Git
(le partager par le canal habituel de l'équipe).

## 6. Comment ça marche

```
 navigateur ── https://argocd.<domaine> ──► Traefik (kube-1:443) ── certificat du Secret argocd-tls (SNI)
                                               │  HTTP (TLS terminé ici)
                                               ▼
                                     Service argocd-server:80 ──► pod argocd-server

 chart platform/ingress, route « argocd » ──► Ingress argocd (namespace argocd)
   prod : annotation cert-manager.io/cluster-issuer ──► Certificate « argocd-tls » ──► défi HTTP-01
   (même mécanique que cert-manager.md § 5)           ──► Secret argocd-tls

 repo-server ──► clone les dépôts avec les Secrets « repo-* » ──► controller compare Git / cluster
```

- **`server.insecure: true`** : sans lui, `argocd-server` sert du HTTPS et fait lui-même la
  redirection, ce qui donne une boucle de redirections (`ERR_TOO_MANY_REDIRECTS`) derrière un
  Traefik qui termine déjà le TLS. Le trafic entre Traefik et le pod reste dans le cluster.
- **Une seule convention d'exposition** : l'Ingress n'est pas celle du chart Argo CD
  (`server.ingress` n'est pas activé), pour que tous les services aient le même hostname, le même TLS
  et l'IP écrite à un seul endroit ([ingress.md](ingress.md)).
- **Redirection HTTP → HTTPS** : assurée par Traefik pour tous les hostnames
  (`platform/traefik/values.yaml`), sauf le défi ACME.
- **Pas de Dex** : la connexion SSO passera directement par Keycloak (OIDC) dans le ticket auth.

## 7. Test (critères d'acceptation)

**Local** : les vérifications du § 2 (`curl` 308 puis 200, interface, dépôts `Successful`).

**Prod** : depuis `ansible/`, après les § 3 et 4 :

```bash
ansible-playbook -i inventory tests/argocd.yml                                        # route sur staging
ansible-playbook -i inventory tests/argocd.yml -e argocd_test_issuer=letsencrypt-prod # route sur prod
```

Le playbook attend les pods, puis le certificat de l'issuer demandé (`Ready=True`) et vérifie,
depuis la machine qui lance Ansible (comme un navigateur) : l'émetteur du certificat servi par
Traefik, la redirection HTTP → HTTPS, l'interface en HTTPS (en prod **avec vérification de la
chaîne de confiance**), puis il ouvre une session sur l'API et lit la liste des dépôts avec
`forceRefresh` : c'est la même source que **Settings > Repositories**. Chaque dépôt de
`argocd_repos` doit être `Successful`. En cas d'échec il affiche pods, Certificate, événements et
logs d'Argo CD. Puis à la main : cadenas valide, émetteur « Let's Encrypt », **Settings > Repositories**.

## 8. Dépannage

| Symptôme | Cause | Solution |
|---|---|---|
| `namespaces "argocd" not found` à l'installation du chart ingress | route `argocd` activée avant Argo CD | installer Argo CD d'abord (§ 2 étape 1) |
| `404 page not found` (Traefik) | route `argocd` non activée dans `platform/ingress/values.yaml`, ou mauvais `baseDomain` | `kubectl get ingress -A` |
| `Bad Gateway` | pods Argo CD pas prêts, ou `server.insecure` non appliqué (port 80 absent) | `kubectl -n argocd get pods,endpoints argocd-server` |
| navigateur : `ERR_TOO_MANY_REDIRECTS` | `server.insecure` non appliqué | `kubectl -n argocd get cm argocd-cmd-params-cm -o yaml` doit contenir `server.insecure: "true"` |
| navigateur : « TRAEFIK DEFAULT CERT » | local : normal ; prod : Secret `argocd-tls` absent | `kubectl -n argocd get certificate,challenge`, puis [cert-manager.md](cert-manager.md) § 9 |
| navigateur : autorité « (STAGING) » | la route est encore sur `letsencrypt-staging` | `--set routes.argocd.issuer=letsencrypt-prod` (§ 4) |
| `argocd_app_repo_url` / « URL de dépôt absente » (Ansible) | URL du repo applicatif vide ou invalide | `inventory/group_vars/all/argocd.yml` |
| « helm absent de kube-1 » (Ansible) | cluster pas construit par `site.yml` | `ansible-playbook -i inventory site.yml` |
| dépôt `Failed`, `authentication required` | repo privé : jeton absent, expiré, ou sans droit de lecture | exporter un jeton valide et relancer `argocd.yml` |
| dépôt `Failed`, `repository not found` | URL erronée, ou repo privé sans jeton | corriger l'URL / fournir le jeton (§ 3) |
| `argocd` CLI : `context deadline exceeded` | le gRPC direct ne passe pas toujours derrière l'Ingress | ajouter `--grpc-web` |
| pods `Pending` | nœuds saturés (requests) | `kubectl describe pod -n argocd`, ou réduire les `resources` de `values.yaml` |
| tâche « Dépôt Git enregistré » en échec sans détail | elle est en `no_log` (le jeton passe dans la commande) | `kubectl -n argocd get secret -l argocd.argoproj.io/secret-type=repository` |

Commandes utiles : `kubectl -n argocd get pods,ingress,certificate`,
`kubectl -n argocd logs deploy/argocd-repo-server --tail=50`.

## 9. Exploitation

- **Monter de version** : une version mineure d'Argo CD à la fois, lire les notes de mise à niveau
  du projet, changer `argocd_chart_version` (`roles/argocd/defaults/main.yml`), la version dans les
  commandes de ce document et l'en-tête de `values.yaml`, puis relancer. Les CRDs suivent le chart.
- **GitOps** (étape suivante) : des Applications dans `apps/` et `platform/` pour Traefik,
  cert-manager ([cert-manager.md](cert-manager.md) § 10), `platform/ingress` (`baseDomain` en paramètre
  Helm, [ingress.md](ingress.md) § 4), sealed-secrets, etc. Argo CD peut aussi se gérer lui-même
  (Application sur ce chart et `platform/argocd/values.yaml`) ; l'installation manuelle reste le
  bootstrap en cas de reconstruction.
- **Jetons des dépôts privés** : une fois sealed-secrets branché, les Secrets `repo-*` pourront être
  versionnés en `SealedSecret` et le jeton sortir d'Ansible.
- **SSO** : au ticket auth, configurer l'OIDC Keycloak (`configs.cm."oidc.config"`), puis
  désactiver le compte local (`configs.cm."admin.enabled": false`).
- **Supervision** (ticket monitoring) : les composants exposent des métriques Prometheus ;
  activer `*.metrics.enabled` et les ServiceMonitors quand Prometheus Operator sera installé.

## 10. Tests réalisés

Sans cluster ni accès réseau pendant le développement, validations hors cluster :

| Test | Résultat |
|---|---|
| `yamllint` : values, playbooks, rôle, variables | OK |
| `ansible-playbook --syntax-check` : `argocd.yml`, `tests/argocd.yml` | OK |
| `ansible-lint` (profil `production`) : `argocd.yml`, `tests/argocd.yml`, `roles/argocd` | Passed |
| rendu des variables du rôle : values fusionnées (domaine), Secret d'un dépôt avec et sans jeton, comparaison « values déjà installées » (identiques puis différentes), refus d'une URL vide | OK |
| correspondance des dépôts du test sur des réponses API simulées (succès, échec, dépôt absent) | OK |
| clés de `platform/argocd/values.yaml` contre le `values.yaml` du chart tag `argo-cd-10.18.0` | toutes présentes, types identiques |

Non fait (pas de binaire `helm` ni de cluster joignables) : `helm template` du chart, déploiement
sur kind (§ 2) et sur AWS (§ 4). À faire : § 2 complet sur kind (pods Running, `curl` 308 puis 200,
dépôts `Successful`) ; plus tard, sur AWS : `argocd.yml` (2e passage `changed=0`), chart ingress en
staging puis prod, `tests/argocd.yml` dans les deux cas, cadenas valide.
