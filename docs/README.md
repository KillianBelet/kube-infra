# Documentation

| Document | Contenu |
|---|---|
| [../README.md](../README.md) | vue d'ensemble, environnement local (kind), prise en main |
| [infra-aws.md](infra-aws.md) | infrastructure AWS : ce qui est créé, prérequis, créer / éteindre / détruire, accès équipe, coûts |
| [runbook.md](runbook.md) | **reconstruire le cluster de zéro** : AWS → Kubernetes → Argo CD → services en HTTPS, vérifications, destruction |
| [conventions.md](conventions.md) | **règles communes** : requests/limits, labels recommandés, Helm ou kustomize, vérification (`scripts/check-conventions.py`) |
| [cluster-ansible.md](cluster-ansible.md) | cluster de prod : inventaire, rôles Ansible, choix techniques, dépannage |
| [cert-manager.md](cert-manager.md) | certificats TLS Let's Encrypt (HTTP-01 via Traefik) : installation, usage dans une Ingress, test, quotas, dépannage |
| [database.md](database.md) | base MySQL de l'application : chart, identifiants scellés, clé Sealed Secrets de l'équipe, test de persistance, sauvegardes et restauration |
| [gitops.md](gitops.md) | Argo CD app-of-apps : racine `bootstrap/`, Applications `apps/`, sync waves, auto-sync / prune / self-heal, tests, dépannage |
| [ingress.md](ingress.md) | hostnames `<service>.<IP>.sslip.io` et Ingress HTTPS de tous les services (chart `platform/ingress`) |
| [keycloak.md](keycloak.md) | Keycloak : base, secrets, realm `kube`, client dex, tests |

Chaque composant ajouté au cluster (Traefik, ArgoCD, Keycloak…) a sa page ici :
ce qu'il fait, comment le déployer, comment vérifier qu'il marche, pannes connues.
