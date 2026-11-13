# Documentation

| Document | Contenu |
|---|---|
| [../README.md](../README.md) | vue d'ensemble, environnement local (kind), prise en main |
| [infra-aws.md](infra-aws.md) | infrastructure AWS : ce qui est créé, prérequis, créer / éteindre / détruire, accès équipe, coûts |
| [cluster-ansible.md](cluster-ansible.md) | cluster de prod : inventaire, rôles Ansible, choix techniques, dépannage |
| [cert-manager.md](cert-manager.md) | certificats TLS Let's Encrypt (HTTP-01 via Traefik) : installation, usage dans une Ingress, test, quotas, dépannage |
| [argocd.md](argocd.md) | Argo CD (GitOps) exposé en HTTPS : bootstrap Ansible, dépôts Git en lecture seule, première connexion, test, dépannage |

Chaque composant ajouté au cluster (Traefik, ArgoCD, Keycloak…) a sa page ici :
ce qu'il fait, comment le déployer, comment vérifier qu'il marche, pannes connues.
