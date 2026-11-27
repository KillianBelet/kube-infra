# kubectl par OIDC (#44)

Chacun accède au cluster AWS avec **son compte Keycloak** : plus de kubeconfig admin partagé.
kubectl obtient un jeton de dex (plugin [kubelogin](https://github.com/int128/kubelogin)),
l'apiserver le vérifie et applique les droits du groupe Keycloak.

```
kubectl ──► kubelogin ──► navigateur : https://dex.<IP>.sslip.io ──► login Keycloak (realm kube)
   │                ◄── ID token dex (email, groups), gardé en cache
   └── requête + jeton ──► apiserver https://<IP>:6443 ──► RBAC selon groups (kube-admins / kube-devs / kube-viewers)
```

Dépend de : dex et son client `kubernetes` ([dex.md](dex.md), #41), l'apiserver qui fait confiance
à dex (#42), les droits par groupe (#43).

## 1. Prérequis

- `aws_outputs.yml` rempli (IP publique), accès SSH à kube-1 ([../README.md](../README.md), « Prod (AWS) »).
- `unzip` sur sa machine (`sudo apt install -y unzip` sous WSL / Linux).
- Un compte dans le realm `kube` de Keycloak, dans un des groupes `kube-admins`, `kube-devs`, `kube-viewers`.

## 2. Mise en place (une fois par cluster)

```bash
cd ansible
ansible-playbook -i inventory kubectl-oidc.yml
export KUBECONFIG=~/.kube-12/kubeconfig-oidc
kubectl get nodes
```

Le playbook :
1. lit sur kube-1 la CA publique du cluster et le secret du client `kubernetes` de dex ;
2. installe kubelogin `v1.36.4` dans `~/.local/bin/kubectl-oidc_login` (version et checksum figés dans
   `inventory/group_vars/all/oidc.yml`, comme kind/kubectl/helm) ;
3. écrit `~/.kube-12/kubeconfig-oidc` (mode 600 : il contient le secret du client, ne pas le partager ni le
   versionner).

Au premier `kubectl`, le navigateur s'ouvre sur Keycloak. Après connexion, le jeton est gardé en cache
(`~/.kube/cache/oidc-login`) et renouvelé tout seul : pas de nouveau login avant l'expiration de la session.

Sous WSL, si le navigateur ne s'ouvre pas : copier l'URL affichée (`http://localhost:8000`) dans le navigateur
Windows, WSL partage `localhost` avec Windows.

Après une reconstruction du cluster (nouvelle IP, nouvelle CA) : relancer le playbook.

## 3. Vérifier qui on est et ce qu'on peut faire

```bash
kubectl auth whoami                                # Username : <login>@kube12.local, Groups : [kube-...]
kubectl auth can-i delete pods -n app              # viewer : no
kubectl auth can-i create deployments -n app       # dev : yes
kubectl auth can-i '*' '*' --all-namespaces        # admin : yes
```

| Claim du jeton | Utilisé par l'apiserver comme |
|---|---|
| `email` | nom d'utilisateur (`--oidc-username-claim=email`) |
| `groups` | groupes Kubernetes (`--oidc-groups-claim=groups`), liés aux rôles par le RBAC (#43) |

## 4. Changer de compte, se déconnecter

```bash
kubectl oidc-login clean          # vide le cache : le prochain kubectl redemande le login
```

## 5. Fichiers

| Fichier | Rôle |
|---|---|
| `ansible/kubectl-oidc.yml` | lit la CA et le secret sur kube-1, installe kubelogin, écrit le kubeconfig |
| `ansible/templates/kubectl-oidc-config.yaml.j2` | kubeconfig : cluster, utilisateur `oidc` en `exec` kubelogin |
| `ansible/inventory/group_vars/all/oidc.yml` | issuer (`https://dex.<base_domain>`), client `kubernetes`, scopes, version de kubelogin |

L'issuer et le client sont les mêmes que ceux de l'apiserver (#42) : `control_plane_oidc_issuer_url`
doit valoir `oidc_issuer_url`, et `control_plane_oidc_client_id` `oidc_client_id`.

## 6. Choix

- **kubelogin** plutôt qu'un jeton collé à la main : renouvellement automatique par refresh token, standard
  de la communauté Kubernetes, un seul binaire.
- **Kubeconfig généré par Ansible** plutôt qu'un fichier type à remplir : la CA et l'IP changent à chaque
  reconstruction, le playbook les relit au bon endroit.
- **Secret du client lu dans le cluster** : pas de secret dans Git ni dans le chat. Il n'ouvre aucun droit à
  lui seul (il faut aussi le login Keycloak, et dex n'accepte que les redirections `localhost`).
- **Pas en local (kind)** : l'apiserver de kind ne peut pas joindre `dex.127.0.0.1.sslip.io` (127.0.0.1 est
  le nœud lui-même) et le certificat local est auto-signé. En local, on garde le contexte admin `kind-kube-12`.

## 7. Dépannage

| Symptôme | Piste |
|---|---|
| `error: You must be logged in to the server (Unauthorized)` | apiserver sans OIDC (#42), ou issuer / client différents de `oidc.yml` |
| `Forbidden ... User "<login>@kube12.local"` | authentifié, mais pas de droit : groupe Keycloak absent ou RBAC (#43) |
| `x509: certificate signed by unknown authority` (dex) | certificat dex encore en staging : passer la route dex en `letsencrypt-prod` (runbook § 6). Test seulement : `-e oidc_insecure_skip_tls_verify=true` |
| `Unregistered redirect_uri` | ports 8000 et 18000 occupés : kubelogin n'a pas pu écouter sur un port autorisé par dex |
| `Invalid client credentials` | secret du client changé dans dex : relancer le playbook |
| playbook : `Lire le secret du client` en échec | dex pas encore déployé (`kubectl -n dex get secret dex-secrets`) |
| playbook : `unzip` introuvable | `sudo apt install -y unzip` |
