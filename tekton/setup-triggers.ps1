# Bootstrap Tekton Triggers -- pipeline berjalan otomatis setiap "git push".
#
#   powershell -ExecutionPolicy Bypass -File tekton\setup-triggers.ps1
#
# Prasyarat: tekton\setup.ps1 sudah dijalankan (namespace, Pipeline, dan Task
# harus sudah ada).
#
# Yang dikerjakan:
#   1. Memastikan Tekton Triggers terpasang di cluster
#   2. Membuat token webhook acak (sekali saja, disimpan di webhook-secret.txt)
#   3. Membuat Secret token itu di namespace cicd
#   4. Menerapkan RBAC, TriggerBinding, TriggerTemplate, EventListener
#   5. Mengekspos EventListener ke localhost lewat Service LoadBalancer
#   6. Mengaktifkan git hook pre-push

$ErrorActionPreference = "Stop"

Set-Location (Join-Path $PSScriptRoot "..")

$SecretFile = "webhook-secret.txt"
$Port       = 8095

# --- 1. Cek Tekton Triggers ------------------------------------------------
Write-Host "==> Memeriksa Tekton Triggers" -ForegroundColor Cyan

$crd = kubectl get crd eventlisteners.triggers.tekton.dev --ignore-not-found 2>$null

if (-not $crd) {
    Write-Host "    Tekton Triggers belum terpasang. Memasang sekarang..." -ForegroundColor Yellow
    kubectl apply -f https://storage.googleapis.com/tekton-releases/triggers/latest/release.yaml
    kubectl apply -f https://storage.googleapis.com/tekton-releases/triggers/latest/interceptors.yaml
    Write-Host "    Menunggu controller siap..."
    kubectl wait --for=condition=Available --timeout=180s -n tekton-pipelines `
        deployment/tekton-triggers-controller deployment/tekton-triggers-core-interceptors
} else {
    Write-Host "    sudah terpasang"
}

# --- 2. Token webhook ------------------------------------------------------
Write-Host "==> Token webhook" -ForegroundColor Cyan

if (-not (Test-Path $SecretFile)) {
    # 32 byte acak -> 64 karakter hex. Ditulis TANPA newline: byte tambahan
    # apa pun ikut masuk ke token dan membuat verifikasi HMAC gagal.
    $bytes = New-Object byte[] 32
    [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
    $token = ($bytes | ForEach-Object { $_.ToString("x2") }) -join ""

    [System.IO.File]::WriteAllText((Join-Path (Get-Location) $SecretFile), $token)
    Write-Host "    dibuat baru: $SecretFile (64 karakter)"
} else {
    Write-Host "    memakai yang sudah ada: $SecretFile"
}

$token = [System.IO.File]::ReadAllText((Join-Path (Get-Location) $SecretFile)).Trim()

if ($token.Length -lt 20) {
    Write-Error "Token di $SecretFile terlalu pendek ($($token.Length) karakter). Hapus file itu lalu jalankan ulang."
}

# Pastikan tidak ikut ter-commit
$ignored = git check-ignore $SecretFile 2>$null
if (-not $ignored) {
    Write-Error "$SecretFile TIDAK ada di .gitignore. Tambahkan dulu sebelum lanjut."
}

# --- 3. Secret di cluster --------------------------------------------------
Write-Host "==> Secret github-webhook-secret (namespace cicd)" -ForegroundColor Cyan

kubectl create secret generic github-webhook-secret `
    --namespace cicd `
    --from-literal=secretToken=$token `
    --dry-run=client -o yaml | kubectl apply -f -

# --- 4. Resource Triggers --------------------------------------------------
Write-Host "==> RBAC + TriggerBinding + TriggerTemplate + EventListener" -ForegroundColor Cyan

kubectl apply `
    -f tekton/triggers/rbac.yml `
    -f tekton/triggers/trigger-binding.yaml `
    -f tekton/triggers/trigger-template.yaml `
    -f tekton/triggers/event-listener.yaml

Write-Host "    Menunggu EventListener siap..."
kubectl wait --for=condition=Ready --timeout=180s -n cicd `
    pod -l eventlistener=employee-push-listener

# --- 5. Ekspos ke localhost ------------------------------------------------
Write-Host "==> Service LoadBalancer (localhost:$Port)" -ForegroundColor Cyan

kubectl apply -f tekton/triggers/service-webhook.yaml

Start-Sleep -Seconds 10

$listening = netstat -ano | Select-String ":$Port\s.*LISTENING"
if ($listening) {
    Write-Host "    localhost:$Port sudah menerima koneksi"
} else {
    Write-Host "    PERINGATAN: belum ada yang listen di port $Port." -ForegroundColor Yellow
    Write-Host "    Kalau port itu dipakai proses lain, ubah 'port' di" -ForegroundColor Yellow
    Write-Host "    tekton/triggers/service-webhook.yaml lalu HAPUS + apply ulang:" -ForegroundColor Yellow
    Write-Host "      kubectl delete svc -n cicd el-webhook" -ForegroundColor Yellow
    Write-Host "      kubectl apply -f tekton/triggers/service-webhook.yaml" -ForegroundColor Yellow
}

# --- 6. Git hook -----------------------------------------------------------
Write-Host "==> Mengaktifkan git hook" -ForegroundColor Cyan

git config core.hooksPath githooks

# Di Windows bit executable tidak selalu terbawa; Git for Windows tetap
# menjalankan hook lewat sh, tapi flag ini dicatat agar konsisten di Linux/mac.
git update-index --chmod=+x githooks/pre-push 2>$null | Out-Null

Write-Host "    core.hooksPath = $(git config core.hooksPath)"

Write-Host @"

Selesai. Mulai sekarang setiap "git push" ke main memicu pipeline otomatis.

Coba:
  git commit --allow-empty -m "uji trigger"
  git push origin main

Pantau:
  kubectl get pipelinerun -n cicd -l trigger=github-push
  tkn pipelinerun logs -n cicd --last -f
  Get-Content .git\tekton-trigger.log -Tail 20

Mematikan sementara untuk satu push:
  `$env:SKIP_TEKTON=1; git push; `$env:SKIP_TEKTON=`$null

Mematikan hook sepenuhnya:
  git config --unset core.hooksPath

"@ -ForegroundColor Green
