# ValidatingAdmissionPolicy : contrôle des requêtes à l'apiserver (#52)

Politiques natives de Kubernetes (CEL) évaluées par kube-apiserver : aucun composant à installer.
Déployées par Argo CD (Application `admission-policies`, wave -1, [gitops.md](gitops.md)).

## 1. Règles

| Policy | Refuse | Contrôle |
|---|---|---|
| `kube12-disallow-latest-tag` | image en `:latest` **ou sans tag** (équivalent) ; une image épinglée par digest est acceptée | conteneurs, initContainers, conteneurs éphémères |
| `kube12-require-resources` | conteneur sans `requests.cpu`, `requests.memory` ou `limits.memory` | conteneurs, initContainers |
| `kube12-disallow-privileged` | `securityContext.privileged: true` | conteneurs, initContainers, conteneurs éphémères |

- Objets contrôlés : Pod, Deployment, StatefulSet, DaemonSet, ReplicaSet, Job, CronJob. Un Deployment
  non conforme est refusé dès son envoi, avec le nom des conteneurs en cause.
- Namespaces exemptés (dans chaque binding) : `kube-system`, `kube-public`, `kube-node-lease`,
  `local-path-storage`. Tous les autres sont contrôlés, y compris `argocd`.
- **Pas de limite CPU obligatoire** : elle bride les pods, et Keycloak démarre très lentement avec
  (`platform/keycloak/values.yaml`). Pour l'exiger, ajouter `'cpu' in c.resources.limits` dans
  `manifests/require-resources.yaml` **et** une limite CPU à tous les composants.
- À la mise à jour, l'objet n'est contrôlé que si son modèle de pod change : un workload ancien peut
  encore être réduit (rolling update) sans être bloqué.

```
platform/admission-policies/
├── manifests/   une policy et son binding par fichier, kustomization.yaml (labels) (déployés par Argo CD)
├── tests/       refused/ et accepted/ (jamais déployés)
├── test.sh          manifests refusés / acceptés, et audit du cluster
└── check-charts.sh  charts du repo rendus avec leurs values
```

## 2. Mise en service

Les policies s'appliquent aux **nouveaux** pods : un composant non conforme continue de tourner, mais
ses pods ne sont plus recréés (redémarrage de nœud, `rollout restart`...).

1. **Essayer en local avant de merger** (Argo CD lit `develop`, pas la branche) :

   ```bash
   kubectl apply -k platform/admission-policies/manifests/
   ./platform/admission-policies/test.sh
   ./platform/admission-policies/check-charts.sh     # values de la branche
   ./platform/admission-policies/test.sh --audit     # ce qui tourne déjà
   ```

   Sur un cluster déployé depuis `develop`, `--audit` signale les composants dont les nouvelles
   valeurs ne sont pas encore appliquées. Sans merge ensuite, retirer les policies :
   `kubectl delete -k platform/admission-policies/manifests/`.
2. **Mettre à jour Argo CD avant le merge** : il n'est pas géré par GitOps, ses nouvelles
   `resources` ne sont pas appliquées toutes seules. Sans cela, ses pods ne pourront pas être recréés.

   ```bash
   # local
   helm upgrade argocd argo-cd --repo https://argoproj.github.io/argo-helm --version 10.18.0 \
     -n argocd -f platform/argocd/values.yaml --wait
   # prod, depuis ansible/
   ansible-playbook -i inventory argocd.yml
   ```
3. Merger dans `develop` : Argo CD déploie les policies et les nouvelles valeurs des composants.
4. Relancer `test.sh` puis `test.sh --audit` : tout doit être `OK`.

Les Jobs lancés par les charts et les pods isolés ne sont pas couverts par `--audit`. Après le
déploiement, chercher les refus : `kubectl get events -A | grep -i ValidatingAdmissionPolicy`, et
l'état des Applications (`kubectl -n argocd get applications`).

## 3. Exemple de refus

Forme du message (les noms dépendent du manifest) :

```
deployments.apps "test-latest" is forbidden: ValidatingAdmissionPolicy 'kube12-disallow-latest-tag'
with binding 'kube12-disallow-latest-tag' denied request: Tag :latest interdit (ou tag absent) :
app (nginx:latest). Indiquer un tag de version ou un digest.
```

## 4. Écrire un manifest conforme

```yaml
containers:
  - name: app
    image: ghcr.io/exemple/app:1.4.2      # jamais latest
    resources:
      requests: {cpu: 50m, memory: 128Mi}
      limits: {memory: 256Mi}
```

`kubectl debug` : donner une image avec un tag (`--image=busybox:1.37`).

## 5. Dépannage

| Symptôme | Cause / correction |
|---|---|
| Application `OutOfSync`, erreur `denied request` | le manifest ou les values du composant ne respectent pas la règle citée |
| Deployment accepté mais aucun pod | refus au niveau du ReplicaSet : `kubectl -n <ns> describe rs` |
| Chart tiers sans réglage de ressources pour un conteneur | chercher la clé dans les values du chart (`initContainers`, jobs de hook) |
| Besoin de désactiver en urgence | retirer le fichier de `manifests/` et de son `kustomization.yaml` par Git (le `selfHeal` annule un `kubectl delete`) |

Les nouveaux composants (monitoring, logging, dex, Headlamp...) doivent respecter ces règles. Un agent
qui aurait besoin de `privileged` ne peut pas tourner hors des namespaces exemptés sans modifier le binding.
