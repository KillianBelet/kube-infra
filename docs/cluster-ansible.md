# Cluster Kubernetes de prod (Ansible + kubeadm)

Tickets : #23 inventaire, #24 rôle `common`, #25 control plane, #26 workers, #27 Calico,
#28 stockage EFS, #29 `site.yml` complet et ansible-lint.

## 1. Ce qu'on obtient

```
                Internet
                   │  22 (admins), 6443 (admins), 80/443 (tous)
                   ▼
   ┌───────────────────────────┐   IP publique fixe (Elastic IP)
   │ kube-1  10.0.0.235        │   control plane + worker
   │ apiserver, etcd, Traefik  │   porte d'entrée SSH (bastion) et HTTP(S)
   └─────────────┬─────────────┘
                 │ subnet 10.0.0.0/24 (tout le trafic autorisé entre nœuds)
       ┌─────────┴─────────┐
       ▼                   ▼
 kube-2 10.0.0.113    kube-3 10.0.0.115      workers, pas d'IP publique fixe
```

| | Valeur |
|---|---|
| OS | Ubuntu 24.04 LTS |
| Kubernetes | 1.36.4 (kubeadm, kubelet, kubectl bloqués avec `apt-mark hold`) |
| Runtime | containerd 2.x (dépôt Docker), cgroup driver `systemd` |
| CNI | Calico v3.33.0, pods en `192.168.0.0/16` (identique au local) |
| Labels | `kube12/node=kube-1`, `kube-2`, `kube-3` sur chaque nœud |
| Taint | aucun : kube-1 accepte aussi des pods |
| Stockage | StorageClass `efs-sc` (Amazon EFS, volumes partagés `ReadWriteMany`) |

Les mêmes conventions qu'en local (kind) : un manifest qui marche dans kind marche ici.

## 2. Arborescence

```
ansible/
├── ansible.cfg                     inventaire par défaut, SSH multiplexé
├── requirements.yml                collections Ansible nécessaires
├── site.yml                        construit le cluster (rejouable)
├── local.yml / local-down.yml      environnement local kind
├── inventory/
│   ├── hosts.yml                   groupes control_plane (kube-1) et workers (kube-2, kube-3)
│   └── group_vars/
│       ├── all/cluster.yml         versions, IP privées, CIDR, label, StorageClass (commun local/prod)
│       ├── all/ssh.yml             utilisateur, clé, known_hosts dédié, private_ip
│       ├── all/aws_outputs.yml     IP publique de kube-1 (généré, ignoré par git)
│       ├── control_plane.yml       kube-1 joint sur l'IP publique
│       └── workers.yml             workers joints en rebond par kube-1
└── roles/
    ├── common/                     prérequis des 3 nœuds
    ├── control_plane/              kubeadm init, kubeconfig, jeton de join
    ├── worker/                     kubeadm join
    ├── calico/                     réseau des pods
    └── efs_csi/                    helm, driver EFS CSI, StorageClass efs-sc
tests/
└── efs.yml                         test : un volume partagé entre kube-2 et kube-3
```

**Règle** : aucune IP ni version en dur dans les rôles ; tout vient de `group_vars`.

## 3. Utilisation

Prérequis : Ansible (WSL Ubuntu, macOS ou Linux), la clé SSH autorisée sur les nœuds,
l'IP publique de kube-1.

```bash
cd ansible
ansible-galaxy collection install -r requirements.yml

# IP publique de kube-1 (demander à l'équipe si on n'a pas provisionné soi-même)
cp inventory/group_vars/all/aws_outputs.yml.example inventory/group_vars/all/aws_outputs.yml

ansible -i inventory all -m ping                 # 3 × SUCCESS
ansible-playbook -i inventory site.yml           # construit ou met à niveau le cluster
ansible-playbook -i inventory site.yml           # 2e passage : changed=0 attendu

export KUBECONFIG=~/.kube-12/kubeconfig-aws      # écrit par le playbook
kubectl get nodes -L kube12/node
```

Avec sa propre clé SSH plutôt que `~/.ssh/kube-12` : ajouter `-e ssh_key_path=~/.ssh/id_ed25519`.

`site.yml` se rejoue sans risque : un nœud déjà initialisé ou déjà dans le cluster est sauté.

## 4. Ce que fait chaque rôle, et pourquoi

### `common` (#24) : les 3 nœuds

