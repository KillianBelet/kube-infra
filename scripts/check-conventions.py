#!/usr/bin/env python3
"""Vérifie les conventions du repo (#80) sans cluster : requests/limits et labels recommandés.

    python3 scripts/check-conventions.py              # env local (apps/common + apps/local)
    python3 scripts/check-conventions.py --env prod   # apps/common + apps/prod
    python3 scripts/check-conventions.py -v           # détail par composant

Rend chaque Application Argo CD de apps/ comme le ferait Argo CD (chart Helm + valueFiles +
valuesObject, chart local, kustomize ou manifests bruts), plus Argo CD lui-même (installé par
Ansible), puis vérifie :
  - chaque conteneur (et init container) : requests cpu/memory et limits cpu/memory ;
  - chaque modèle de pod : label app.kubernetes.io/name ;
  - chaque ressource : labels app.kubernetes.io/name et app.kubernetes.io/part-of.
Les sources hors de ce repo (repo applicatif) sont ignorées. Voir docs/conventions.md.
Prérequis : helm, kubectl, python3-yaml.
"""
import argparse
import glob
import os
import subprocess
import sys
import tempfile

import yaml

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
REPO_URL = "https://github.com/KillianBelet/kube-infra"
WORKLOADS = {"Deployment", "StatefulSet", "DaemonSet", "Job", "CronJob", "Pod", "ReplicaSet"}
# Ressources sans pod ni intérêt à labelliser (générées par les charts pour Helm lui-même)
SKIP_LABEL_KINDS = {"CustomResourceDefinition"}
NAME = "app.kubernetes.io/name"
PART_OF = "app.kubernetes.io/part-of"
# Charts qui ne posent pas app.kubernetes.io/name sur toutes leurs ressources et ne permettent pas
# de l'ajouter sans doublon (commonLabels le répète là où il existe déjà). Les pods l'ont toujours.
NAME_OPTIONAL = {"kube-prometheus-stack"}


def run(cmd, cwd=None):
    res = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True)
    if res.returncode != 0:
        raise RuntimeError(f"{' '.join(cmd)}\n{res.stderr.strip()}")
    return res.stdout


def docs(text):
    return [d for d in yaml.safe_load_all(text) if isinstance(d, dict) and d.get("kind")]


def render_helm(app_name, ns, src, values_ref):
    helm = src.get("helm", {})
    cmd = ["helm", "template", helm.get("releaseName", app_name), "--namespace", ns]
    if src.get("chart"):  # dépôt Helm classique
        cmd += [src["chart"], "--repo", src["repoURL"], "--version", src["targetRevision"]]
        base = ROOT
    elif src["repoURL"].startswith("oci://"):
        cmd += [src["repoURL"], "--version", src["targetRevision"]]
        base = ROOT
    else:  # chart local du repo
        base = os.path.join(ROOT, src["path"])
        cmd += [base]
    for vf in helm.get("valueFiles", []):
        path = vf.replace("$values/", ROOT + "/") if vf.startswith("$values/") else os.path.join(base, vf)
        if vf.startswith("$values/") and not values_ref:
            raise RuntimeError(f"{app_name} : $values sans source ref")
        cmd += ["-f", path]
    tmp = None
    if helm.get("valuesObject"):
        tmp = tempfile.NamedTemporaryFile("w", suffix=".yaml", delete=False)
        yaml.safe_dump(helm["valuesObject"], tmp)
        tmp.close()
        cmd += ["-f", tmp.name]
    try:
        return docs(run(cmd))
    finally:
        if tmp:
            os.unlink(tmp.name)


def render_path(app_name, ns, src):
    path = os.path.join(ROOT, src["path"])
    if os.path.exists(os.path.join(path, "Chart.yaml")):
        return render_helm(app_name, ns, src, True)
    if os.path.exists(os.path.join(path, "kustomization.yaml")):
        return docs(run(["kubectl", "kustomize", path]))
    out = []
    for f in sorted(glob.glob(os.path.join(path, "*.yaml"))):
        with open(f, encoding="utf-8") as fh:
            out += docs(fh.read())
    return out


