

python3 - <<'PY'
import os, sys, subprocess, textwrap, re
from pathlib import Path

REPO = os.getenv("REPO_URL", "https://github.com/Athithya-Sakthivel/RAG8s.git")
BR = os.getenv("BRANCH", "main")
MANIFEST_PATH = Path(os.getenv("MANIFEST_PATH", "infra/manifests"))
EXCLUDE = os.getenv("EXCLUDE_DIR", "jobs")
FLUX_NS = os.getenv("FLUX_NS", "flux-system")
GITNAME = "rag8s"

def sanitize(n):
    return re.sub(r'[^a-z0-9-]', '-', n.lower()).strip('-')[:63]

if not MANIFEST_PATH.is_dir():
    print(f"Manifest path not found: {MANIFEST_PATH}", file=sys.stderr)
    sys.exit(1)

gitrepo = textwrap.dedent(f"""\
apiVersion: source.toolkit.fluxcd.io/v1
kind: GitRepository
metadata:
  name: {GITNAME}
  namespace: {FLUX_NS}
spec:
  interval: 1m0s
  url: {REPO}
  ref:
    branch: {BR}
""")

r = subprocess.run("kubectl apply -f -", shell=True, input=gitrepo, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
if r.returncode != 0:
    sys.exit(1)

subprocess.run(f"kubectl wait gitrepository/{GITNAME} -n {FLUX_NS} --for=condition=Ready --timeout=60s", shell=True)
subprocess.run(f"flux reconcile source git {GITNAME} -n {FLUX_NS}", shell=True)

kustomizations = []
dirs = [d for d in sorted(MANIFEST_PATH.iterdir()) if d.is_dir() and d.name != EXCLUDE]
for d in dirs:
    name = sanitize(d.name)
    subprocess.run(f"kubectl create ns {name} --dry-run=client -o yaml | kubectl apply -f -", shell=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    ky = textwrap.dedent(f"""\
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: {GITNAME}-{name}
  namespace: {FLUX_NS}
spec:
  interval: 1m0s
  prune: true
  sourceRef:
    kind: GitRepository
    name: {GITNAME}
  path: ./{MANIFEST_PATH.as_posix()}/{d.name}
  targetNamespace: {name}
""")
    kustomizations.append(ky)

if kustomizations:
    allk = "\n---\n".join(kustomizations)
    r = subprocess.run("kubectl apply -f -", shell=True, input=allk, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if r.returncode != 0:
        sys.exit(1)
    for d in dirs:
        name = sanitize(d.name)
        subprocess.run(f"flux reconcile kustomization {GITNAME}-{name} -n {FLUX_NS}", shell=True)
        subprocess.run(f"kubectl wait kustomization/{GITNAME}-{name} -n {FLUX_NS} --for=condition=Ready --timeout=60s", shell=True)
PY
