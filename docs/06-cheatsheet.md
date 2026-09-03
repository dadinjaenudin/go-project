# Bab 6 — Cheatsheet

Perintah yang sering dipakai. Semua sudah diuji di lingkungan project ini (Windows + PowerShell + Docker Desktop).

---

## Docker

```powershell
# Build
docker build -f Dockerfile-go -t dadin/go-backend:v1 .
docker build -f ui/Dockerfile -t dadin/go-frontend:v1 ui    # perhatikan context "ui"

# Lihat
docker images
docker images --filter "reference=dadin/*" --format "{{.Repository}}:{{.Tag}}  {{.Size}}"
docker ps                          # container yang jalan
docker ps -a                       # termasuk yang mati

# Jalankan
docker run --rm -p 8888:8888 dadin/go-backend:v1
docker run -d --name be dadin/go-backend:v1        # -d = background
docker logs -f be
docker exec -it be sh                              # masuk ke dalam container
docker rm -f be

# Registry
Get-Content secret.md | docker login -u dadin --password-stdin
docker push dadin/go-backend:v1
docker pull dadin/go-backend:32b21ca
docker manifest inspect nginx:1.29-alpine          # cek tag ADA tanpa menariknya

# Bersih-bersih
docker rmi dadin/go-backend:v1
docker system df                                   # berapa disk terpakai
docker system prune                                # hapus yang tidak terpakai
```

### Menjalankan perintah tanpa memasang tool-nya

Berguna karena Go tidak terpasang di Windows ini:

```powershell
docker run --rm -v "D:\MY-Project\go-project:/src" -w /src golang:1.27-alpine `
  sh -c "go vet ./... && go test ./... -v"
```

- `--rm` hapus container setelah selesai
- `-v host:container` pasang folder Windows ke dalam container
- `-w` folder kerja di dalam container

---

## kubectl — dasar

```powershell
# Konteks & cluster
kubectl config current-context
kubectl config get-contexts
kubectl config use-context docker-desktop
kubectl cluster-info
kubectl get nodes -o wide

# Melihat objek
kubectl get pods -n dev
kubectl get all -n dev
kubectl get deploy,svc -n dev
kubectl get pods -A                    # semua namespace
kubectl get pods -n dev -o wide        # + IP dan node
kubectl get pods -n dev -w             # pantau perubahan langsung

# Detail & log
kubectl describe pod <nama> -n dev
kubectl logs <nama-pod> -n dev
kubectl logs <nama-pod> -n dev -f
kubectl logs <nama-pod> -n dev --previous     # log container SEBELUM restart
kubectl exec -it <nama-pod> -n dev -- sh

# Menerapkan & menghapus
kubectl apply -f k8s\backend-deployment.yaml
kubectl apply -f k8s\ -n dev                  # seluruh folder
kubectl delete -f k8s\ -n dev
kubectl delete pod <nama> -n dev              # akan dibuat ulang oleh Deployment

# Validasi TANPA menerapkan  <- biasakan!
kubectl apply --dry-run=server -f k8s\backend-deployment.yaml
```

## kubectl — sering dipakai di project ini

```powershell
# Image apa yang SEDANG jalan
kubectl get deploy -n dev -o custom-columns='NAME:.metadata.name,IMAGE:.spec.template.spec.containers[0].image'

# Ganti image manual
kubectl set image -n dev deployment/employee-backend backend=dadin/go-backend:32b21ca

# Tunggu rollout selesai
kubectl rollout status -n dev deployment/employee-backend

# Riwayat & rollback
kubectl rollout history -n dev deployment/employee-backend
kubectl rollout undo -n dev deployment/employee-backend

# Paksa buat pod baru tanpa ganti image
kubectl rollout restart -n dev deployment/employee-backend

# Events terbaru (paling berguna saat error)
kubectl get events -n dev --sort-by=.lastTimestamp | Select-Object -Last 20

# Akses aplikasi kalau LoadBalancer bermasalah
kubectl port-forward -n dev svc/employee-frontend 8090:8090

# Uji dari DALAM cluster
kubectl run smoke --rm -i --restart=Never -n dev --image=curlimages/curl:8.11.1 -- `
  curl -s http://employee-backend:8888/api/health
```

## kubectl — RBAC

```powershell
kubectl auth can-i create deployments.apps -n dev --as=system:serviceaccount:cicd:tekton-deployer
kubectl auth can-i --list -n dev --as=system:serviceaccount:cicd:tekton-deployer
kubectl get sa,role,rolebinding -n dev
```

## kubectl — Secret

