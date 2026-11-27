# dex (#41)

dex est l'issuer OIDC unique du cluster : kube-apiserver (#42), Argo CD, Grafana et Headlamp lui font confiance, et
lui seul. dex ne garde aucun compte : il renvoie l'utilisateur vers Keycloak, récupère son identité et ses groupes, puis
émet son propre jeton.

Dépend de : Keycloak et le client `dex` du realm `kube` (#39, #40), Ingress HTTPS (#32), Sealed Secrets (#37).

```
navigateur / kubectl ──► https://dex.<IP>.sslip.io ──► login sur https://keycloak.<IP>.sslip.io (realm kube)
                         ◄── ID token dex : email, groups=[kube-admins…]
dex ──HTTP──► keycloak-http.keycloak.svc (discovery, échange du code, clés)
```

| | |
|---|---|
| URL | `https://dex.<IP>.sslip.io` (local : `https://dex.127.0.0.1.sslip.io`) |
| Discovery | `https://dex.<IP>.sslip.io/.well-known/openid-configuration` |
| Chart | `dex` 0.26.0 (https://charts.dexidp.io), dex v2.46.0 |
| Namespace | `dex`, Service `dex:5556` |
| Application Argo CD | `dex` (wave 3, `apps/local` et `apps/prod`) |
| Stockage | CRDs Kubernetes (`*.dex.coreos.com`), dans le namespace `dex` |

## 1. Fichiers

| Fichier | Rôle |
|---|---|
| `apps/local/dex.yaml`, `apps/prod/dex.yaml` | Application `dex` : chart officiel + `platform/dex/config` |
| `platform/dex/values.yaml` | values du chart officiel (image, sécurité, ressources) |
| `platform/dex/config/` | petit chart qui génère la config de dex à partir de `baseDomain`, et le SealedSecret `dex-secrets` |
| `platform/dex/config/templates/_config.tpl` | la config : issuer, connecteur Keycloak, clients |
| `platform/dex/seal-secrets.sh` | génère et scelle les secrets |
| `platform/dex/test-dex.sh` | tests de bout en bout |

Le chart officiel ne sait pas construire sa config à partir d'une variable, et dex ne lit pas les variables
d'environnement pour l'issuer ni pour les redirect URIs. La config est donc rendue par `platform/dex/config`, comme
les Ingress par `platform/ingress` : en prod, seul `baseDomain` de `apps/prod/dex.yaml` change.

## 2. Fonctionnement

1. Un outil envoie l'utilisateur sur `https://dex.<IP>.sslip.io/auth`. Il n'y a qu'un connecteur, donc dex redirige
   tout de suite vers Keycloak.
2. L'utilisateur se connecte sur Keycloak (realm `kube`). Keycloak le renvoie sur `https://dex.<IP>.sslip.io/callback`.
3. dex échange le code contre un jeton Keycloak, en passant par le Service `keycloak-http` (pas par Internet), et
   vérifie que l'issuer du jeton est bien `https://keycloak.<IP>.sslip.io/realms/kube`.
4. dex émet son propre ID token (issuer `https://dex.<IP>.sslip.io`) avec `email`, `name` (le login) et `groups`,
   puis renvoie l'utilisateur vers l'outil.

Passer par le Service pour les appels de dex à Keycloak évite deux problèmes : en local,
`keycloak.127.0.0.1.sslip.io` pointe sur le pod lui-même ; en prod, le certificat de Keycloak peut encore être celui de
staging, que dex refuserait. Le navigateur, lui, passe toujours par l'URL publique. Pour tout faire passer par l'URL
publique : `keycloakInternalURL: ""` dans `platform/dex/config/values.yaml`.

dex garde ses clés de signature, ses sessions et ses refresh tokens dans des ressources Kubernetes (CRDs créées par dex
au démarrage) : un redémarrage ne déconnecte personne.

## 3. Secrets

Un SealedSecret `dex-secrets` (`platform/dex/config/templates/dex-secrets.sealed.yaml`), lu par dex en variables
d'environnement :

| Clé | Rôle |
|---|---|
| `KEYCLOAK_CLIENT_SECRET` | secret du client `dex` dans Keycloak (même valeur que `REALM_SECRET_DEX_CLIENT`) |
| `KUBERNETES_CLIENT_SECRET` | client `kubernetes` (kubectl / kubelogin, #42) |
| `ARGOCD_CLIENT_SECRET` | client `argocd` |
| `GRAFANA_CLIENT_SECRET` | client `grafana` |
| `HEADLAMP_CLIENT_SECRET` | client `headlamp` |

```bash
./platform/dex/seal-secrets.sh
git add platform/dex/config/templates/dex-secrets.sealed.yaml platform/keycloak/manifests
```

Le script ne crée que les clés absentes et affiche les nouvelles valeurs une seule fois (gestionnaire de mots de
passe). Quand il écrit `KEYCLOAK_CLIENT_SECRET`, il rescelle la même valeur dans Keycloak
(`REALM_SECRET_DEX_CLIENT`), pour que les deux restent identiques.

Le secret d'un client sert aussi à l'outil qui l'utilise : Argo CD, Grafana et Headlamp le scellent dans leur propre
namespace, avec la même valeur.

Changer le secret du client `dex` sur un Keycloak déjà initialisé : le régénérer dans la console (realm `kube` →
Clients → dex → Credentials), puis `KEYCLOAK_CLIENT_SECRET=<nouvelle valeur> ./platform/dex/seal-secrets.sh`.

## 4. Clients

| Client | Redirect URIs | Utilisé par |
|---|---|---|
| `kubernetes` | `http://localhost:8000`, `http://localhost:18000` | kubectl via kubelogin (#42) |
| `argocd` | `https://argocd.<IP>.sslip.io/auth/callback`, `http://localhost:8085/auth/callback` (CLI) | Argo CD |
| `grafana` | `https://grafana.<IP>.sslip.io/login/generic_oauth` | Grafana (#47) |
| `headlamp` | `https://headlamp.<IP>.sslip.io/oidc-callback` | Headlamp (#50) |

Pour brancher un outil :

| Paramètre | Valeur |
|---|---|
| issuer | `https://dex.<IP>.sslip.io` |
| client ID / secret | tableau ci-dessus, § 3 |
| scopes | `openid profile email groups` |
| claim des groupes | `groups` (`kube-admins`, `kube-devs`, `kube-viewers`) |
| claim du nom d'utilisateur | `email` (`<login>@kube12.local`) |

kube-apiserver et les outils appellent dex côté serveur : en prod, la route `dex` doit avoir un certificat
Let's Encrypt de prod (`issuer: letsencrypt-prod` sur la route dans `platform/ingress/values.yaml`, après un premier
passage en staging).

## 5. Déploiement et tests

Rien à lancer à la main : l'Application racine lit `apps/<env>/dex.yaml`. En prod, `baseDomain` de
`apps/prod/dex.yaml` vaut `<IP publique de kube-1>.sslip.io`.

```bash
kubectl -n argocd get application dex
kubectl -n dex get pods,svc,ingress
kubectl -n dex logs deploy/dex | grep -i -E "connector|listening"
```

Tests (discovery en HTTPS, redirection vers Keycloak, retour avec les groupes) :

```bash
./platform/dex/test-dex.sh                                          # local
DEX_URL=https://dex.<IP>.sslip.io ./platform/dex/test-dex.sh        # prod
DEX_INSECURE=1 DEX_URL=https://dex.<IP>.sslip.io ./platform/dex/test-dex.sh   # prod, certificat staging
```

Le script se connecte avec le compte `demo` sur le client `kubernetes`, comme un navigateur : `/auth` de dex, formulaire
Keycloak, retour sur dex puis sur le client, échange du code. Il vérifie ensuite l'issuer, l'audience et les claims
`groups` (`kube-viewers`) et `email` de l'ID token. Les secrets sont lus dans le cluster.

À la main : ouvrir `https://dex.<IP>.sslip.io/.well-known/openid-configuration`, puis se connecter sur un outil
branché sur dex.

dex ne relit pas sa config à chaud, et le Secret `dex-config` ne fait pas partie du chart officiel : après une
modification de `platform/dex/config`, redémarrer dex.

```bash
kubectl -n dex rollout restart deployment dex
```

Validé hors cluster : rendu des deux charts en local et en prod, Secret de config refusé sans `baseDomain`, secrets
scellés avec le certificat de l'équipe. Pas encore testé sur kind ni sur AWS.

## 6. Choix

- **Connecteur OIDC générique** plutôt que le connecteur SAML ou Keycloak : Keycloak parle OIDC, et le client `dex`
  existe déjà dans le realm.
- **`insecureEnableGroups: true`** : sans cette option, dex ignore le claim `groups` de Keycloak. Le nom fait peur, mais
  le claim vient d'un fournisseur de confiance et d'un mapper qu'on contrôle.
- **`userNameKey: preferred_username`** : dex refuse un jeton sans claim `name`, et Keycloak n'en émet pas pour les
  comptes sans prénom ni nom (ceux de l'équipe).
- **Stockage `kubernetes`** plutôt que `memory` : les clés de signature et les refresh tokens survivent aux
  redémarrages. Pas de base à gérer.
- **ID tokens valables 1 h** (24 h par défaut) : kubelogin et les outils les renouvellent avec le refresh token.
- **Pas d'écran d'approbation** (`skipApprovalScreen`) : tous les clients sont à nous.

## 7. Dépannage

| Symptôme | Piste |
|---|---|
| pod en `CrashLoopBackOff`, `failed to get provider` | Keycloak pas encore prêt (dex repart tout seul), ou `keycloakInternalURL` faux |
| `CreateContainerConfigError` | Secret `dex-secrets` absent : `kubectl -n dex describe sealedsecret dex-secrets`, clé d'équipe |
| Keycloak : `Invalid client or Invalid client credentials` | `KEYCLOAK_CLIENT_SECRET` différent du secret du client dans Keycloak (§ 3) |
| Keycloak : `Invalid parameter: redirect_uri` | realm importé avec un autre domaine que `baseDomain` de dex |
| dex : `missing "name" claim` | `userNameKey` retiré de la config |
| dex : `oidc: id token issued by a different provider` | `issuerAlias` différent de `KC_HOSTNAME` de Keycloak |
| pas de `groups` dans le jeton | scope `groups` absent de la demande de l'outil |
| `Unregistered redirect_uri` | URL de callback de l'outil absente du § 4 |
| config modifiée sans effet | redémarrer dex (§ 5) |
