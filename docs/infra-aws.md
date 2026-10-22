# Infrastructure AWS (Ansible)

Tickets : #28 (EFS, security group NFS, IAM). Le cluster Kubernetes posé dessus est
décrit dans [cluster-ansible.md](cluster-ansible.md).

Toute l'infrastructure est du code : n'importe quel membre peut la recréer **sur son propre
compte AWS**, puis la détruire entièrement. Aucune information de compte n'est dans le repo.

## 1. Ce qui est créé

| Ressource | Nom (tag `Project=kube-12`) | Détail |
|---|---|---|
| VPC | `kube-12-vpc` | `10.0.0.0/16`, DNS activé |
| Subnet public | `kube-12-subnet` | `10.0.0.0/24`, zone `eu-north-1a` |
| Internet gateway + table de routage | `kube-12-igw`, `kube-12-rt` | sortie Internet du subnet |
| Security group nœuds | `kube-12-nodes` | tout le trafic entre nœuds ; 22 et 6443 depuis `admin_cidrs` ; 80/443 depuis Internet |
| Security group EFS | `kube-12-efs` | NFS (2049) depuis les nœuds uniquement |
| Rôle IAM + profil d'instance | `kube-12-node` | `AmazonEFSCSIDriverPolicy` (driver EFS, sans clé) |
| Clé SSH | `kube-12` | générée en local dans `~/.ssh/kube-12` (jamais dans le repo) |
| 3 instances EC2 | `kube-1`, `kube-2`, `kube-3` | `c7i-flex.large` (2 vCPU, 4 Go), Ubuntu 24.04, disque gp3 30 Go, IP privées fixes `10.0.0.235/.113/.115` |
| Elastic IP | `kube-12-kube-1` | IP publique fixe de kube-1 (SSH, API, Traefik, domaines sslip.io) |
| Amazon EFS | `kube-12-efs` | chiffré, un mount target dans le subnet |

Sécurité :
- IMDSv2 obligatoire sur les instances (hop limit 2 pour que le driver EFS y accède depuis un pod) ;
- `source_dest_check` désactivé : nécessaire au routage des pods par Calico ;
- SSH et API Kubernetes fermés à Internet, ouverts seulement aux IP de `admin_cidrs`.

Les paramètres sont dans `ansible/inventory/group_vars/all/aws.yml` (région, type d'instance,
AMI, CIDR…) et `cluster.yml` (noms et IP privées des nœuds).

## 2. Prérequis (une fois)

1. **Compte AWS** (le Free plan suffit) et un **budget avec alerte** : *Billing → Budgets*.
2. **Utilisateur IAM** pour Ansible avec une clé d'accès (*IAM → Users → Create access key*,
   cas « CLI »). Droits nécessaires : EC2, VPC, EFS, IAM (rôles et profils d'instance).
   Le plus simple pour un projet étudiant : `AmazonEC2FullAccess`, `AmazonElasticFileSystemFullAccess`, `IAMFullAccess`.
3. **AWS CLI** configurée avec cette clé, région `eu-north-1` :
   ```bash
   aws configure          # la clé reste dans ~/.aws/credentials, jamais dans le repo
   aws sts get-caller-identity
   ```
4. **Dépendances Ansible** :
   ```bash
   sudo apt install -y python3-boto3
   cd ansible && ansible-galaxy collection install -r requirements.yml
   ```
5. **Quota vCPU** : 3 instances × 2 vCPU = 6 vCPU. Si la création échoue avec
   `VcpuLimitExceeded`, demander une hausse du quota *Running On-Demand Standard instances*
   (*Service Quotas → EC2*), par exemple à 16.

## 3. Cycle de vie

Depuis `ansible/` :

```bash
ansible-playbook -i inventory provision-aws.yml        # crée tout (≈ 5 min), rejouable
ansible-playbook -i inventory site.yml                 # installe Kubernetes (≈ 10 min)

ansible-playbook -i inventory aws-power.yml -e power=stopped   # éteint les 3 VM (soir, week-end)
ansible-playbook -i inventory aws-power.yml -e power=running   # les rallume (même IP publique)

ansible-playbook -i inventory destroy-aws.yml -e confirm=kube-12   # supprime TOUT, données EFS comprises
```

`provision-aws.yml` écrit `inventory/group_vars/all/aws_outputs.yml` (IP publique, id EFS…),
ignoré par git. Les autres membres de l'équipe le recréent depuis `aws_outputs.yml.example`
avec l'IP communiquée par celui qui a provisionné.

Ordre de suppression dans `destroy-aws.yml` : instances, Elastic IP, EFS, clé, IAM, puis le
réseau (security groups, routes, subnet, gateway, VPC). Le playbook refuse de tourner sans
`-e confirm=kube-12`.

## 4. Accès de l'équipe

- **Ouvrir SSH et l'API à un membre** : ajouter son IP publique à `admin_cidrs` et relancer
  `provision-aws.yml` (seule la règle du security group change) :
  ```bash
  ansible-playbook -i inventory provision-aws.yml -e '{"admin_cidrs": ["1.2.3.4/32", "5.6.7.8/32"]}'
  ```
  Par défaut, `admin_cidrs` contient uniquement l'IP de la machine qui lance le playbook.
- **Autoriser sa clé SSH** : copier `files/team_authorized_keys.example` en
  `files/team_authorized_keys` (ignoré par git), y mettre les clés publiques, puis :
  ```bash
  ansible-playbook -i inventory team-access.yml
  ```
  La liste est exclusive : une clé retirée du fichier perd l'accès au prochain passage.

## 5. Coûts

Ordre de grandeur, région `eu-north-1`, à vérifier dans *Billing* :

| Ressource | Quand ça coûte |
|---|---|
| 3 × `c7i-flex.large` | seulement allumées → `aws-power.yml -e power=stopped` dès qu'on ne s'en sert plus |
| 3 disques gp3 30 Go | tant qu'ils existent, même VM éteintes (≈ quelques $/mois au total) |
| Elastic IP | tant qu'elle existe |
| EFS | au volume de données stockées (faible pour ce projet) |

Pour ne plus rien payer : `destroy-aws.yml`. Tout se recrée en ≈ 15 min
(`provision-aws.yml` puis `site.yml`), avec une **nouvelle IP publique** (donc de nouveaux
domaines sslip.io).

## 6. Dépannage

| Symptôme | Cause | Solution |
|---|---|---|
| `NoCredentialsError` / `Unable to locate credentials` | AWS CLI pas configurée dans ce shell (WSL ≠ Windows) | `aws configure` dans le même terminal |
| `VcpuLimitExceeded` | quota vCPU du compte trop bas | hausse de quota (voir prérequis) |
| `UnauthorizedOperation` | droits IAM insuffisants | ajouter les politiques listées en prérequis |
| SSH `Connection timed out` | IP de la machine absente de `admin_cidrs` (IP changée, autre réseau) | relancer `provision-aws.yml` depuis cette machine ou avec `-e admin_cidrs=…` |
| `destroy-aws.yml` bloque sur le VPC | une ressource créée à la main y est encore attachée | la supprimer dans la console, relancer |
| `Missing required library boto3` | boto3 absent | `sudo apt install -y python3-boto3` |
