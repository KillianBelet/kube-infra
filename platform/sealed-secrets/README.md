# Sealed Secrets

Controller : bitnami-labs/sealed-secrets, installé via Helm dans le namespace `sealed-secrets`.

## Installation du controller (une fois par cluster)

```bash
helm repo add sealed-secrets https://bitnami.github.io/sealed-secrets
helm repo update

kubectl create namespace sealed-secrets
helm install sealed-secrets sealed-secrets/sealed-secrets \
  --namespace sealed-secrets \
  --wait
```

## Installer kubeseal (CLI local, une fois par poste)

```bash
KUBESEAL_VERSION='0.27.1'
curl -OL "https://github.com/bitnami-labs/sealed-secrets/releases/download/v${KUBESEAL_VERSION}/kubeseal-${KUBESEAL_VERSION}-linux-amd64.tar.gz"
tar -xvzf kubeseal-${KUBESEAL_VERSION}-linux-amd64.tar.gz kubeseal
sudo install -m 755 kubeseal /usr/local/bin/kubeseal
```

## Clé de l'équipe

Tous les clusters (kind de chacun, AWS) utilisent la **même** clé, pour qu'un SealedSecret versionné se déchiffre partout.
Le certificat public est ici : `team-cert.crt`. La clé privée (`sealed-secrets-key.yaml`) n'est jamais dans Git :
elle se transmet en privé et s'applique **avant** l'installation du controller.

```bash
kubectl create namespace sealed-secrets
kubectl apply -f /chemin/hors-git/sealed-secrets-key.yaml
```

Avec le certificat, on chiffre sans être connecté au cluster : `kubeseal --cert platform/sealed-secrets/team-cert.crt`.
Détails : [docs/database.md](../../docs/database.md) § 3.

## Chiffrer un secret

```bash
kubectl create secret generic mon-secret \
  --dry-run=client \
  --from-literal=cle=valeur \
  -n <namespace-cible> \
  -o yaml | \
kubeseal \
  --cert platform/sealed-secrets/team-cert.crt \
  --format yaml > mon-secret-sealed.yaml
```

Toujours chiffrer avec `--cert platform/sealed-secrets/team-cert.crt` (le certificat de l'équipe), et non avec
la clé du cluster local : sinon le secret ne se déchiffre que sur votre cluster.

Le fichier `mon-secret-sealed.yaml` est le seul à commiter dans Git. Le `Secret` en clair ne doit jamais y figurer.

## Règle

Aucun secret en clair dans Git. Seul le `SealedSecret` chiffré est versionné.