| Étape | Pourquoi |
|---|---|
| hostname = `kube-1/2/3`, entrées `/etc/hosts` | les nœuds Kubernetes portent les noms du schéma, pas `ip-10-0-0-x` |
| swap désactivé (et commenté dans fstab) | exigé par le kubelet |
| modules `overlay`, `br_netfilter` + sysctl `ip_forward`, `bridge-nf-call-*` | réseau des pods et des Services |
| containerd depuis le dépôt Docker | Kubernetes 1.36 demande containerd 2.x, plus récent que celui d'Ubuntu |
| config containerd régénérée une seule fois (marqueur `/etc/containerd/.kube12`) | le paquet désactive le plugin CRI par défaut ; le marqueur évite d'écraser la config à chaque passage |
| `SystemdCgroup = true` | containerd et kubelet doivent utiliser le même gestionnaire de cgroups |
| kubelet/kubeadm/kubectl `1.36.4-1.1` + `hold` | même version partout, un `apt upgrade` ne casse pas le cluster |

Le kubelet redémarre en boucle tant que `kubeadm init`/`join` n'a pas eu lieu : c'est normal.

### `control_plane` (#25) : kube-1

- Config kubeadm générée depuis `templates/kubeadm-config.yaml.j2` :
  - `taints: []` → kube-1 est aussi worker ;
  - `node-labels: kube12/node=kube-1`, `node-ip` = IP privée ;
  - `certSANs` = IP privée, **IP publique**, `kube-1` → `kubectl` fonctionne depuis nos PC ;
  - `controlPlaneEndpoint` = IP privée de kube-1.
