# Bootstrap sekali jalan untuk pipeline Tekton — versi PowerShell (Windows).
#
#   powershell -ExecutionPolicy Bypass -File tekton\setup.ps1
#
# Membuat namespace cicd + dev, Secret Docker Hub, RBAC, dan semua Task/Pipeline.
# Token Docker Hub dibaca dari .\secret.md yang sengaja masuk .gitignore.

$ErrorActionPreference = "Stop"

Set-Location (Join-Path $PSScriptRoot "..")

$DockerHubUser = if ($env:DOCKERHUB_USER) { $env:DOCKERHUB_USER } else { "dadin" }
$SecretFile    = if ($env:SECRET_FILE)    { $env:SECRET_FILE }    else { "secret.md" }

if (-not (Test-Path $SecretFile)) {
    Write-Error "$SecretFile tidak ada. Isi file itu dengan Docker Hub access token (dckr_pat_...)."
}

# Baris non-kosong pertama, dibersihkan dari spasi dan CR.
$Token = (Get-Content $SecretFile | Where-Object { $_.Trim() -ne "" } | Select-Object -First 1).Trim()

if ([string]::IsNullOrWhiteSpace($Token)) {
    Write-Error "Tidak menemukan token di $SecretFile"
}

Write-Host "==> Namespace" -ForegroundColor Cyan
kubectl create namespace cicd --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f k8s/namespace.yaml

Write-Host "==> Secret Docker Hub (namespace cicd)" -ForegroundColor Cyan
# Dibuat ulang tiap kali supaya rotasi token cukup dengan mengubah secret.md.
kubectl create secret docker-registry dockerhub-secret `
    --namespace cicd `
    --docker-server=https://index.docker.io/v1/ `
    --docker-username=$DockerHubUser `
    --docker-password=$Token `
    --dry-run=client -o yaml | kubectl apply -f -

Write-Host "==> RBAC" -ForegroundColor Cyan
kubectl apply -f tekton/rbac.yml

Write-Host "==> Task" -ForegroundColor Cyan
kubectl apply `
    -f tekton/task-git-clone.yaml `
    -f tekton/task-backend-test.yaml `
    -f tekton/task-frontend-test.yaml `
    -f tekton/task-backend-build.yaml `
    -f tekton/task-frontend-build.yaml `
    -f tekton/task-deploy.yaml

Write-Host "==> Pipeline" -ForegroundColor Cyan
kubectl apply -f tekton/pipeline.yaml

Write-Host @"

Setup selesai. Jalankan pipeline:

  kubectl create -f tekton\pipelinerun.yaml
  tkn pipelinerun logs -n cicd --last -f

Setelah deploy sukses, buka aplikasinya di:

  http://localhost:8090

Service frontend bertipe LoadBalancer, dan Docker Desktop mem-publish-nya
langsung ke localhost. NodePort (30080) TIDAK bisa diakses dari Windows.

"@ -ForegroundColor Green
