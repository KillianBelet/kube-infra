# Certificats TLS automatiques (cert-manager + Let's Encrypt)

Dépend de : Traefik en NodePort sur kube-1 (#30).

## 1. Ce qu'on obtient

Toute Ingress qui le demande reçoit un certificat **Let's Encrypt** valide pour son hostname
`*.<IP publique>.sslip.io`, renouvelé automatiquement. Personne ne manipule de certificat ni de clé.

| Élément | Valeur |
|---|---|
| Contrôleur | cert-manager v1.21.3 (chart `oci://quay.io/jetstack/charts/cert-manager`), namespace `cert-manager` |
| CRDs | installées par le chart, conservées si le chart est désinstallé (`crds.keep`) |
| ClusterIssuers | `letsencrypt-staging` (essais) et `letsencrypt-prod` (cadenas valide) |
| Validation | ACME **HTTP-01**, servie par Traefik (IngressClass `traefik`) |
| Durée / renouvellement | durée fixée par Let's Encrypt, renouvellement aux 2/3 de la durée |

```
platform/cert-manager/
├── values.yaml                      values Helm (CRDs, ressources)
└── issuers/
    ├── letsencrypt-staging.yaml     ClusterIssuer staging
    └── letsencrypt-prod.yaml        ClusterIssuer prod
ansible/tests/tls.yml                test de bout en bout (staging puis prod)
```

## 2. Prérequis : le port 80 de kube-1 doit atteindre Traefik

Let's Encrypt valide HTTP-01 **toujours sur le port 80** de l'IP du hostname. En prod, le
security group ouvre 80/443, mais aucun processus n'écoutait sur ces ports de la VM : Traefik
n'était joignable que sur ses NodePorts 30080/30443. `platform/traefik/values.yaml` ajoute donc :

| Réglage | Pourquoi |
|---|---|
| `hostPort: 80` / `443` | kube-1:80/443 → pod Traefik (Traefik est déjà épinglé sur kube-1) |
| `updateStrategy` `maxUnavailable: 1`, `maxSurge: 0` | un hostPort n'est tenu que par un pod : l'ancien s'arrête avant que le nouveau démarre (quelques secondes de coupure) |
| `allowACMEByPass: true` sur `web` | `/.well-known/acme-challenge/` n'est plus redirigé vers HTTPS : le défi est servi en HTTP (Traefik ≥ v3.6) |
| `ingressClass.name: traefik` | nom figé, référencé par les ClusterIssuers |

En local (kind), rien ne change : l'hôte passe toujours par les NodePorts (`extraPortMappings`).

Appliquer (garder la version de chart déjà installée : `helm list -A`, colonne CHART) :

```bash
helm upgrade traefik traefik --repo https://traefik.github.io/charts --version <version installée> \
  -n <namespace de traefik> -f platform/traefik/values.yaml --wait
curl -sI http://<IP publique>/ | head -1                                   # 308 : redirection HTTPS
curl -sI http://x.<IP publique>.sslip.io/.well-known/acme-challenge/t | head -1   # 404 : pas redirigé
```

`Connection refused` sur le premier `curl` = le port 80 n'atteint pas Traefik, aucun certificat ne pourra être émis.

## 3. Installation (une fois par cluster)

Depuis la racine du repo, `KUBECONFIG` pointant vers le cluster (`~/.kube-12/kubeconfig-aws` en prod) :

```bash
helm upgrade --install cert-manager oci://quay.io/jetstack/charts/cert-manager \
  --version v1.21.3 --namespace cert-manager --create-namespace \
  -f platform/cert-manager/values.yaml --wait

kubectl apply -f platform/cert-manager/issuers/
kubectl get clusterissuer        # READY=True pour les deux
```

`READY=True` signifie que le compte ACME est créé chez Let's Encrypt (clé dans le Secret
`letsencrypt-*-account-key` du namespace `cert-manager`). Rien n'est émis à ce stade.
Fonctionne aussi en local : les ClusterIssuers sont `Ready`, mais aucun certificat ne peut être émis (§ 6).

## 4. Utilisation dans une Ingress

