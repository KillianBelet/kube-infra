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

## Chiffrer un secret

```bash
kubectl create secret generic mon-secret \
  --dry-run=client \
  --from-literal=cle=valeur \
  -n <namespace-cible> \
  -o yaml | \
kubeseal \
  --controller-name=sealed-secrets \
  --controller-namespace=sealed-secrets \
  --format yaml > mon-secret-sealed.yaml
```

Le fichier `mon-secret-sealed.yaml` est le seul à commiter dans Git. Le `Secret` en clair ne doit jamais y figurer.

## Règle

Aucun secret en clair dans Git. Seul le `SealedSecret` chiffré est versionné.