- `kubeadm init` lancé seulement si `/etc/kubernetes/admin.conf` n'existe pas.
- kubeconfig admin copié pour `ubuntu` sur kube-1, et en local dans `~/.kube-12/kubeconfig-aws`
  (adresse remplacée par l'IP publique ; fichier hors du repo, à ne jamais committer).
- Crée un jeton de join valable 1 h, transmis aux workers.

**OIDC (#42)** : renseigner dans les variables du rôle `oidc_issuer_url` et `oidc_client_id`
(et si besoin `oidc_username_claim`, `oidc_groups_claim`), puis relancer `site.yml`.
Si la config kubeadm change après l'init, le manifest de l'apiserver est régénéré
(`kubeadm init phase control-plane apiserver`). Pas besoin de toucher aux fichiers du rôle.

### `worker` (#26) : kube-2, kube-3

- Lancé seulement si `/etc/kubernetes/kubelet.conf` n'existe pas.
- `JoinConfiguration` (plutôt que la commande `kubeadm join` brute) pour poser le label
  `kube12/node` et le `node-ip` dès l'arrivée du nœud.
- Le fichier de join contient le jeton : il est supprimé juste après.

### `calico` (#27)

- Même manifest et même version qu'en local, appliqué en `--server-side`.
- Attend que les 3 nœuds soient `Ready`, puis affiche `kubectl get nodes`.
- Encapsulation IP-in-IP : autorisée car le security group laisse passer tout le trafic entre nœuds.

### `efs_csi` (#28)

Ce qui existe avant, créé au provisionnement AWS :
- un système de fichiers **EFS** chiffré, avec un mount target dans le subnet des nœuds ;
- un security group qui n'autorise que le NFS (2049) depuis les nœuds ;
- un rôle IAM `AmazonEFSCSIDriverPolicy` attaché aux 3 VM (profil d'instance), et
  l'accès aux métadonnées de la VM ouvert aux pods (IMDSv2, hop limit 2) :
  le driver récupère ses droits AWS **sans aucune clé stockée dans le cluster** ;
- l'identifiant `efs_id` écrit dans `aws_outputs.yml`.

Ce que fait le rôle, sur kube-1 :
1. installe `helm` (même version qu'en local, somme de contrôle vérifiée) ;
2. installe le chart `aws-efs-csi-driver` (version figée dans `defaults/main.yml`) dans `kube-system` ;
3. crée la StorageClass `efs-sc` :

| Paramètre | Valeur | Pourquoi |
|---|---|---|
| `provisioningMode` | `efs-ap` | chaque volume = un *access point* EFS, un dossier isolé sous `/dynamic` |
| `reclaimPolicy` | `Retain` | supprimer un PVC ne supprime pas les données (base de données, backups) |
| `volumeBindingMode` | `WaitForFirstConsumer` | identique au local |
| `directoryPerms` | `700` | seul le propriétaire du volume y accède |

En local (kind), `efs-sc` existe aussi mais repose sur `local-path` : pas de
`ReadWriteMany` entre nœuds. Le partage entre nœuds ne se teste donc qu'en prod.

Utilisation dans un manifest :

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata: {name: data}
spec:
  accessModes: [ReadWriteMany]   # ReadWriteOnce aussi possible
  storageClassName: efs-sc
  resources: {requests: {storage: 5Gi}}   # indicatif : EFS n'a pas de taille fixe
```

Test : `ansible-playbook -i inventory tests/efs.yml` crée un volume, l'écrit depuis un pod
sur kube-2, le relit depuis un pod sur kube-3, vérifie le contenu puis nettoie tout.

**Données conservées** : avec `Retain`, un volume supprimé laisse son PV et son access point.
Pour vraiment libérer : `kubectl delete pv <nom>` puis supprimer l'access point dans la console EFS.

## 5. Accès SSH

- kube-1 est joint directement sur son IP publique ; kube-2 et kube-3 sur leur IP privée,
  **en rebond par kube-1** (`ProxyCommand` dans `group_vars/workers.yml`).
- Les empreintes des nœuds sont dans `~/.ssh/kube-12_known_hosts`, acceptées à la
  1re connexion. Raison : quand le cluster est recréé, les VM gardent les mêmes IP privées
  mais changent d'empreinte ; avec le `known_hosts` habituel, SSH refuserait la connexion.
- Se connecter à la main :
  ```bash
  ssh -i ~/.ssh/kube-12 ubuntu@<IP publique>                       # kube-1
  ssh -i ~/.ssh/kube-12 -J ubuntu@<IP publique> ubuntu@10.0.0.113  # kube-2
  ```

## 6. Dépannage

| Symptôme | Cause | Solution |
|---|---|---|
| `ignoring it as an ansible.cfg source` (WSL) | repo sous `/mnt/c`, dossier « world writable » | sans gravité si on passe `-i inventory` ; sinon cloner dans `~/` ou voir le README |
| `'public_ip' is undefined` | `aws_outputs.yml` absent | le créer depuis `aws_outputs.yml.example` |
| `REMOTE HOST IDENTIFICATION HAS CHANGED` | ancienne empreinte d'une VM recréée | `rm ~/.ssh/kube-12_known_hosts` (fait aussi par la destruction de l'infra) |
| `UNREACHABLE` juste après la création des VM | les VM démarrent encore | attendre 1 min et relancer le ping |
| un worker n'arrive pas à joindre | jeton expiré (1 h) | relancer `site.yml` : un nouveau jeton est créé à chaque passage |
| nœud `NotReady` | Calico pas encore démarré | `kubectl -n kube-system get pods -l k8s-app=calico-node` ; attendre ou relancer `site.yml` |
| PVC `efs-sc` reste `Pending` | driver pas prêt, ou pas de pod qui l'utilise (`WaitForFirstConsumer`) | `kubectl -n kube-system get pods -l app.kubernetes.io/name=aws-efs-csi-driver` ; `kubectl describe pvc` |
| pod bloqué en `ContainerCreating` avec un volume EFS | NFS bloqué ou mount target absent | vérifier le security group EFS (2049 depuis les nœuds) et `efs_id` |
| `AccessDenied` dans les logs du driver | rôle IAM ou accès aux métadonnées | profil d'instance `kube-12-node` attaché, hop limit IMDS = 2 |
| `kubectl` depuis le PC refuse le certificat | IP publique changée après l'init | l'IP de kube-1 est fixe (Elastic IP) ; si elle change, recréer le cluster |

Commandes utiles sur kube-1 : `sudo crictl ps`, `sudo journalctl -u kubelet -f`,
`kubectl -n kube-system get pods -o wide`.

## 7. Monter de version

1. Changer `kubernetes_version` / `kubernetes_release` dans `cluster.yml` (une version mineure à la fois).
2. Suivre la procédure `kubeadm upgrade` (kube-1 puis les workers). `site.yml` installe les
   paquets à la nouvelle version mais **ne lance pas** `kubeadm upgrade` : c'est volontaire.

## 8. Tests réalisés

Sur 3 VM AWS `c7i-flex.large` (2 vCPU, 4 Go), Ubuntu 24.04 :

- `ansible all -m ping` : 3 × SUCCESS ;
- `site.yml` : 0 échec, 3 nœuds `Ready` en v1.36.4, containerd 2.4.2, labels corrects ;
- `site.yml` rejoué : `changed=0` sur kube-2 et kube-3 ; sur kube-1, seul le kubeconfig local
  changeait, corrigé ensuite.
