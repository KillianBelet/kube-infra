# Registry privé : GHCR et imagePullSecret (#38)

L'image de l'application est construite par la CI du repo `kube-app` (#53) et poussée sur le GitHub Container
Registry, en privé. Le cluster la tire avec un secret de pull scellé.

| | |
|---|---|
| Image | `ghcr.io/killianbelet/kube-app:<SHA du commit>` (jamais `latest`) |
| Build et push | `.github/workflows/image.yml` du repo `kube-app`, sur `develop` et `main` |
| Secret de pull | `ghcr-pull` (type `kubernetes.io/dockerconfigjson`), namespace `app` |
| Fichiers | `platform/kube-app/` : `kustomization.yaml`, `seal-secrets.sh`, `ghcr-pull.sealed.yaml` |
| Déploiement | deuxième source de l'Application `kube-app` (`apps/common/kube-app.yaml`), avant les pods (wave -1) |

## 1. Choix

- **GHCR** plutôt qu'un registry dans le cluster : rien à héberger ni à sauvegarder, la CI GitHub y pousse avec
  son `GITHUB_TOKEN`, et le package suit les droits du repo `kube-app`.
- **Token en lecture seule** pour le cluster : un token GitHub classique avec le seul droit `read:packages`. Il ne
  peut ni pousser d'image ni lire le code.
- **Secret scellé dans Git** avec la clé de l'équipe, comme les autres secrets (`platform/sealed-secrets/`).

## 2. Mise en place

1. **Package privé** (propriétaire du repo `kube-app`) : GitHub → Packages → `kube-app` → *Package settings* →
   *Change visibility* → Private. Dans *Manage Actions access*, le repo `kube-app` garde le droit d'écriture.
2. **Token** : GitHub → *Settings* → *Developer settings* → *Personal access tokens (classic)* → droit
   `read:packages` uniquement, sans expiration courte avant la soutenance. Le compte doit avoir accès au repo
   `kube-app`.
3. **Sceller** (sans cluster, avec le certificat de l'équipe) :

   ```bash
   GHCR_USER=<login GitHub> GHCR_TOKEN=<token> ./platform/kube-app/seal-secrets.sh
   git add platform/kube-app
   ```

   Le script écrit `ghcr-pull.sealed.yaml` et l'ajoute au `kustomization.yaml`. Pour changer de token, le relancer.
4. Le Deployment de l'application référence le secret (`imagePullSecrets: [{name: ghcr-pull}]`, #55).

## 3. Vérifier

Pull anonyme refusé :

```bash
TOKEN=$(curl -s "https://ghcr.io/token?scope=repository:killianbelet/kube-app:pull" | jq -r .token)
curl -s -H "Authorization: Bearer $TOKEN" https://ghcr.io/v2/killianbelet/kube-app/tags/list
# attendu : DENIED ou NAME_UNKNOWN, jamais une liste de tags
```

Pull depuis le cluster :

```bash
kubectl -n app get secret ghcr-pull -o jsonpath='{.type}'     # kubernetes.io/dockerconfigjson
kubectl -n app run pull-test --image=ghcr.io/killianbelet/kube-app:<sha> --restart=Never \
  --overrides='{"spec":{"imagePullSecrets":[{"name":"ghcr-pull"}],"containers":[{"name":"pull-test","image":"ghcr.io/killianbelet/kube-app:<sha>","resources":{"requests":{"cpu":"10m","memory":"32Mi"},"limits":{"memory":"64Mi"}}}]}}'
kubectl -n app get pod pull-test        # Running : l'image a été tirée
kubectl -n app delete pod pull-test
```

Le même pod sans `imagePullSecrets` doit rester en `ErrImagePull`.

Testé sur kind : secret scellé avec le certificat de l'équipe, déchiffré par le contrôleur en
`kubernetes.io/dockerconfigjson` pour `ghcr.io`.

## 4. Dépannage

| Symptôme | Piste |
|---|---|
| `ErrImagePull`, `401 Unauthorized` | token expiré ou sans `read:packages`, ou compte sans accès au repo `kube-app` |
| `ErrImagePull`, `not found` | tag absent : la CI n'a pas tourné sur ce commit (onglet Actions du repo `kube-app`) |
| secret `ghcr-pull` absent | `kubectl -n app describe sealedsecret ghcr-pull` : scellé avec un autre certificat que celui de l'équipe |
| pull anonyme accepté | package encore public (§ 2, étape 1) |
