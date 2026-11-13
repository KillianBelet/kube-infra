# Runbook : reconstruire le cluster de zéro (#63)

Procédure complète, de « rien sur AWS » à « tous les services en HTTPS », puis retour à zéro.
Chaque étape renvoie à la doc détaillée du composant ; ici, seulement l'ordre, les commandes
et ce qu'il faut voir avant de passer à la suite.

Durée : **≈ 40 min**, dont ≈ 30 min d'attente. Coût : quelques euros par jour d'infra allumée
([infra-aws.md](infra-aws.md) § 5).

```
 1. provision-aws.yml        VPC, 3 VM, EFS, Elastic IP          ≈ 5 min
 2. site.yml                 Kubernetes, Calico, driver EFS       ≈ 10 min
 3. clé Sealed Secrets       restaurée AVANT le bootstrap         ≈ 1 min
 4. argocd.yml               Argo CD + dépôts Git                 ≈ 3 min
 5. baseDomain + root-prod   Argo CD déploie tout le reste        ≈ 10 min
 6. vérifications            nœuds, Applications, HTTPS, tests    ≈ 10 min
```

## 0. Prérequis (une fois par poste)

- WSL Ubuntu, AWS CLI configurée, collections Ansible : [infra-aws.md](infra-aws.md) § 2.
- Le repo à jour sur `develop` (`git pull`) : Argo CD déploie ce qui est **sur GitHub**, pas en local.
- La dernière sauvegarde de la clé Sealed Secrets (`sealed-secrets-key.yaml`), si des
  SealedSecrets sont déjà versionnés (§ 3). Elle n'est jamais dans Git.

Toutes les commandes Ansible se lancent depuis `ansible/`, toujours avec `-i inventory`.

## 1. Infrastructure AWS

```bash
ansible-playbook -i inventory provision-aws.yml
```

Attendu : `failed=0`, et `inventory/group_vars/all/aws_outputs.yml` écrit. Noter l'IP publique :

```bash
grep -E 'public_ip|base_domain' inventory/group_vars/all/aws_outputs.yml
```

Coéquipiers : leur IP dans `admin_cidrs`, leur clé SSH via `team-access.yml` ([infra-aws.md](infra-aws.md) § 4).

## 2. Cluster Kubernetes

```bash
ansible-playbook -i inventory site.yml
ansible-playbook -i inventory tests/efs.yml      # stockage partagé entre nœuds
export KUBECONFIG=~/.kube-12/kubeconfig-aws
kubectl get nodes -L kube12/node                 # 3 nœuds Ready, labels kube-1/2/3
```

`Host key verification failed` : la nouvelle VM a réutilisé une ancienne IP, le fichier
`~/.ssh/kube-12_known_hosts` est nettoyé par `destroy-aws.yml` ; sinon le supprimer.
Détails et dépannage : [cluster-ansible.md](cluster-ansible.md).

## 3. Clé Sealed Secrets (avant Argo CD)

Les SealedSecrets du repo ne sont déchiffrables qu'avec la clé privée du **premier** cluster.
On la remet en place avant que le contrôleur démarre : il la trouve et ne génère pas de nouvelle clé.

```bash
kubectl create namespace sealed-secrets
kubectl apply -f /chemin/hors-git/sealed-secrets-key.yaml
```

Pas de sauvegarde (premier cluster, ou aucun SealedSecret versionné) : sauter cette étape,
puis **sauvegarder la clé générée** dès que le contrôleur tourne (§ 7).

## 4. Argo CD

```bash
ansible-playbook -i inventory argocd.yml          # installe Argo CD, enregistre les dépôts
kubectl -n argocd get pods                        # tous Running
```

Détails : [argocd.md](argocd.md) § 4.

## 5. Tout le reste, par Git

L'IP publique est la seule valeur qui change d'un cluster à l'autre. Dans
`apps/prod/ingress.yaml`, mettre `baseDomain: <IP publique>.sslip.io` (valeur `base_domain`
du § 1), puis **PR vers `develop`** (branche protégée : une review).

Une fois mergée :

