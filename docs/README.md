# Documentation

| Document | Contenu |
|---|---|
| [../README.md](../README.md) | vue d'ensemble, environnement local (kind), prise en main |
| [infra-aws.md](infra-aws.md) | infrastructure AWS : ce qui est créé, prérequis, créer / éteindre / détruire, accès équipe, coûts |
| [cluster-ansible.md](cluster-ansible.md) | cluster de prod : inventaire, rôles Ansible, choix techniques, dépannage |
| [cert-manager.md](cert-manager.md) | certificats TLS Let's Encrypt (HTTP-01 via Traefik) : installation, usage dans une Ingress, test, quotas, dépannage |
| [gitops.md](gitops.md) | Argo CD app-of-apps : racine `bootstrap/`, Applications `apps/`, sync waves, auto-sync / prune / self-heal, tests, dépannage |

Chaque composant ajouté au cluster (Traefik, ArgoCD, Keycloak…) a sa page ici :
ce qu'il fait, comment le déployer, comment vérifier qu'il marche, pannes connues.
