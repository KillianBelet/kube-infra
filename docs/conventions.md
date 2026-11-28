# Conventions des manifests (#80)

Règles communes à tous les composants : ressources, labels, Helm ou kustomize. Vérifiées par
`scripts/check-conventions.py`, sans cluster. Les ValidatingAdmissionPolicy (#52,
[admission-policies.md](admission-policies.md)) imposent déjà à l'apiserver les requests et la limite
mémoire ; la limite CPU et les labels ne sont vérifiés que par le script.

## 1. Ressources : requests et limits sur chaque conteneur

| | Rôle | Comment on la fixe |
|---|---|---|
| `requests.cpu` / `requests.memory` | ce que le scheduler réserve sur le nœud | usage normal observé |
| `limits.memory` | au-delà, le conteneur est tué (OOMKilled) | 2 à 4 × la request |
| `limits.cpu` | au-delà, le conteneur est ralenti (throttling), jamais tué | **large** : 100m à 2 vCPU |

Les limits CPU sont volontairement larges : une limite basse ralentit les démarrages lourds
(Keycloak, MySQL) sans rien protéger de plus. Elles servent de plafond si un pod s'emballe.

Sur un chart Helm, les ressources se règlent dans son `values.yaml` (clé `resources` du composant).
Sans clé prévue (conteneur d'init, Job d'installation), regarder `helm show values` : ces conteneurs
reprennent souvent les ressources du conteneur principal.

| Composant | requests (cpu / mem) | limits (cpu / mem) |
|---|---|---|
| Traefik | 50m / 64Mi | 500m / 256Mi |
| cert-manager (controller, webhook, cainjector) | 10m / 32-64Mi | 100-200m / 128-512Mi |
| Sealed Secrets | 10m / 32Mi | 200m / 128Mi |
| Argo CD (server, repo-server, controller) | 25-50m / 128-256Mi | 500m-1 / 512Mi-1Gi |
| MySQL (app), MySQL Keycloak | 50-100m / 384-512Mi | 1 / 768Mi-1Gi |
| Sauvegarde MySQL (CronJob) | 50m / 64Mi | 500m / 256Mi |
| Keycloak | 100m / 768Mi | 2 / 1Gi |
| dex | 10m / 32Mi | 200m / 128Mi |
| Prometheus | 100m / 512Mi | 1 / 1536Mi |
| Alertmanager, opérateur, node-exporter, kube-state-metrics | 10-20m / 32-64Mi | 100-200m / 64-256Mi |
| Grafana (+ sidecars) | 50m / 128Mi (10m / 64Mi) | 500m / 384Mi (100m / 128Mi) |

## 2. Labels recommandés

[Labels recommandés Kubernetes](https://kubernetes.io/docs/concepts/overview/working-with-objects/common-labels/),
sur **toutes** les ressources et sur les modèles de pods :

| Label | Valeur | Exemple |
|---|---|---|
| `app.kubernetes.io/name` | le composant | `traefik`, `mysql`, `letsencrypt-prod` |
| `app.kubernetes.io/part-of` | l'application dont il fait partie (= l'Application Argo CD) | `keycloak` pour la base de Keycloak |
| `app.kubernetes.io/component` | son rôle, si l'application en a plusieurs | `database`, `issuer`, `ingress`, `config` |
| `app.kubernetes.io/instance`, `managed-by` | posés par Helm et Argo CD | |

D'où ils viennent :
- **charts Helm** : `name`, `instance` et `managed-by` sont posés par le chart ; `part-of` par
  `commonLabels` (Traefik, Sealed Secrets, MySQL, Keycloak, dex), `global.commonLabels` (cert-manager) ;
  Argo CD pose déjà `part-of: argocd`.
- **manifests bruts** : `labels` dans le `kustomization.yaml` du dossier pour ce qui est commun,
  `app.kubernetes.io/name` dans le fichier quand il change d'une ressource à l'autre.
- **chart `platform/ingress`** : `name` et `part-of` = nom de la route, `component: ingress`.
- **kube-prometheus-stack** : le chart pose `part-of` partout, mais pas `name` sur ses Services, règles et
  ServiceMonitors, et `commonLabels` créerait des doublons ailleurs. Le script ne lui demande que `part-of`
  (`NAME_OPTIONAL`) ; ses pods ont bien `name`.

Ne jamais ajouter de label dans un `selector` (Deployment, StatefulSet, Service) ni dans les
`volumeClaimTemplates` d'un StatefulSet : ces champs ne sont pas modifiables, Argo CD échouerait
sur un cluster existant. `commonLabels` des charts utilisés et `labels` de kustomize (sans
`includeSelectors`) ne les touchent pas.

## 3. Helm ou kustomize

| Cas | Outil | Exemples |
|---|---|---|
| Composant tiers avec un chart officiel | **Helm** (chart + `values.yaml` dans `platform/<composant>/`) | Traefik, cert-manager, Argo CD, MySQL, Keycloak, dex |
| Manifests à nous qui dépendent d'une variable (domaine) | **petit chart Helm** dans le repo | `platform/ingress`, `platform/dex/config` |
| Manifests à nous, identiques partout | **kustomize** (`kustomization.yaml` : liste des fichiers, labels communs, générateurs) | `platform/cert-manager/issuers`, `platform/mysql/manifests`, `platform/keycloak/{db,manifests}` |
| Application, différente en local et en prod | **kustomize** base + overlays dans le repo applicatif | `kube-app/deploy/` (#55) |

Argo CD reconnaît seul un dossier avec `kustomization.yaml` ou `Chart.yaml` : rien à déclarer dans
l'Application. Un dossier avec `kustomization.yaml` ne déploie **que** les fichiers listés dans
`resources` : tout nouveau fichier doit y être ajouté.

## 4. Vérifier

Sans cluster, avant une PR (helm, kubectl et python3-yaml, installés par `local.yml` sauf PyYAML) :

```bash
python3 scripts/check-conventions.py              # local : apps/common + apps/local
python3 scripts/check-conventions.py --env prod   # prod  : apps/common + apps/prod
```

Le script rend chaque Application de `apps/` comme Argo CD (chart, `valueFiles`, `valuesObject`,
kustomize), plus Argo CD lui-même, et liste les conteneurs sans requests/limits et les ressources
sans `name` / `part-of`. Code de sortie 1 s'il y a un écart.

Sur un cluster qui tourne :

```bash
# conteneurs sans requests ou limits complets (hors kube-system)
kubectl get pods -A -o json | jq -r '.items[] | select(.metadata.namespace != "kube-system")
  | .metadata.namespace as $ns | .metadata.name as $p
  | (.spec.initContainers // []) + .spec.containers | .[]
  | select((.resources.requests.cpu and .resources.requests.memory
            and .resources.limits.cpu and .resources.limits.memory) | not)
  | "\($ns)/\($p) \(.name)"'

# pods sans app.kubernetes.io/name
kubectl get pods -A -l '!app.kubernetes.io/name' --field-selector metadata.namespace!=kube-system
```

Les deux commandes ne doivent rien afficher. Exceptions connues : `kube-system` (Calico, CoreDNS,
kube-proxy, gérés par kubeadm), et `local-path-storage` en local (fourni par kind).