```powershell
kubectl get secret -n cicd
kubectl describe secret dockerhub-secret -n cicd

# Buat / perbarui secret registry.
# Token dibaca ke variabel dulu -- bentuk $(...).Trim() langsung di posisi
# argumen tidak bisa di-parse PowerShell.
$token = (Get-Content secret.md -Raw).Trim()

# Pola "create --dry-run | apply" dipakai supaya bisa dijalankan berulang:
# create biasa akan error "already exists" kalau secret sudah ada.
kubectl create secret docker-registry dockerhub-secret `
  --namespace cicd `
  --docker-server=https://index.docker.io/v1/ `
  --docker-username=dadin `
  --docker-password=$token `
  --dry-run=client -o yaml | kubectl apply -f -
```

---

## Tekton

```powershell
# Pasang / lihat definisi
kubectl apply -f tekton\task-backend-test.yaml
kubectl get tasks -n cicd
kubectl get pipeline -n cicd

# Jalankan  <- create, BUKAN apply
kubectl create -f tekton\pipelinerun.yaml

# Status
kubectl get pipelinerun -n cicd
kubectl get taskrun -n cicd
kubectl describe pipelinerun -n cicd <nama>

# Log
tkn pipelinerun logs -n cicd --last -f
tkn pipelinerun logs -n cicd <nama> -f
tkn taskrun logs -n cicd <nama-taskrun> -f
kubectl logs -n cicd -l tekton.dev/pipelineTask=backend-build --tail=50

# Result yang dihasilkan sebuah task
kubectl get taskrun -n cicd <nama-taskrun> -o jsonpath='{.status.results}'

# Batalkan / hapus
tkn pipelinerun cancel -n cicd <nama>
kubectl delete pipelinerun -n cicd <nama>
kubectl delete pipelinerun --all -n cicd

# Ringkasan dengan tkn
tkn pipelinerun list -n cicd
tkn pipelinerun describe -n cicd --last
tkn task list -n cicd
```

---

## Git

```powershell
git status
git status --short
git add -A
git commit -m "pesan"
git push origin main

git log --oneline -10
git show 32b21ca                       # lihat kode di balik sebuah tag image
git diff
git diff --cached                      # yang sudah di-stage

# Pastikan file rahasia diabaikan
git check-ignore -v secret.md
git ls-files secret.md                 # HARUS kosong

# Bandingkan lokal vs GitHub
git fetch origin
git log --oneline -1 HEAD
git log --oneline -1 origin/main
```

---

## Diagnosa jaringan (Windows)

```powershell
# Siapa yang listen di sebuah port
netstat -ano | Select-String ":8090"

# Proses apa itu
Get-Process -Id <PID>

# Uji HTTP
curl.exe -s -o NUL -w "HTTP %{http_code}`n" http://localhost:8090/
curl.exe -s http://localhost:8090/api/health
```

---

## Cek status deploy (paling sering dipakai)

```
.\cek.cmd            cek sekali
.\cek.cmd -Watch     pantau sampai pipeline selesai
.\cek.cmd -Fetch     ambil dulu keadaan terbaru dari GitHub
```

Menampilkan: commit lokal vs GitHub, log trigger terakhir, status tiap task
pipeline beserta durasinya, image yang sedang jalan, kesiapan pod, respons HTTP
aplikasi, dan satu baris kesimpulan.

---

## Alur lengkap satu siklus

```powershell
# 1. Ubah kode, uji lokal
docker run --rm -v "D:\MY-Project\go-project:/src" -w /src golang:1.27-alpine sh -c "go test ./..."
cd ui; npm test; cd ..

# 2. Commit + push (pipeline baca dari GitHub!)
git add -A
git commit -m "perubahan X"
git push origin main

# 3. Jalankan pipeline
kubectl create -f tekton\pipelinerun.yaml

# 4. Pantau
tkn pipelinerun logs -n cicd --last -f

# 5. Verifikasi
kubectl get pipelinerun -n cicd
kubectl get deploy -n dev -o custom-columns='NAME:.metadata.name,IMAGE:.spec.template.spec.containers[0].image'
curl.exe http://localhost:8090/api/health
```

---

## Perbedaan PowerShell vs Bash

Dokumentasi Kubernetes di internet umumnya memakai bash. Padanannya:

| Bash | PowerShell |
|---|---|
| `grep pola` | `Select-String pola` |
| `head -5` | `Select-Object -First 5` |
| `tail -5` | `Select-Object -Last 5` |
| `cat file` | `Get-Content file` |
| `export A=b` | `$env:A = "b"` |
| `\` di akhir baris | `` ` `` (backtick) |
| `$(cmd)` | `$(cmd)` (sama) |
| `cmd1 && cmd2` | `cmd1; if ($?) { cmd2 }` |
| `2>/dev/null` | `2>$null` |
| `/dev/null` | `$null` atau `NUL` |

Anda juga bisa memakai **Git Bash** (ikut terpasang bersama Git for Windows) kalau ingin menyalin perintah bash apa adanya. Project ini menyediakan `tekton/setup.sh` untuk itu.

Lanjut ke [Bab 7 — Latihan](07-latihan.md).
