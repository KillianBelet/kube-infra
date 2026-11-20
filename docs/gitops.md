# GitOps : Argo CD app-of-apps (#36)

Un seul manifeste appliqué à la main (`bootstrap/root-*.yaml`) ; ensuite **tout le cluster se pilote par `git push`**.
L'Application racine lit le dossier `apps/` du repo infra, et chaque fichier de ce dossier est une Application enfant
(un composant de la plateforme, ou l'application métier).

```
bootstrap/root-<env>.yaml   (kubectl apply, une fois)
  └─ Application "root"  ──► apps/common/ + apps/<env>/   (repo kube-infra)
        ├─ vague 0 : sealed-secrets, traefik, cert-manager      ──► platform/<composant>/values.yaml
        ├─ vague 1 : cert-manager-issuers                       ──► platform/cert-manager/issuers/
        ├─ vague 2 : ingress                                    ──► platform/ingress/ (chart #71)
        └─ vague 3 : kube-app                                   ──► deploy/ du repo kube-app
```

Toutes les Applications ont `automated` + `prune` + `selfHeal` + `retry` (backoff 10 s → 3 min).

## 1. Arborescence

| Fichier | Rôle |
|---|---|
| `bootstrap/root-local.yaml` | racine du cluster kind : `apps/common` + `apps/local` (exclut `prod/`) |
| `bootstrap/root-prod.yaml` | racine du cluster AWS : `apps/common` + `apps/prod` (exclut `local/`) |
| `apps/common/*.yaml` | composants identiques dans les deux environnements |
| `apps/local/ingress.yaml` | routes HTTPS locales (`values-local.yaml`, `*.127.0.0.1.sslip.io`, sans cert-manager) |
| `apps/prod/ingress.yaml` | routes HTTPS prod (`baseDomain` à renseigner, voir §5) |

`bootstrap/` est hors de `apps/` : la racine ne se gère pas elle-même (pas de boucle).
Les Applications des charts tierces utilisent deux sources : le chart (version épinglée) et ce repo en `ref: values`
pour lire `platform/<composant>/values.yaml` : les valeurs restent à un seul endroit, comme avant.

| Application | Vague | Source | Namespace |
|---|---|---|---|
| `sealed-secrets` | 0 | chart `sealed-secrets` 2.22.0 | `sealed-secrets` |
| `traefik` | 0 | chart `traefik` 42.3.0 | `traefik` |
| `cert-manager` | 0 | `oci://quay.io/jetstack/charts/cert-manager` v1.21.3 | `cert-manager` |
| `cert-manager-issuers` | 1 | `platform/cert-manager/issuers/` | `cert-manager` |
| `ingress` | 2 | `platform/ingress/` (release `kube12-ingress`) | `kube-system` (les Ingress sont créées dans le namespace de chaque route) |
| `kube-app` | 3 | repo `kube-app`, dossier `deploy/` | `app` |

Pourquoi ces vagues : les `ClusterIssuer` ont besoin des CRDs cert-manager (vague 1 après la 0) ; les Ingress ont besoin
de Traefik et des issuers (vague 2) ; l'application passe en dernier (vague 3).

## 2. Prérequis : santé des Applications

Argo CD n'évalue **pas** la santé d'une Application enfant par défaut : sans réglage, la racine passerait à la vague
suivante sans attendre que la précédente soit `Healthy`. Le réglage est dans `platform/argocd/values.yaml`
(`configs.cm."resource.customizations.health.argoproj.io_Application"`). Si Argo CD est déjà installé, mettre à jour la release :

```bash
helm upgrade argocd argo-cd --repo https://argoproj.github.io/argo-helm --version 10.18.0 \
  -n argocd -f platform/argocd/values.yaml --wait
```

## 3. Bootstrap local (kind)

Prérequis : cluster kind (`ansible-playbook local.yml`) et Argo CD installé + repo infra enregistré (`docs/argocd.md`).

**Cluster neuf** (Argo CD seul installé à la main) :

```bash
kubectl apply -f bootstrap/root-local.yaml
kubectl -n argocd get applications -w
```

**Cluster où Traefik / cert-manager / sealed-secrets / `kube12-ingress` ont déjà été installés avec `helm`** : désinstaller
d'abord ces releases (en local la coupure est sans importance), sinon deux « propriétaires » se disputent les mêmes objets :

```bash
helm uninstall traefik -n traefik
helm uninstall kube12-ingress -n kube-system
# idem cert-manager / sealed-secrets s'ils ont été installés à la main
kubectl apply -f bootstrap/root-local.yaml
```

Ne pas désinstaller Argo CD lui-même : il reste installé par Ansible / `helm` (le rôle `argocd`).

Attendu : `root` puis les 6 enfants `Synced` + `Healthy`, dans l'ordre des vagues. `kube-app` reste en erreur
(`deploy` introuvable) tant que le repo `kube-app` n'a pas de dossier `deploy/` : c'est normal et sans effet sur le reste.
`ingress` reste en erreur tant que `platform/ingress` (#71) n'est pas sur `develop`.

## 4. Tests d'acceptation

**Un `git push` déclenche le déploiement sans action manuelle.** Argo CD interroge Git toutes les 3 minutes par défaut.

1. Dans une branche suivie (`develop`), changer une valeur, par exemple les `resources` dans `platform/cert-manager/values.yaml`
   (ou ajouter un fichier `apps/common/<composant>.yaml`).
2. `git push`.
3. Sans rien lancer d'autre, l'Application passe `OutOfSync` puis `Synced` en ≤ 3 min
   (`kubectl -n argocd get applications`, ou l'UI ; un clic sur *Refresh* accélère).

**Self-heal : une modification manuelle est corrigée.**

```bash
kubectl -n sealed-secrets get deploy                               # relever le nom exact du Deployment
kubectl -n sealed-secrets scale deploy sealed-secrets --replicas=3  # ou : kubectl edit deploy sealed-secrets
kubectl -n sealed-secrets get deploy -w                            # revient à la valeur de Git en quelques secondes
```

L'Application passe brièvement `OutOfSync` puis revient `Synced` (le journal est visible dans *History and Rollback* de l'UI).

**Prune : un fichier supprimé de Git supprime la ressource.** Supprimer `apps/common/<composant>.yaml`, push :
l'Application enfant disparaît, et ses ressources avec elle (finalizer `resources-finalizer.argocd.argoproj.io`).

## 5. Prod (AWS)

L'IP publique de kube-1 change à chaque recréation de l'infra. Dans `apps/prod/ingress.yaml`, remplacer
`baseDomain: a-renseigner.sslip.io` par `<IP publique de kube-1>.sslip.io` (même valeur que `base_domain`
dans `ansible/inventory/group_vars/all/aws_outputs.yml`) et pousser. Puis, une seule fois par cluster :

```bash
kubectl apply -f bootstrap/root-prod.yaml
```

Les ClusterIssuers `letsencrypt-staging` / `letsencrypt-prod` sont déployés ensemble ; `issuer` vaut `letsencrypt-staging`
dans `apps/prod/ingress.yaml` : passer à `letsencrypt-prod` une fois le certificat de test validé (quotas : `docs/cert-manager.md`).

## 6. Ajouter un composant

1. Créer `platform/<composant>/values.yaml` (ou le dossier de manifests).
2. Copier une Application de `apps/common/` (chart tiers : `traefik.yaml` ; manifests du repo : `cert-manager-issuers.yaml`),
   adapter nom, chart / chemin, namespace, **vague** (le composant dépend-il d'un autre ?).
3. `git push` : la racine détecte le nouveau fichier.

Un composant propre à un seul environnement va dans `apps/local/` ou `apps/prod/`.

## 7. Passer de `develop` à `main`

Les `targetRevision: develop` (racines et Applications) servent tant que les composants ne sont pas sur `main`.
À la bascule : remplacer `develop` par `main` dans `bootstrap/` et `apps/`, puis ré-appliquer la racine (`kubectl apply -f bootstrap/root-*.yaml`).

## 8. Dépannage

| Symptôme | Cause / correction |
|---|---|
| Enfant en `Unknown` / `ComparisonError` : *app path does not exist* | dossier absent de la branche suivie (`platform/ingress` avant #71, `deploy/` du repo `kube-app`) |
| `authentication required` sur un des repos | repo non enregistré dans Argo CD : `docs/argocd.md` §3 |
| `cert-manager` : erreur OCI | vérifier l'accès à `quay.io` depuis le cluster ; version `v1.21.3` avec le `v` |
| `cert-manager-issuers` : *no matches for kind ClusterIssuer* | CRDs pas encore prêtes : le `retry` réessaie ; sinon vérifier que `cert-manager` est `Healthy` |
| Les vagues ne s'attendent pas | santé des Applications non activée (§2) : `kubectl -n argocd get cm argocd-cm -o yaml \| grep Application` |
| Un `kubectl edit` reste en place | `selfHeal` absent ou Application en `Unknown` ; `kubectl -n argocd get app <nom> -o yaml \| grep -A3 automated` |
| Les changements Git tardent | polling 3 min : *Refresh* dans l'UI, ou `kubectl -n argocd annotate app <nom> argocd.argoproj.io/refresh=hard --overwrite` |
| Ressource en doublon / conflit avec une release `helm` | composant installé à la main : `helm uninstall` d'abord (§3) |

## 9. Limites connues

- Argo CD n'est pas géré par lui-même (installé par Ansible) ; l'amorçage reste un `kubectl apply` manuel par cluster.
- Aucun webhook GitHub : le déclenchement par push passe par le polling (≤ 3 min).
- Les SealedSecrets ne sont pas encore rangés dans un dossier suivi : ils iront dans `apps/` avec leur composant.
