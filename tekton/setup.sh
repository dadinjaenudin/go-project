#!/usr/bin/env bash
#
# Bootstrap sekali jalan untuk pipeline Tekton.
#
#   bash tekton/setup.sh
#
# Membuat namespace cicd + dev, Secret Docker Hub, RBAC, dan semua Task/Pipeline.
# Token Docker Hub dibaca dari ./secret.md yang sengaja masuk .gitignore.

set -euo pipefail

cd "$(dirname "$0")/.."

DOCKERHUB_USER="${DOCKERHUB_USER:-dadin}"
SECRET_FILE="${SECRET_FILE:-secret.md}"

if [[ ! -f "$SECRET_FILE" ]]; then
  echo "ERROR: $SECRET_FILE tidak ada. Isi file itu dengan Docker Hub access token (dckr_pat_...)." >&2
  exit 1
fi

# Ambil token: baris non-kosong pertama, buang spasi/CR.
TOKEN="$(tr -d '\r' < "$SECRET_FILE" | grep -v '^[[:space:]]*$' | head -n1 | xargs)"

if [[ -z "$TOKEN" ]]; then
  echo "ERROR: tidak menemukan token di $SECRET_FILE" >&2
  exit 1
fi

echo "==> Namespace"
kubectl create namespace cicd --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f k8s/namespace.yaml

echo "==> Secret Docker Hub (namespace cicd)"
# Dibuat ulang tiap kali supaya rotasi token cukup dengan mengubah secret.md.
kubectl create secret docker-registry dockerhub-secret \
  --namespace cicd \
  --docker-server=https://index.docker.io/v1/ \
  --docker-username="$DOCKERHUB_USER" \
  --docker-password="$TOKEN" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "==> RBAC"
kubectl apply -f tekton/rbac.yml

echo "==> Task"
kubectl apply \
  -f tekton/task-git-clone.yaml \
  -f tekton/task-backend-test.yaml \
  -f tekton/task-frontend-test.yaml \
  -f tekton/task-backend-build.yaml \
  -f tekton/task-frontend-build.yaml \
  -f tekton/task-deploy.yaml

echo "==> Pipeline"
kubectl apply -f tekton/pipeline.yaml

cat <<'DONE'

Setup selesai. Jalankan pipeline:

  kubectl create -f tekton/pipelinerun.yaml
  tkn pipelinerun logs -n cicd --last -f

Setelah deploy sukses, buka aplikasinya di:

  http://localhost:8090

Service frontend bertipe LoadBalancer, dan Docker Desktop mem-publish-nya
langsung ke localhost. NodePort (30080) TIDAK bisa diakses dari Windows.

DONE
