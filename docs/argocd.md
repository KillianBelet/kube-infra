# Argo CD (GitOps) exposé en HTTPS

Ticket #35. Dépend de : cert-manager + ClusterIssuers (#31), repo infra (#33), repo application (#34).

## 1. Ce qu'on obtient

Argo CD est le **seul composant installé à la main** (bootstrap). Une fois en place, il lit les
deux repos Git et déploie le reste du cluster. Son interface est servie en HTTPS, avec un
certificat Let's Encrypt, sur `https://argocd.<IP publique>.sslip.io`.

| Élément | Valeur |
|---|---|
| Contrôleur | Argo CD v3.6.1 (chart `argo-cd` 10.18.0, `https://argoproj.github.io/argo-helm`), namespace `argocd` |
| Exposition | Ingress `traefik`, hostname `argocd.<IP publique>.sslip.io`, certificat dans le Secret `argocd-server-tls` |
| TLS | terminé par Traefik ; le serveur Argo CD parle HTTP derrière (`server.insecure`) |
| Dépôts | repo infra (ce repo) et repo applicatif, un Secret par dépôt, lecture seule |
| Connexion | compte `admin` (mot de passe initial généré) ; Dex désactivé, SSO Keycloak prévu (ticket auth) |
| Désactivé | `dex`, `notifications` (inutiles pour l'instant, économie de mémoire) |

```
platform/argocd/
└── values.yaml                       values Helm (Ingress, TLS, ressources)
ansible/
├── argocd.yml                        playbook de bootstrap
├── roles/argocd/                     helm + Secrets des dépôts
├── inventory/group_vars/all/argocd.yml   URL des dépôts, variables des jetons
└── tests/argocd.yml                  test de bout en bout (HTTPS + dépôts « Successful »)
```

## 2. Prérequis

| Prérequis | Où le trouver |
|---|---|
| cluster de prod et `helm` sur kube-1 | `ansible-playbook -i inventory site.yml` (rôle `efs_csi`) |
| Traefik joignable sur kube-1:80/443 | [cert-manager.md](cert-manager.md) § 2 |
| cert-manager et les ClusterIssuers `Ready` | [cert-manager.md](cert-manager.md) § 3 |
| IP publique de kube-1 (`base_domain`) | `inventory/group_vars/all/aws_outputs.yml` |
| URL du repo applicatif | `argocd_app_repo_url` dans `inventory/group_vars/all/argocd.yml` (`https://github.com/KillianBelet/kube-app` ; le rôle refuse de démarrer si elle est vide) |
| jetons de lecture, **si un repo est privé** | voir ci-dessous |

Un repo public se lit sans identifiant. Pour un repo privé, créer sur GitHub un *fine-grained
personal access token* limité à ce seul repo, permission **Contents : Read-only**, et l'exporter
dans le shell qui lance Ansible :

```bash
export ARGOCD_INFRA_REPO_TOKEN=...   # repo infra, si privé
export ARGOCD_APP_REPO_TOKEN=...     # repo applicatif, si privé
```

Les jetons ne sont jamais écrits dans Git ni dans un fichier : Ansible les lit dans
l'environnement et les envoie directement dans le Secret Kubernetes.

## 3. Installation (une fois par cluster)

### Prod (AWS)

Depuis `ansible/` :

```bash
ansible-playbook -i inventory argocd.yml                                            # certificat staging
ansible-playbook -i inventory tests/argocd.yml                                      # vérifier (§ 7)
ansible-playbook -i inventory argocd.yml -e argocd_cluster_issuer=letsencrypt-prod  # puis certificat prod
ansible-playbook -i inventory tests/argocd.yml -e argocd_test_issuer=letsencrypt-prod
```

Le playbook : vérifie que `helm` et le ClusterIssuer existent, dépose les values (celles du repo
+ `global.domain` et l'issuer propres à la prod) sur kube-1, installe le chart dans le namespace
`argocd`, puis crée un Secret par dépôt. Il se rejoue sans risque : helm n'est relancé que si la
release manque ou si la version du chart ou les values changent (2e passage : `changed=0`).

Règle des certificats ([cert-manager.md](cert-manager.md) § 4) : **un nouvel hostname passe d'abord
par `letsencrypt-staging`**, puis `letsencrypt-prod` une fois `READY=True`. cert-manager redemande
alors le certificat tout seul.

### Local (kind)

Même chart, mêmes values ; le domaine par défaut de `values.yaml` est `argocd.127.0.0.1.sslip.io` :

```bash
helm upgrade --install argocd argo-cd --repo https://argoproj.github.io/argo-helm --version 10.18.0 \
  -n argocd --create-namespace -f platform/argocd/values.yaml --wait
```

L'interface répond sur `https://argocd.127.0.0.1.sslip.io` avec le certificat par défaut de
Traefik (avertissement navigateur) : Let's Encrypt ne peut pas joindre 127.0.0.1
([cert-manager.md](cert-manager.md) § 6). Si le ClusterIssuer n'existe pas en local, l'Ingress
fonctionne quand même, seul le `Certificate` reste en attente.

## 4. Dépôts Git

Chaque dépôt est un Secret du namespace `argocd` portant le label
`argocd.argoproj.io/secret-type: repository` : Argo CD le détecte sans redémarrage.

| Champ | Contenu |
|---|---|
| `type` / `name` / `url` | `git`, nom affiché, URL HTTPS du dépôt |
| `username` / `password` | `argocd` et le jeton de lecture ; **absents** pour un dépôt public |

La liste est dans `inventory/group_vars/all/argocd.yml` (`argocd_repos`). Pour changer ou
renouveler un jeton : l'exporter et relancer `argocd.yml`, le Secret est mis à jour.

Registre à la main (local, ou dépôt privé ajouté en urgence) :

```bash
kubectl -n argocd create secret generic repo-kube-app \
  --from-literal=type=git --from-literal=name=kube-app \
  --from-literal=url=https://github.com/<org>/<repo> \
  --from-literal=username=argocd --from-literal=password="$ARGOCD_APP_REPO_TOKEN"
kubectl -n argocd label secret repo-kube-app argocd.argoproj.io/secret-type=repository
```

Vérification : interface, **Settings > Repositories**, les deux dépôts en `Successful`.

## 5. Première connexion

```bash
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo
```

Ouvrir `https://argocd.<IP publique>.sslip.io`, utilisateur `admin`. Puis, sans attendre :

```bash
argocd login argocd.<IP publique>.sslip.io --grpc-web --username admin
argocd account update-password --grpc-web
kubectl -n argocd delete secret argocd-initial-admin-secret   # n'est plus valable
```

`--grpc-web` est nécessaire derrière Traefik. Après le changement de mot de passe,
`tests/argocd.yml` demande `-e argocd_test_password=...`. Le mot de passe ne va jamais dans Git
(le partager par le canal habituel de l'équipe).

## 6. Comment ça marche

```
 navigateur ── https://argocd.<IP>.sslip.io ──► kube-1:443 (hostPort) ──► Traefik
                                                     │ certificat du Secret argocd-server-tls (SNI)
                                                     ▼  HTTP (TLS terminé ici)
                                           Service argocd-server:80 ──► pod argocd-server

 Ingress + annotation cert-manager.io/cluster-issuer ──► cert-manager crée le Certificate
 « argocd-server-tls » ──► défi HTTP-01 via Traefik ──► Secret argocd-server-tls
 (même mécanique que cert-manager.md § 5)

 repo-server ──► clone les dépôts avec les Secrets « repo-* » ──► controller compare Git / cluster
```

- **`server.insecure: true`** : sans lui, Argo CD fait lui-même la redirection HTTPS et sa propre
  TLS, ce qui donne une boucle de redirections (`ERR_TOO_MANY_REDIRECTS`) derrière un Traefik
  qui termine déjà le TLS. Le trafic entre Traefik et le pod reste à l'intérieur du cluster.
- **Redirection HTTP → HTTPS** : déjà assurée par Traefik pour tous les hostnames
  (`platform/traefik/values.yaml`), sauf le défi ACME.
- **Pas de Dex** : la connexion SSO passera directement par Keycloak (OIDC) dans le ticket auth.

## 7. Test (critères d'acceptation)

Depuis `ansible/`, en prod, après le § 3 :

```bash
ansible-playbook -i inventory tests/argocd.yml                                        # staging
ansible-playbook -i inventory tests/argocd.yml -e argocd_test_issuer=letsencrypt-prod # prod
```

Le playbook attend les pods, puis le certificat de l'issuer demandé (`Ready=True`) et vérifie,
depuis la machine qui lance Ansible (comme un navigateur) : l'émetteur du certificat servi par
Traefik, la redirection HTTP → HTTPS, l'interface en HTTPS (en prod **avec vérification de la
chaîne de confiance**), puis il ouvre une session sur l'API et lit la liste des dépôts avec
`forceRefresh` : c'est la même source que **Settings > Repositories**. Chaque dépôt de
`argocd_repos` doit être `Successful`. En cas d'échec il affiche pods, Certificate, événements et
logs d'Argo CD.

Puis à la main : ouvrir `https://argocd.<IP publique>.sslip.io` (cadenas valide, émetteur
« Let's Encrypt »), se connecter, vérifier **Settings > Repositories**.

## 8. Dépannage

| Symptôme | Cause | Solution |
|---|---|---|
| `argocd_app_repo_url` / « URL de dépôt absente » | URL du repo applicatif non renseignée | `inventory/group_vars/all/argocd.yml` ou `-e argocd_app_repo_url=...` |
| « helm absent de kube-1 » | cluster pas construit par `site.yml` | `ansible-playbook -i inventory site.yml` |
| « ClusterIssuer ... introuvable » | cert-manager pas installé | [cert-manager.md](cert-manager.md) § 3 |
| navigateur : `ERR_TOO_MANY_REDIRECTS` | `server.insecure` non appliqué | `kubectl -n argocd get cm argocd-cmd-params-cm -o yaml` doit contenir `server.insecure: "true"` |
| navigateur : « TRAEFIK DEFAULT CERT » | Secret `argocd-server-tls` absent | `kubectl -n argocd get certificate,challenge`, puis [cert-manager.md](cert-manager.md) § 9 |
| navigateur : autorité « (STAGING) » | l'Ingress est encore sur `letsencrypt-staging` | relancer avec `-e argocd_cluster_issuer=letsencrypt-prod` |
| dépôt `Failed`, `authentication required` | jeton absent, expiré, ou sans droit de lecture sur ce repo | exporter un jeton valide et relancer `argocd.yml` |
| dépôt `Failed`, `repository not found` | URL erronée, ou repo privé sans jeton | corriger l'URL / fournir le jeton (§ 2) |
| `argocd` CLI : `context deadline exceeded` | le gRPC direct ne passe pas toujours derrière l'Ingress | ajouter `--grpc-web` |
| pods `Pending` | nœuds saturés (requests) | `kubectl describe pod -n argocd`, alléger ailleurs ou réduire les `resources` de `values.yaml` |
| tâche « Dépôt Git enregistré » en échec sans détail | elle est en `no_log` (le jeton passe dans la commande) | `kubectl -n argocd get secret -l argocd.argoproj.io/secret-type=repository` |

Commandes utiles : `kubectl -n argocd get pods,ingress,certificate`,
`kubectl -n argocd logs deploy/argocd-repo-server --tail=50`.

## 9. Exploitation

- **Monter de version** : une version mineure d'Argo CD à la fois, lire les notes de mise à niveau
  du projet, changer `argocd_chart_version` (`roles/argocd/defaults/main.yml`), l'en-tête de
  `values.yaml` et ce document, relancer `argocd.yml`. Les CRDs suivent le chart.
- **GitOps** (étape suivante) : des Applications dans `apps/` et `platform/` pour Traefik,
  cert-manager ([cert-manager.md](cert-manager.md) § 10), sealed-secrets, etc. Argo CD peut
  aussi se gérer lui-même (Application sur ce chart et `platform/argocd/values.yaml`) ; le
  playbook reste le bootstrap en cas de reconstruction.
- **Jetons des dépôts** : une fois sealed-secrets branché, les Secrets `repo-*` pourront être
  versionnés en `SealedSecret` (`platform/sealed-secrets/README.md`) et le jeton sortir d'Ansible.
- **SSO** : au ticket auth, configurer l'OIDC Keycloak (`configs.cm."oidc.config"`), puis
  désactiver le compte local (`configs.cm."admin.enabled": false`).
- **Supervision** (ticket monitoring) : les composants exposent des métriques Prometheus ;
  activer `*.metrics.enabled` et les ServiceMonitors quand Prometheus Operator sera installé.

## 10. Tests réalisés

Sans cluster disponible pendant le développement, validations hors cluster :

| Test | Résultat |
|---|---|
| `yamllint` : values, playbooks, rôle, variables | OK |
| `ansible-playbook --syntax-check` : `argocd.yml`, `tests/argocd.yml` | OK |
| `ansible-lint` (profil `production`) : `argocd.yml`, `tests/argocd.yml`, `roles/argocd` | Passed |
| rendu des variables du rôle : values fusionnées (domaine, issuer), Secret d'un dépôt avec et sans jeton, comparaison « values déjà installées » (identiques puis différentes), refus d'une URL vide | OK |
| clés de `platform/argocd/values.yaml` contre le `values.yaml` du chart tag `argo-cd-10.18.0` | toutes présentes, types identiques |

Non fait ici (pas de binaire `helm` ni de cluster joignables) : `helm template` du chart et tout
ce qui touche au cluster. À faire sur le cluster AWS (critères d'acceptation) : `argocd.yml` en
staging puis en prod, `tests/argocd.yml` dans les deux cas, 2e passage de `argocd.yml` en
`changed=0`, cadenas valide dans le navigateur, deux dépôts `Successful` dans Settings >
Repositories.
