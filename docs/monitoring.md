# Monitoring : kube-prometheus-stack (#45)

Prometheus collecte les métriques du cluster, des nœuds et de l'application. Alertmanager reçoit les
alertes de Prometheus. node-exporter tourne sur chaque nœud.

| | |
|---|---|
| Chart | `kube-prometheus-stack` 94.1.0 (https://prometheus-community.github.io/helm-charts) |
| Namespace | `monitoring` |
| Application Argo CD | `kube-prometheus-stack` (wave 1, `apps/local` et `apps/prod`) |
| Prometheus | Service `kube-prometheus-stack-prometheus:9090`, volume `efs-sc` |
| Alertmanager | Service `kube-prometheus-stack-alertmanager:9093`, volume `efs-sc` |

Wave 1 : les CRDs (`ServiceMonitor`, `PrometheusRule`...) doivent exister avant l'application (wave 3), qui
déclare son propre `ServiceMonitor` (#58).

## 1. Fichiers

| Fichier | Rôle |
|---|---|
| `apps/local/kube-prometheus-stack.yaml`, `apps/prod/kube-prometheus-stack.yaml` | Application Argo CD |
| `platform/monitoring/values.yaml` | values communes : rétention, volumes, ressources, exporters |
| `platform/monitoring/values-local.yaml` | local : rétention et volume plus petits |

## 2. Ce qui est déployé

| Composant | Type | Où |
|---|---|---|
| Prometheus | StatefulSet (1 replica) | volume `efs-sc` 10 Gi, rétention 7 jours ou 8 Go (local : 2 jours, 2 Gi) |
| Alertmanager | StatefulSet (1 replica) | volume `efs-sc` 1 Gi |
| prometheus-operator | Deployment | crée Prometheus et Alertmanager à partir des CRDs |
| node-exporter | DaemonSet | un pod par nœud, kube-1 compris |
| kube-state-metrics | Deployment | état des objets Kubernetes |

Prometheus lit les `ServiceMonitor`, `PodMonitor` et `PrometheusRule` de **tous** les namespaces, sans label
imposé (`*SelectorNilUsesHelmValues: false`). Un composant n'a qu'à déclarer son `ServiceMonitor`.

Grafana fait partie du chart mais il est désactivé ici : il arrive avec #47.

## 3. Composants du control plane

kubeadm fait écouter le controller-manager, le scheduler, les métriques d'etcd et kube-proxy sur `127.0.0.1` :
Prometheus ne peut pas les joindre. Ils écoutent sur toutes les interfaces :

| Composant | Port | Réglage |
|---|---|---|
| kube-controller-manager | 10257 (HTTPS) | `bind-address: 0.0.0.0` |
| kube-scheduler | 10259 (HTTPS) | `bind-address: 0.0.0.0` |
| etcd (métriques seules) | 2381 (HTTP) | `listen-metrics-urls: http://0.0.0.0:2381` |
| kube-proxy | 10249 (HTTP) | `metricsBindAddress: 0.0.0.0:10249` |

- Prod : `ansible/roles/control_plane/templates/kubeadm-config.yaml.j2`. Le security group n'ouvre ces ports
  qu'entre les nœuds.
- Local : `kubeadmConfigPatches` de `ansible/templates/kind-config.yaml.j2`.

Ces réglages sont pris à la création du cluster. Sur un cluster existant : recréer le cluster local
(`local-down.yml` puis `local.yml`) ; en prod, modifier les manifests statiques de kube-1
(`/etc/kubernetes/manifests/`) et la ConfigMap `kube-proxy`, ou reconstruire le cluster (runbook).

## 4. Vérifier

```bash
kubectl -n argocd get application kube-prometheus-stack
kubectl -n monitoring get pods -o wide
kubectl -n monitoring get ds kube-prometheus-stack-prometheus-node-exporter   # DESIRED = READY = 3
```

Targets :

```bash
kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus 9090
# http://localhost:9090/targets, ou :
curl -s localhost:9090/api/v1/targets | jq -r '.data.activeTargets[] | "\(.health) \(.labels.job) \(.scrapeUrl)"' | sort
```

Toutes les lignes doivent commencer par `up`.

Testé sur kind (3 nœuds, cluster recréé avec la nouvelle config) : 27 targets `up` (apiserver, kubelet x3,
node-exporter x3, kube-proxy x3, controller-manager, scheduler, etcd, coredns, kube-state-metrics, opérateur,
Prometheus, Alertmanager), volumes liés en `efs-sc`, aucun refus des ValidatingAdmissionPolicies. Config kubeadm
de prod validée avec `kubeadm config validate`. Pas encore testé sur AWS.

## 5. Dépannage

| Symptôme | Piste |
|---|---|
| target `kube-scheduler` / `kube-controller-manager` / `kube-etcd` / `kube-proxy` en `down`, `connection refused` | cluster créé avant ce réglage (§ 3) |
| Prometheus en `Pending` | volume `efs-sc` non lié : `kubectl -n monitoring describe pvc` |
| Application `OutOfSync` sur les CRDs | `ServerSideApply=true` retiré de l'Application (CRDs trop grosses pour `kubectl apply`) |
| un `ServiceMonitor` n'apparaît pas dans les targets | le Service n'a pas le port nommé dans le `ServiceMonitor`, ou les labels du `selector` ne correspondent pas |
