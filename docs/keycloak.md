# Keycloak (#39, #40)

Keycloak garde les comptes, les mots de passe et les groupes de l'équipe. Les outils du cluster ne lui parlent pas
directement : dex (#41) se branche dessus et sert d'issuer OIDC unique. Les droits dans chaque outil viennent du claim
`groups` du jeton.

Dépend de : app-of-apps (#36), Sealed Secrets et clé d'équipe (#37, #54), Ingress HTTPS (#32), `efs-sc` (#28).

```
navigateur ──HTTPS──► Traefik ──HTTP──► keycloak-http:80 ──► keycloak-0 ──3306──► keycloak-db-0 (MySQL, efs-sc)
dex (#41) ──OIDC (client dex)──► https://keycloak.<IP>.sslip.io/realms/kube
```

| | |
|---|---|
| URL | `https://keycloak.<IP>.sslip.io` (local : `https://keycloak.127.0.0.1.sslip.io`) |
| Console | `https://keycloak.<IP>.sslip.io/admin/`, compte du realm `master` (Secret `keycloak-admin`) |
| Issuer | `https://keycloak.<IP>.sslip.io/realms/kube` |
| Chart | `keycloakx` 7.4.0 (codecentric), image officielle Keycloak 26.8.1 |
| Base | MySQL 8.4, chart Bitnami `mysql` 12.3.5, release `keycloak-db` |
| Namespace | `keycloak` |
| Applications Argo CD | `keycloak-db` (wave 1, `apps/common`), `keycloak` (wave 2, `apps/local` et `apps/prod`) |

## 1. Fichiers

| Fichier | Rôle |
|---|---|
| `apps/common/keycloak-db.yaml` | Application `keycloak-db` : chart MySQL + `platform/keycloak/db/` |
| `apps/local/keycloak.yaml`, `apps/prod/keycloak.yaml` | Application `keycloak` : chart keycloakx + `platform/keycloak/manifests/` (seul `baseDomain` change) |
| `platform/keycloak/values.yaml` | values de Keycloak |
| `platform/keycloak/values-db.yaml` | values de la base |
| `platform/keycloak/db/` | identifiants scellés de la base |
| `platform/keycloak/manifests/` | admin et secrets du realm scellés, `realm-kube.json` |
| `platform/keycloak/seal-secrets.sh` | génère et scelle les secrets manquants |
| `platform/keycloak/test-realm.sh` | tests du realm |

## 2. Fonctionnement

1. Wave 1 : la base `keycloak-db` démarre avec ses identifiants (Secret `keycloak-db-credentials`) et crée la base
   `keycloak`.
2. Wave 2 : les Secrets `keycloak-admin`, `keycloak-realm-secrets` et la ConfigMap `keycloak-realm` sont créés en
   premier (wave `-1`), puis le StatefulSet Keycloak.
3. Au démarrage (`kc.sh start --import-realm`), Keycloak crée son schéma dans MySQL, crée l'admin du realm `master` s'il
   n'y en a pas, puis importe `realm-kube.json` si le realm `kube` n'existe pas. Les `${...}` du fichier sont remplacés
   par les variables d'environnement du pod.
4. Traefik termine le TLS. Keycloak lit les en-têtes `X-Forwarded-*` uniquement s'ils viennent du réseau des pods
   (`KC_PROXY_TRUSTED_ADDRESSES`) et utilise `KC_HOSTNAME` pour ses URLs.

Tout est dans MySQL sur EFS : un pod recréé retrouve ses données, et ce qui est modifié dans la console survit aux
redémarrages (l'import est ignoré si le realm existe).

`baseDomain` est passé par l'Application de chaque environnement. Il donne `KC_HOSTNAME`
(`https://keycloak.<baseDomain>`) et la redirect URI de dex (`https://dex.<baseDomain>/callback`). En prod c'est la même
valeur que dans `apps/prod/ingress.yaml`. Après un `destroy-aws` / `provision-aws`, la base repart de zéro et le realm
est réimporté avec le nouveau domaine.

## 3. Secrets

Trois SealedSecrets, chiffrés avec `platform/sealed-secrets/team-cert.crt` (voir [database.md](database.md) § 3) :

| Secret | Clés |
|---|---|
| `keycloak-db-credentials` | `mysql-root-password`, `mysql-password` |
| `keycloak-admin` | `KC_BOOTSTRAP_ADMIN_USERNAME` (`kube12-admin`), `KC_BOOTSTRAP_ADMIN_PASSWORD` |
| `keycloak-realm-secrets` | `REALM_SECRET_DEX_CLIENT`, `REALM_SECRET_DEMO_PASSWORD`, `REALM_SECRET_PASSWORD_<LOGIN>` |

```bash
./platform/keycloak/seal-secrets.sh
git add platform/keycloak/db platform/keycloak/manifests
```

Le script ne crée que les clés absentes et affiche les nouvelles valeurs une seule fois : elles vont dans le
gestionnaire de mots de passe, et chacun reçoit son mot de passe initial en privé. Pour forcer une valeur :
`REALM_SECRET_DEX_CLIENT=... ./platform/keycloak/seal-secrets.sh`.

Une fois la base et Keycloak initialisés, changer un secret scellé ne suffit pas, il faut aussi le changer dans le
service :

| Valeur | Dans le service | Puis |
|---|---|---|
| mot de passe MySQL | `ALTER USER` sur `keycloak-db-0` ([database.md](database.md) § 4) | `KEYCLOAK_DB_PASSWORD=... KEYCLOAK_DB_ROOT_PASSWORD=... ./seal-secrets.sh` |
| admin Keycloak | console, realm `master` → Users → admin → Credentials | `KC_BOOTSTRAP_ADMIN_PASSWORD=... ./seal-secrets.sh` |
| secret du client dex | console, realm `kube` → Clients → dex → Credentials → Regenerate | `KEYCLOAK_CLIENT_SECRET=... ./platform/dex/seal-secrets.sh` (scelle les deux côtés, [dex.md](dex.md) § 3) |

Un utilisateur qui change son propre mot de passe n'a rien à resceller.

## 4. Déploiement

Prérequis : app-of-apps ([gitops.md](gitops.md)), clé d'équipe sur le cluster, Traefik, cert-manager et
`platform/ingress`. Les Applications sont lues par l'Application racine, rien à lancer à la main.

En prod, `baseDomain` de `apps/prod/keycloak.yaml` vaut `<IP publique de kube-1>.sslip.io`.

```bash
kubectl -n argocd get applications keycloak-db keycloak
kubectl -n keycloak get pods,pvc,svc,ingress
kubectl -n keycloak logs keycloak-0 -c keycloak | grep -E "Realm|started in"
```

Le premier démarrage prend 2 à 5 minutes.

## 5. Tests

Console en HTTPS :

```bash
curl -sI http://keycloak.<IP>.sslip.io/ | head -1    # 308
curl -s https://keycloak.<IP>.sslip.io/realms/kube/.well-known/openid-configuration | grep -o '"issuer":"[^"]*"'
kubectl -n keycloak get secret keycloak-admin -o jsonpath='{.data.KC_BOOTSTRAP_ADMIN_PASSWORD}' | base64 -d; echo
```

Persistance : créer un utilisateur `persist-test` dans la console, puis :

```bash
kubectl -n keycloak delete pod keycloak-0 keycloak-db-0
kubectl -n keycloak rollout status statefulset/keycloak --timeout=600s
kubectl -n keycloak logs keycloak-0 -c keycloak | grep "Realm 'kube'"    # Import skipped
```

`persist-test` doit toujours être là.

Realm et claim `groups` :

```bash
./platform/keycloak/test-realm.sh
KEYCLOAK_URL=https://keycloak.<IP>.sslip.io ./platform/keycloak/test-realm.sh
```

Le script vérifie l'issuer, les groupes, le client `dex` et le claim `groups` des jetons de `demo`.

Réimport depuis Git : supprimer le realm `kube` dans la console, puis `kubectl -n keycloak delete pod keycloak-0`.
Les logs affichent `Realm 'kube' imported` et `test-realm.sh` repasse.

Testé hors cluster avec Keycloak 26.8.1 sur base H2 : import du realm, `test-realm.sh` 9/9, vrai login `demo` sur le
client dex (`groups=['kube-viewers']`), persistance et réimport, issuer correct derrière un proxy. Pas encore testé sur
kind ni sur AWS.

## 6. Le realm

`platform/keycloak/manifests/realm-kube.json` est la référence du realm.

| Élément | Valeur |
|---|---|
| Groupes | `kube-admins`, `kube-devs`, `kube-viewers` (utilisés par #42, Argo CD, Grafana, Headlamp : ne pas renommer) |
| Comptes de l'équipe | login GitHub, `kube-admins`, mot de passe initial temporaire |
| Compte de démo | `demo`, `kube-viewers` |
| Client `dex` | confidentiel, flux standard uniquement, `fullScopeAllowed: false` |
| Mapper `groups` | claim `groups`, sans le chemin (`kube-admins` et pas `/kube-admins`) |
| Sécurité | pas d'inscription, mots de passe de 12 caractères min., protection brute force, événements gardés 7 jours |

Les adresses `<login>@kube12.local` ne sont pas réelles : le claim `email` sert de nom d'utilisateur à kube-apiserver
(#42), aucun mail n'est envoyé.

Pour modifier le realm : changer `realm-kube.json` (un nouveau compte a pour mot de passe
`${REALM_SECRET_PASSWORD_<LOGIN>}`), lancer `seal-secrets.sh`, commit, push. Le realm existant n'est pas mis à jour
par l'import : faire la même modification dans la console. À l'inverse, une modification faite dans la console doit
être reportée dans le JSON (Realm settings → Action → Partial export).

## 7. Choix

- **keycloakx plutôt que Bitnami** : image officielle de Keycloak. Le chart Bitnami dépend des images `bitnamilegacy`,
  qui ne sont plus mises à jour. L'opérateur Keycloak serait trop lourd pour une seule instance.
- **MySQL plutôt que PostgreSQL** : sur `efs-sc`, EFS impose son uid aux fichiers et PostgreSQL refuse de démarrer
  dans ce cas. Base séparée de celle de l'application pour pouvoir toucher à l'une sans casser l'authentification.
- **`--import-realm` plutôt que keycloak-config-cli** : rien à installer en plus. En contrepartie, Git ne met pas à
  jour un realm déjà créé.
- **`xforwarded`** : Traefik envoie `X-Forwarded-*` et pas `Forwarded`.
- **Une seule instance**, sans `nodeSelector`.

## 8. dex (#41)

dex se connecte au realm avec le client `dex`. Il appelle Keycloak par le Service `keycloak-http`, et le navigateur
par l'URL publique : voir [dex.md](dex.md).

## 9. Dépannage

| Symptôme | Piste |
|---|---|
| `keycloak-0` bloqué en `Init` | `dbchecker` attend la base : `kubectl -n keycloak logs keycloak-0 -c dbchecker` |
| `CreateContainerConfigError` | Secret absent : `kubectl -n keycloak describe sealedsecret`, clé d'équipe |
| `keycloak-0` redémarre au premier lancement | schéma long à créer sur EFS : augmenter `startupProbe.failureThreshold` |
| `Access denied for user 'keycloak'` | le mot de passe scellé ne correspond plus à celui de la base (§ 3) |
| `Bad Gateway` | pod pas prêt, ou mauvais Service dans la route (`keycloak-http:80`) |
| « HTTPS required » ou boucle de redirections | `KC_PROXY_HEADERS`, `KC_PROXY_TRUSTED_ADDRESSES` |
| issuer en `http://` ou mauvais nom | `baseDomain` de l'Application |
| dex : `Invalid redirect_uri` | realm importé avec un autre domaine |
| `${REALM_SECRET_...}` affiché tel quel | clé absente de `keycloak-realm-secrets` : `seal-secrets.sh` puis réimport |
| repartir de zéro | `efs-sc` est en `Retain` : supprimer aussi le PVC `data-keycloak-db-0` et son PV |