Une annotation et un bloc `tls` suffisent : cert-manager crée lui-même le `Certificate`
(nommé comme le Secret), Traefik sert le Secret dès qu'il existe.

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: grafana
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt-staging   # puis letsencrypt-prod
spec:
  ingressClassName: traefik
  tls:
    - hosts: [grafana.<IP publique>.sslip.io]
      secretName: grafana-tls
  rules:
    - host: grafana.<IP publique>.sslip.io
      http:
        paths:
          - {path: /, pathType: Prefix, backend: {service: {name: grafana, port: {number: 80}}}}
```

Règles :
- **tout nouveau hostname passe d'abord par `letsencrypt-staging`** ; une fois `READY=True`,
  passer l'annotation à `letsencrypt-prod` (cert-manager redemande le certificat tout seul) ;
- un hostname par service : pas de wildcard possible en HTTP-01 ;
- ne pas supprimer un Secret de certificat prod « pour voir » : c'est une nouvelle émission (§ 7).

## 5. Comment ça marche

```
 Certificate ──► CertificateRequest ──► Order (Let's Encrypt) ──► Challenge HTTP-01
                  (clé privée + CSR)     « prouvez que vous         │
                                          contrôlez ce nom »         ▼
                                       cert-manager crée un pod solver + Service + Ingress
                                       GET /.well-known/acme-challenge/<jeton>
                                                                     ▲
 Let's Encrypt ── DNS sslip.io ──► IP publique ──► kube-1:80 (hostPort) ──► Traefik
                                                                     │ jeton correct
                                                                     ▼
 Secret <nom>-tls (tls.crt, tls.key) ◄── certificat signé ◄── Order valide
        │ lu à chaud, pas de redémarrage
        ▼
 Traefik présente le certificat sur :443 (choisi selon le nom demandé, SNI)
```

1. cert-manager génère la clé privée (elle ne quitte jamais le cluster) et une demande de signature.
2. Il ouvre une commande (*Order*) chez Let's Encrypt, qui répond par un défi : publier un jeton
   à `http://<hostname>/.well-known/acme-challenge/<jeton>`.
3. Il crée un petit pod qui sert ce jeton, et une Ingress temporaire de classe `traefik` vers lui.
4. **Self-check** : cert-manager interroge lui-même cette URL, par l'IP publique, jusqu'à obtenir
   le jeton. Tant que ça échoue, Let's Encrypt n'est pas sollicité : pas d'échec compté.
5. Il demande à Let's Encrypt de valider ; Let's Encrypt résout le nom (sslip.io renvoie l'IP
   contenue dans le nom), se connecte au port 80, lit le jeton.
6. Commande validée : cert-manager récupère le certificat signé, l'écrit dans le Secret, supprime
   le pod, le Service et l'Ingress temporaires. Le `Certificate` passe `Ready=True`.
7. Aux 2/3 de la durée de vie, tout recommence, sans intervention ; le Secret est mis à jour en place.

Pour déboguer, descendre la chaîne dans cet ordre : `kubectl describe certificate`, puis
`certificaterequest`, `order`, `challenge` (même namespace que l'Ingress).

## 6. Local et prod

| | Local (kind) | Prod (AWS) |
|---|---|---|
| cert-manager, ClusterIssuers `Ready` | oui | oui |
| Émission d'un certificat | **impossible** | oui |
| HTTPS d'une Ingress | certificat par défaut de Traefik (avertissement navigateur) | certificat Let's Encrypt |

En local, `*.127.0.0.1.sslip.io` désigne la machine de chacun : Let's Encrypt ne peut pas la
joindre. Le `Certificate` reste `Ready=False` (self-check en échec), sans consommer de quota.
Les manifests restent identiques dans les deux environnements.

## 7. Quotas Let's Encrypt

| Limite (prod) | Valeur | Ce qui la déclenche chez nous |
|---|---|---|
| certificats par domaine enregistré | 50 / 7 jours, **globale** | `sslip.io` n'est pas dans la Public Suffix List : tous ses utilisateurs dans le monde partagent ce compteur (Let's Encrypt l'a relevé pour sslip.io, sans garantie) |
| certificats pour exactement les mêmes noms | 5 / 7 jours | redemander le même hostname : Secret supprimé, cluster recréé sur la même IP |
| échecs de validation par nom | 5 / heure | insister en prod sur un hostname mal configuré |

Les renouvellements ne comptent pas dans la première limite. Le staging a des limites très
larges : c'est là qu'on se trompe. Erreur `too many certificates` : attendre, ne pas relancer en boucle.

## 8. Test (critères d'acceptation)

Depuis `ansible/`, en prod, après les § 2 et 3 :

```bash
ansible-playbook -i inventory tests/tls.yml                                     # staging
ansible-playbook -i inventory tests/tls.yml -e tls_test_issuer=letsencrypt-prod # prod
```

Le playbook déploie `whoami` derrière une Ingress `tls-test.<IP publique>.sslip.io` et un
`Certificate`, attend un certificat émis par l'issuer demandé et `Ready=True`, puis, depuis la
machine qui lance Ansible (comme un navigateur) : vérifie l'émetteur du certificat présenté par
Traefik, et en prod fait une requête HTTPS **avec vérification de la chaîne de confiance**.
En cas d'échec, il affiche Certificate, Challenges, événements et logs de cert-manager.

Puis ouvrir `https://tls-test.<IP publique>.sslip.io` : cadenas valide, émetteur « Let's Encrypt ».
Les ressources restent en place ; relancer le test ne redemande pas de certificat.
Nettoyage : `ansible-playbook -i inventory tests/tls.yml -e tls_test_cleanup=true`.

## 9. Dépannage

| Symptôme | Cause | Solution |
|---|---|---|
| `failed calling webhook "webhook.cert-manager.io"` au `kubectl apply` | webhook pas encore prêt juste après l'installation | attendre 30 s (ou installer avec `--wait`) et relancer |
| ClusterIssuer `READY=False` | pas d'accès sortant vers `acme-*.api.letsencrypt.org` | `kubectl describe clusterissuer <nom>` |
| Challenge `pending`, `failed to perform self check GET request ... connection refused` | le port 80 de l'IP publique n'atteint pas Traefik (en local : normal) | § 2 : hostPort, security group |
| Challenge `pending`, self-check en `404` | Ingress du solver ignorée par Traefik | `kubectl get ingressclass` : le nom doit être `traefik` |
| Challenge `invalid`, `Timeout during connect (likely firewall problem)` | Let's Encrypt ne joint pas le port 80 depuis Internet | security group, IP publique dans le hostname |
| Order `errored`, `too many certificates ... already issued` | quota (§ 7) | attendre ; ne pas recréer le Secret |
| navigateur : « TRAEFIK DEFAULT CERT » | Secret absent ou `tls.hosts` différent du `host` de la règle | `kubectl get certificate -A` |
| navigateur : autorité « (STAGING) » | le Certificate est encore sur `letsencrypt-staging` | passer à `letsencrypt-prod` |

Commandes utiles : `kubectl get certificate,challenge -A`,
`kubectl -n cert-manager logs deploy/cert-manager --tail=50`.

## 10. Exploitation

- **Monter de version** : une version mineure à la fois, lire les notes de version, changer
  `--version` (§ 3) et l'en-tête de `values.yaml`. Les CRDs suivent le chart.
- **Supervision** (ticket monitoring) : cert-manager expose des métriques Prometheus (port 9402),
  dont `certmanager_certificate_expiration_timestamp_seconds` : alerter si un certificat expire
  dans moins de 14 jours (renouvellement en échec). Activer `prometheus.servicemonitor.enabled`
  quand Prometheus Operator sera installé.
- **GitOps** (ticket ArgoCD) : une Application pour le chart (OCI + `values.yaml`), une pour
  `platform/cert-manager/issuers/`, appliquée après les CRDs.

## 11. Tests réalisés

Sans cluster disponible pendant le développement, validations hors cluster :

| Test | Résultat |
|---|---|
| `helm template` cert-manager v1.21.3 avec `values.yaml` (schéma strict du chart) | OK : 6 CRDs (`helm.sh/resource-policy: keep`), 3 Deployments avec leurs requêtes |
| `helm template` Traefik 42.3.0 avec `platform/traefik/values.yaml` | OK : hostPort 80/443, `--entryPoints.web.allowACMEByPass=true`, stratégie 1/0, IngressClass `traefik` |
| `kubeconform -strict` : ClusterIssuers + manifests de `tests/tls.yml` + rendu Traefik, contre les CRDs v1.21.3 et les schémas Kubernetes | 18 ressources valides ; une faute de frappe volontaire est bien rejetée |

À faire sur le cluster AWS (critères d'acceptation) : § 2 (`curl` 308 puis 404), § 3
(`READY=True` × 2), `tests/tls.yml` en staging puis en prod, cadenas valide dans le navigateur.