```bash
kubectl apply -f ../bootstrap/root-prod.yaml
kubectl -n argocd get applications -w             # Ctrl+C quand tout est Synced / Healthy
```

Les vagues s'enchaînent ([gitops.md](gitops.md)) : sealed-secrets, traefik, cert-manager →
issuers → ingress → application. `kube-app` reste en erreur tant que le repo applicatif n'a pas
de `deploy/` : sans effet sur le reste.

## 6. Vérifications

| Vérification | Commande | Attendu |
|---|---|---|
| Nœuds | `kubectl get nodes` | 3 `Ready` |
| Applications | `kubectl -n argocd get applications` | `Synced` + `Healthy` |
| Ports 80/443 | `curl -sI http://<IP>/ \| head -1` | `308` ou `301` (redirection HTTPS) |
| Certificats | `kubectl get certificate -A` | `READY=True` |
| Argo CD en HTTPS | `ansible-playbook -i inventory tests/argocd.yml` | `failed=0` |
| Certificat de bout en bout | `ansible-playbook -i inventory tests/tls.yml` | `failed=0` |

Puis dans le navigateur : `https://argocd.<IP>.sslip.io`, utilisateur `admin`, mot de passe :

```bash
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo
```

Le premier passage est sur `letsencrypt-staging` (navigateur : autorité « STAGING »). Une fois
les certificats `READY=True`, passer `issuer: letsencrypt-prod` dans `apps/prod/ingress.yaml`
(PR) pour le cadenas valide. Ne pas reconstruire en boucle avec `letsencrypt-prod` : 5 certificats
par hostname et par semaine ([cert-manager.md](cert-manager.md) § 7).

## 7. Avant d'éteindre ou de détruire

Sauvegarder la clé Sealed Secrets (elle change tous les 30 jours, les anciennes restent valides) :

```bash
kubectl -n sealed-secrets get secret -l sealedsecrets.bitnami.com/sealed-secrets-key \
  -o yaml > /chemin/hors-git/sealed-secrets-key.yaml
```

À ranger hors du repo (gestionnaire de mots de passe de l'équipe). Puis :

```bash
ansible-playbook -i inventory aws-power.yml -e power=stopped       # pause : même IP au redémarrage
ansible-playbook -i inventory destroy-aws.yml -e confirm=kube-12   # tout supprimer, EFS compris
```

Après `aws-power.yml -e power=running`, rien à refaire : même IP, cluster et Argo CD intacts.
Après `destroy-aws.yml`, recommencer au § 1 avec une **nouvelle IP** (donc nouveau § 5).

## 8. Si une étape échoue

| Étape | Symptôme | Où regarder |
|---|---|---|
| 1 | `VcpuLimitExceeded`, `UnauthorizedOperation` | [infra-aws.md](infra-aws.md) § 6 |
| 2 | nœud `NotReady`, `kubeadm` en échec | [cluster-ansible.md](cluster-ansible.md), dépannage |
| 4 | pods Argo CD en `Pending` / `CrashLoopBackOff` | `kubectl -n argocd describe pod <pod>` |
| 5 | Application `Unknown` / `ComparisonError` | [gitops.md](gitops.md) § 8 (chemin absent de `develop`, dépôt non enregistré) |
| 5 | `ingress` en erreur | `baseDomain` non mergé sur `develop`, ou namespace d'une route absent ([ingress.md](ingress.md) § 6) |
| 6 | certificat `READY=False` | [cert-manager.md](cert-manager.md) § 9 (port 80, quotas) |
| 6 | SealedSecret non déchiffré | clé du § 3 absente ou différente : la réappliquer, puis `kubectl -n sealed-secrets delete pod -l app.kubernetes.io/name=sealed-secrets` |

## 9. Limites connues

- L'IP publique est dans Git (`apps/prod/ingress.yaml`) : chaque reconstruction après
  `destroy-aws.yml` demande une PR. Un domaine fixe (DNS) supprimerait cette étape.
- La clé Sealed Secrets est sauvegardée à la main (§ 7) : l'oublier avant `destroy-aws.yml`
  rend les SealedSecrets du repo indéchiffrables ; il faut alors les re-sceller.
