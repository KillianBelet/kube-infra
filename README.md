# T-CLO-901 — KUBE (groupe 12)

Cluster Kubernetes 3 nœuds, déployé en GitOps, tout en HTTPS et OIDC.
Architecture : [Miro](https://miro.com/app/board/uXjVHigyph8=/) — suivi : [GitHub Project](https://github.com/orgs/EpitechMscProPromo2027/projects/549).

| Nœud | Rôle | IP privée (prod) |
|---|---|---|
| kube-1 | control plane + worker, porte d'entrée (Traefik) | 10.0.0.235 |
| kube-2 | worker | 10.0.0.113 |
| kube-3 | worker | 10.0.0.115 |

## Deux environnements, mêmes manifests

| | Local (kind) | Prod (AWS) |
|---|---|---|
| Cluster | kind, 3 nœuds Docker | 3 VM, kubeadm |
| CNI | Calico | Calico |
| Nœuds | label `kube12/node=kube-1/2/3` | label `kube12/node=kube-1/2/3` |
| Entrée | 127.0.0.1:80/443 → NodePorts 30080/30443 | kube-1:80/443 → NodePorts 30080/30443 |
| Domaines | `*.127.0.0.1.sslip.io` | `*.<IP publique>.sslip.io` |
| StorageClass `efs-sc` | local-path (pas de RWX) | Amazon EFS |

**On développe tout en local.** La prod AWS n'est allumée que pour l'intégration et la démo.

Règles pour que tout marche dans les deux environnements :
- placer un pod sur un nœud avec le label `kube12/node` (jamais le nom du nœud) ;
- les volumes persistants utilisent la StorageClass `efs-sc` ;
- les Ingress utilisent un domaine construit sur une variable (`127.0.0.1.sslip.io` en local).

## Prérequis

- **Windows** : WSL2 + Ubuntu, et Docker Desktop avec
  *Settings → Resources → WSL integration → Ubuntu* activé.
  Dans Ubuntu : `sudo apt install -y ansible`.
- **macOS** : Docker Desktop, `brew install ansible`.
- **Linux** : Docker et `ansible`.
- Environ 8 Go de RAM disponibles pour Docker si toute la stack tourne.

kind, kubectl et helm sont installés par le playbook, aux mêmes versions pour tout le monde,
dans `~/.local/bin`. Ajouter à son `~/.bashrc` / `~/.zshrc` :

```bash
export PATH="$HOME/.local/bin:$PATH"
```

## Environnement local

```bash
cd ansible
ansible-playbook local.yml        # crée le cluster kind-kube-12 (≈ 2-3 min)
kubectl get nodes -L kube12/node  # 3 nœuds Ready, labels kube-1/2/3
ansible-playbook local-down.yml   # supprime le cluster
```

Les versions (Kubernetes 1.36, Calico, kind, kubectl, helm) sont figées dans
`ansible/local.yml` et `ansible/inventory/group_vars/all/cluster.yml` : ne pas les changer sans prévenir l'équipe.

## Prod (AWS) : accès aux nœuds

L'inventaire `ansible/inventory/` est fixe : groupes `control_plane` (kube-1) et `workers`
(kube-2, kube-3). Les IP privées viennent de `cluster.yml` ; la seule valeur qui change est
l'IP publique de kube-1, à mettre dans `inventory/group_vars/all/aws_outputs.yml`
(ignoré par git, voir `aws_outputs.yml.example`). Les workers sont joints en rebond par kube-1.

```bash
cd ansible
cp inventory/group_vars/all/aws_outputs.yml.example inventory/group_vars/all/aws_outputs.yml
# y mettre l'IP publique de kube-1, puis :
ansible -i inventory all -m ping                                  # clé ~/.ssh/kube-12
ansible -i inventory all -m ping -e ssh_key_path=~/.ssh/id_ed25519  # ou sa propre clé
```

> **Windows : repo cloné sous `C:\…` et utilisé depuis WSL (`/mnt/c/…`)** — Ansible ignore
> `ansible.cfg` dans ce cas (dossier « world writable »). Ça n'empêche pas `local.yml` de
> fonctionner. Pour corriger : cloner le repo dans le home Linux (`~/`), ou
> `printf '[automount]\noptions = "metadata,umask=22,fmask=11"\n' | sudo tee -a /etc/wsl.conf`
> puis `wsl --shutdown` dans PowerShell.