def render_app(app):
    name = app["metadata"]["name"]
    ns = app["spec"]["destination"].get("namespace", "default")
    sources = app["spec"].get("sources") or [app["spec"]["source"]]
    values_ref = any(s.get("ref") == "values" for s in sources)
    out = []
    for src in sources:
        if src.get("ref"):
            continue
        if src.get("chart") or src["repoURL"].startswith("oci://"):
            out += render_helm(name, ns, src, values_ref)
        elif src["repoURL"].rstrip("/") == REPO_URL:
            out += render_path(name, ns, src)
        # autre repo (application) : vérifié dans son propre repo
    for d in out:
        d.setdefault("metadata", {}).setdefault("namespace", ns)
    return out


def argocd_install():
    """Argo CD est installé par Ansible (roles/argocd), pas par une Application."""
    defaults = yaml.safe_load(open(os.path.join(ROOT, "ansible/roles/argocd/defaults/main.yml"), encoding="utf-8"))
    src = {"repoURL": defaults["argocd_chart_repo"], "chart": "argo-cd",
           "targetRevision": defaults["argocd_chart_version"],
           "helm": {"releaseName": "argocd", "valueFiles": ["$values/platform/argocd/values.yaml"]}}
    return render_helm("argocd", "argocd", src, True)


def pod_spec(d):
    spec = d.get("spec", {})
    if d["kind"] == "Pod":
        return d.get("metadata", {}), spec
    if d["kind"] == "CronJob":
        spec = spec.get("jobTemplate", {}).get("spec", {})
    tpl = spec.get("template", {})
    return tpl.get("metadata", {}), tpl.get("spec", {})


def check(component, objs):
    problems = []
    for d in objs:
        kind, meta = d["kind"], d.get("metadata", {})
        ref = f"{kind}/{meta.get('name')}"
        labels = meta.get("labels") or {}
        if kind not in SKIP_LABEL_KINDS:
            required = (PART_OF,) if component in NAME_OPTIONAL else (NAME, PART_OF)
            missing = [k for k in required if k not in labels]
            if missing:
                problems.append(f"{ref} : labels absents {', '.join(missing)}")
        if kind not in WORKLOADS:
            continue
        pmeta, pspec = pod_spec(d)
        if NAME not in (pmeta.get("labels") or {}):
            problems.append(f"{ref} : pod sans label {NAME}")
        for c in pspec.get("initContainers", []) + pspec.get("containers", []):
            res = c.get("resources") or {}
            miss = [f"{k}.{r}" for k in ("requests", "limits") for r in ("cpu", "memory")
                    if r not in (res.get(k) or {})]
            if miss:
                problems.append(f"{ref} conteneur {c['name']} : {', '.join(miss)} absent(s)")
    return problems


def main():
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    p.add_argument("--env", choices=["local", "prod"], default="local")
    p.add_argument("-v", "--verbose", action="store_true")
    args = p.parse_args()

    apps = []
    for f in sorted(glob.glob(os.path.join(ROOT, "apps/common/*.yaml")) +
                    glob.glob(os.path.join(ROOT, f"apps/{args.env}/*.yaml"))):
        with open(f, encoding="utf-8") as fh:
            apps += [d for d in docs(fh.read()) if d["kind"] == "Application"]

    components = [("argocd", argocd_install)] + [(a["metadata"]["name"], lambda a=a: render_app(a)) for a in apps]
    total = 0
    for name, render in components:
        try:
            objs = render()
        except RuntimeError as e:
            print(f"[ERREUR] {name} : rendu impossible\n  {e}")
            total += 1
            continue
        problems = check(name, objs)
        total += len(problems)
        status = "OK" if not problems else f"{len(problems)} écart(s)"
        print(f"[{status}] {name} ({len(objs)} ressources)")
        if problems and (args.verbose or len(problems) <= 15):
            for pb in problems:
                print(f"    - {pb}")
        elif problems:
            for pb in problems[:15]:
                print(f"    - {pb}")
            print(f"    … {len(problems) - 15} de plus (-v)")
    print(f"\n{total} écart(s) au total ({args.env}).")
    return 1 if total else 0


if __name__ == "__main__":
    sys.exit(main())
