# Base de données MySQL (#54)

Dépend de : Sealed Secrets (#37), StorageClass `efs-sc` (#28), Argo CD app-of-apps (#36).

La base de l'application tourne dans le cluster, déployée par Argo CD avec le chart MySQL de Bitnami.
Ses fichiers sont sur un volume persistant `efs-sc` : si le pod meurt, les données restent.

| | |
|---|---|
| Chart | `oci://registry-1.docker.io/bitnamicharts/mysql` **12.3.5** (MySQL 8.4 LTS) |
| Image | `docker.io/bitnamilegacy/mysql:8.4.5-debian-12-r0` (voir § 6) |
| Namespace | `database` |
| Pod | `mysql-0` (StatefulSet `mysql`), sur **kube-2** (`kube12/node: kube-2`) |
| Service | `mysql.database.svc.cluster.local:3306` |
| Base / utilisateur | `app_database` / `app_user` (mêmes noms que la config de `kube-app`) |
| Volume | PVC `data-mysql-0`, 2 Gi, StorageClass `efs-sc` |
| Identifiants | Secret `mysql-credentials` (clés `mysql-root-password`, `mysql-password`), créé par un SealedSecret |

## 1. Les fichiers

| Fichier | Rôle |
|---|---|
| `apps/common/mysql.yaml` | Application Argo CD (vague 1) : le chart, les values, et les manifests du dossier `platform/mysql/manifests/` |
| `platform/mysql/values.yaml` | réglages du chart : image, base, utilisateur, volume, ressources, nœud |
| `platform/mysql/manifests/mysql-credentials.sealed.yaml` | les mots de passe, chiffrés (SealedSecret) |
| `platform/mysql/seal-credentials.sh` | génère et chiffre de nouveaux mots de passe |
| `platform/sealed-secrets/team-cert.crt` | certificat **public** de l'équipe, pour chiffrer sans être connecté au cluster |

## 2. Comment ça marche

1. Argo CD lit `apps/common/mysql.yaml` et installe le chart avec `platform/mysql/values.yaml`.
2. Il applique aussi le SealedSecret. Le contrôleur Sealed Secrets le déchiffre avec la **clé privée de l'équipe**
   et crée le Secret `mysql-credentials` dans le namespace `database`.
3. Le chart lit ce Secret (`auth.existingSecret`) : au premier démarrage, MySQL crée la base `app_database`
   et l'utilisateur `app_user` avec ce mot de passe.
4. Les fichiers de MySQL sont écrits dans `/bitnami/mysql/data`, sur le volume `efs-sc`.
   Un nouveau pod remonte le même volume et retrouve les données.

La vague 1 place la base après Sealed Secrets (vague 0) et avant l'application (vague 3).

## 3. Clé Sealed Secrets de l'équipe

Un SealedSecret ne se déchiffre qu'avec la clé privée qui correspond au certificat utilisé pour le chiffrer.
Pour que **le même fichier** marche sur le kind de chacun et sur AWS, tous les clusters utilisent la même clé :

- le certificat public est dans Git : `platform/sealed-secrets/team-cert.crt` ;
- la clé privée (`sealed-secrets-key.yaml`) n'est **jamais** dans Git. Elle se transmet en privé dans l'équipe.

Sur un cluster neuf, **avant** d'installer Sealed Secrets (ou avant le bootstrap Argo CD) :

```bash
kubectl create namespace sealed-secrets
kubectl apply -f /chemin/hors-git/sealed-secrets-key.yaml
```

Le contrôleur trouve la clé au démarrage et ne génère pas la sienne. `keyrenewperiod: "0"`
(`platform/sealed-secrets/values.yaml`) l'empêche d'en créer une nouvelle tous les 30 jours.

**Contrôleur déjà installé** (son kind tournait avant) : il a généré sa propre clé, qu'il utilise pour chiffrer.
Supprimer cette clé, appliquer celle de l'équipe, puis redémarrer le contrôleur :

```bash
kubectl -n sealed-secrets get secret -l sealedsecrets.bitnami.com/sealed-secrets-key   # repérer sealed-secrets-keyXXXXX
kubectl -n sealed-secrets delete secret sealed-secrets-keyXXXXX
kubectl apply -f /chemin/hors-git/sealed-secrets-key.yaml
kubectl -n sealed-secrets rollout restart deploy sealed-secrets
```

**Comment la clé a été créée** (le 15/11/2026, valable 10 ans), pour pouvoir l'expliquer ou la refaire :

```bash
openssl req -x509 -days 3650 -nodes -newkey rsa:4096 -keyout tls.key -out tls.crt \
  -subj "/CN=sealed-secret/O=kube-12"
kubectl create secret tls sealed-secrets-team-key -n sealed-secrets --cert=tls.crt --key=tls.key \
  --dry-run=client -o yaml > sealed-secrets-key.yaml
# puis ajouter le label sealedsecrets.bitnami.com/sealed-secrets-key: active dans metadata
```

`tls.crt` est le certificat public (`team-cert.crt`). `tls.key` et `sealed-secrets-key.yaml` restent hors de Git :
c'est Adam qui les détient et les transmet en privé.

## 4. Changer les mots de passe

**Nouvelle base** (le volume `data-mysql-0` n'existe pas encore) :

```bash
./platform/mysql/seal-credentials.sh     # écrit le SealedSecret et affiche les mots de passe une fois
git add platform/mysql/manifests/mysql-credentials.sealed.yaml
```

**Base déjà initialisée** : MySQL garde les mots de passe de sa création. Le Secret est monté en fichier dans le pod
et les sondes de santé lisent le mot de passe root dans ce fichier : si le Secret change sans que MySQL change,
les sondes échouent et le pod redémarre en boucle. Toujours dans cet ordre :

```bash
# 1. Changer dans MySQL (avec l'ancien mot de passe root)
kubectl -n database exec -it mysql-0 -c mysql -- mysql -u root -p \
  -e "ALTER USER 'root'@'%' IDENTIFIED BY 'NOUVEAU_ROOT'; ALTER USER 'app_user'@'%' IDENTIFIED BY 'NOUVEAU_APP';"
# 2. Sceller exactement les mêmes valeurs, puis pousser
MYSQL_ROOT_PASSWORD='NOUVEAU_ROOT' MYSQL_PASSWORD='NOUVEAU_APP' ./platform/mysql/seal-credentials.sh
```

Ne jamais relancer le script sans ces deux variables sur une base existante.

Le mot de passe de `app_user` est aussi le `DB_PASSWORD` du Secret de l'application (#55).

## 5. Vérifier

```bash
kubectl -n argocd get application mysql                 # Synced + Healthy
kubectl -n database get pods,pvc -o wide                # mysql-0 Running sur kube-2, PVC Bound en efs-sc
kubectl -n database get secret mysql-credentials        # créé par le SealedSecret
```

Test de persistance (critère d'acceptation) :

```bash
PW=$(kubectl -n database get secret mysql-credentials -o jsonpath='{.data.mysql-password}' | base64 -d)
sql() { kubectl -n database exec mysql-0 -c mysql -- env MYSQL_PWD="$PW" mysql -u app_user app_database -e "$1"; }

sql "CREATE TABLE IF NOT EXISTS t54 (id INT PRIMARY KEY, v VARCHAR(20)); REPLACE INTO t54 VALUES (1, 'persistant');"
kubectl -n database delete pod mysql-0
kubectl -n database rollout status statefulset/mysql --timeout=300s
sql "SELECT * FROM t54;"      # la ligne est toujours là
sql "DROP TABLE t54;"
```

Résultat sur kind (local-path) le 15/11/2026 : ligne retrouvée après suppression du pod, Secret déchiffré
avec la clé d'équipe, connexion de `app_user` depuis un autre namespace par `mysql.database.svc.cluster.local`.
**Non testé sur EFS** : à refaire sur AWS à la prochaine mise en route du cluster, et noter le résultat ici
avant de fermer #54.

## 6. Pour l'application (#55)

L'application est dans le namespace `app` : elle ne peut pas lire le Secret `mysql-credentials` (namespace `database`).
- `kube-app/deploy/chart/values.yaml` : `dbHost: mysql.database.svc.cluster.local` (au lieu de `CHANGE_ME_db_service_name`).
- Son SealedSecret `kube-app-secrets` doit contenir `DB_PASSWORD` = le mot de passe de `app_user`.

## 7. Choix techniques

- **Chart Bitnami** : c'est le chart de référence pour MySQL. MySQL n'a pas de chart officiel simple
  (seulement l'opérateur InnoDB Cluster, trop lourd pour une seule instance).
- **Image `bitnamilegacy`** : depuis août 2025, Bitnami ne publie plus ses images gratuites dans `docker.io/bitnami`.
  L'image du chart n'y existe plus ; la même image est restée dans `docker.io/bitnamilegacy`, mais elle ne reçoit plus
  de correctifs. D'où `global.security.allowInsecureImages: true` (sans lui, le chart refuse une autre image).
  Suffisant pour le projet ; en production, il faudrait passer à une image maintenue.
- **MySQL 8.4 LTS** plutôt que 9.x : version longue durée, la plus proche du `mysql:8.0` du docker-compose de l'app.
- **Une instance** (`architecture: standalone`) : le sujet demande la persistance, pas la réplication.
- **MySQL sur EFS (NFS)** : un disque réseau est plus lent qu'un disque local, le premier démarrage peut prendre
  plus d'une minute (d'où `startupProbe.failureThreshold: 30`). Sur EFS, le point d'accès impose son propre uid
  (à partir de 50000) à toutes les écritures : le `chown` d'un initContainer échouerait, d'où `volumePermissions: false`.
- **Placement strict sur kube-2** (`nodeSelector`) : c'est le schéma. Si kube-2 tombe, la base tombe avec lui,
  alors qu'EFS permettrait de remonter le volume ailleurs. Acceptable pour le projet.
- **NetworkPolicy** : le chart en crée une qui ouvre le port 3306 à tous les pods du cluster (`allowExternal: true`).
  Plus tard, on pourra la limiter aux namespaces de l'application et de la sauvegarde (`networkPolicy.allowExternal: false`
  et `networkPolicy.ingressNSMatchLabels`).

## 8. Dépannage

| Symptôme | Cause / correction |
|---|---|
| `mysql-0` bloqué en `ContainerCreating`, événement `FailedMount ... secret "mysql-credentials" not found` (`kubectl -n database describe pod mysql-0`) | SealedSecret non déchiffré : mauvaise clé sur le cluster (§ 3). `kubectl -n database describe sealedsecret mysql-credentials` |
| SealedSecret : *no key could decrypt secret* | le cluster n'a pas la clé de l'équipe (§ 3) |
| `mysql-0` en `Pending` | pas de nœud `kube12/node=kube-2`, ou PVC non créé : `kubectl -n database describe pod mysql-0` |
| `ErrImagePull` sur `bitnami/mysql` | values non appliquées : l'image doit venir de `bitnamilegacy` |
| `Access denied for user 'app_user'`, ou `mysql-0` qui redémarre en boucle (sondes en échec) | Secret changé sans changer MySQL : remettre les anciennes valeurs ou suivre § 4 |
| Redémarrages au premier lancement sur EFS | initialisation lente : augmenter `primary.startupProbe.failureThreshold` |
| Repartir de zéro (base vide, nouveaux mots de passe) | `efs-sc` est en `Retain` : supprimer l'Application ne supprime pas le volume. Supprimer aussi `kubectl -n database delete pvc data-mysql-0` puis le PV associé (`kubectl get pv`) |
