# Bab 4 — Alur Pipeline Detik per Detik

Bab ini mengikuti satu eksekusi pipeline dari awal sampai akhir. Angka waktunya diambil dari run nyata (`employee-ci-cd-2ccdv`, total 2 menit 38 detik).

---

## Sebelum apa pun terjadi

Anda menjalankan:

```powershell
kubectl create -f tekton\pipelinerun.yaml
```

Yang terjadi: Kubernetes membuat satu objek `PipelineRun` bernama `employee-ci-cd-2ccdv`. Controller Tekton yang sedang berjalan di namespace `tekton-pipelines` melihat objek baru itu, membaca `pipelineRef: employee-ci-cd`, lalu mulai menjalankan Task sesuai urutan `runAfter`.

Sebelum Task pertama jalan, Tekton menyiapkan **workspace**: sebuah PersistentVolumeClaim 5 GB dibuat dari `volumeClaimTemplate`. Disk inilah yang nanti dipakai bersama semua Task.

---

## Detik 0-40 — Task `clone`

**Pod:** `employee-ci-cd-2ccdv-clone-pod`
**Image:** `alpine/git:2.49.1`

Status pertama yang Anda lihat adalah `Pending` — pod sedang menunggu image ditarik dan volume dipasang.

Yang dijalankan:

```sh
rm -rf ./* ./.[!.]* 2>/dev/null || true
git clone --depth 1 --branch main https://github.com/dadinjaenudin/go-project.git .
git rev-parse HEAD           | tr -d '\n' > /tekton/results/commit
git rev-parse --short=7 HEAD | tr -d '\n' > /tekton/results/commit-short
```

Output di log:

```
Cloning into '.'...
Checked out main @ 32b21ca
```

Setelah selesai, workspace berisi seluruh isi repo, dan dua **result** tersimpan:

| Result | Nilai |
|---|---|
| `commit` | `32b21ca5b150a7e9ba33610388eda725bc476ce8` |
| `commit-short` | `32b21ca` |

> **Di sinilah pipeline pernah gagal.** Saat baris penulisan `commit-short` belum ada, Task ini tetap `Succeeded` — tapi result-nya cuma satu. Task berikutnya yang memakai `$(tasks.clone.results.commit-short)` langsung ditolak dengan `PipelineValidationFailed`. Lihat bab 5 kasus #1.

Cara memeriksa result yang benar-benar dihasilkan:

```powershell
kubectl get taskrun -n cicd employee-ci-cd-2ccdv-clone -o jsonpath='{.status.results}'
```

---

## Detik 40-60 — `backend-test` dan `frontend-test` (bersamaan)

Dua pod berjalan **serentak** karena `runAfter`-nya sama-sama `[clone]`.

### Pod 1: `backend-test` (`golang:1.27-alpine`)

```sh
go mod download
go vet ./...
go test ./... -v -count=1
```

Output:

```
=== RUN   TestReadCSVMemetakanHeaderKeKolom
--- PASS: TestReadCSVMemetakanHeaderKeKolom (0.00s)
=== RUN   TestReadCSVMembuangBOMDariHeaderPertama
--- PASS: TestReadCSVMembuangBOMDariHeaderPertama (0.00s)
...
PASS
ok      go-project      0.017s
```

`-count=1` mematikan cache test Go. Tanpa itu, Go bisa melaporkan hasil lama tanpa benar-benar menjalankan test.

`go vet` adalah static analysis — menangkap kesalahan yang lolos dari compiler, misalnya format string yang tidak cocok dengan argumennya.

### Pod 2: `frontend-test` (`node:22-alpine`)

```sh
npm ci --no-audit --no-fund
npm test                      # vitest run
npm run build
```

Output:

```
Test Files  1 passed (1)
     Tests  13 passed (13)
```

Perhatikan `npm run build` ikut dijalankan di sini, bukan cuma test. Tujuannya: kalau ada error yang hanya muncul saat build produksi (misalnya import yang salah), ketahuan **sebelum** masuk tahap build image yang lebih lambat.

> **Kenapa dua image berbeda?** Karena Tekton membolehkan tiap Step memakai image sendiri. Tidak perlu satu server yang punya Go dan Node sekaligus — masalah klasik pada CI model lama.

---

## Detik 60-120 — `backend-build` dan `frontend-build` (bersamaan)

Keduanya `runAfter: [backend-test, frontend-test]`, jadi baru mulai setelah **kedua** test hijau.

**Image:** `gcr.io/kaniko-project/executor:v1.23.2`

### Apa yang Kaniko lakukan

1. Membaca `Dockerfile-go` dari workspace
2. Menarik base image (`golang:1.27-alpine`, `alpine:3.22`)
3. Menjalankan tiap instruksi Dockerfile, membuat *snapshot* filesystem tiap layer
4. Menyusun image final
5. Push ke Docker Hub memakai kredensial dari `/kaniko/.docker/config.json`

Potongan log yang khas:

```
INFO[0000] Retrieving image manifest golang:1.27-alpine
INFO[0012] Building stage 'golang:1.27-alpine' [idx: '0']
INFO[0035] RUN go mod download
INFO[0058] Taking snapshot of full filesystem...
INFO[0069] Pushing image to docker.io/dadin/go-backend:32b21ca
INFO[0079] Pushing image to docker.io/dadin/go-backend:latest
```

Perhatikan tag-nya: **`32b21ca`** — nilai yang datang dari result `commit-short` milik Task `clone`. Inilah rantai yang menghubungkan commit Git ke image yang jalan di production.

Tiap build menghasilkan **digest**, yaitu sidik jari isi image:

```powershell
kubectl get taskrun -n cicd -l tekton.dev/pipelineTask=backend-build -o jsonpath='{.items[0].status.results[0].value}'
# sha256:485a2bf419bc218908e3024cee3e8e5c70b3bb1454fcd0b00e44d2cd0adc39c2
```

Tag bisa dipindah-pindah, digest tidak pernah. Kalau dua image punya digest sama, isinya benar-benar identik.

---

## Detik 120-160 — Task `deploy`

**Image:** `alpine/k8s:1.36.1`
**ServiceAccount:** `tekton-deployer` (dari `taskRunTemplate` di PipelineRun)

Ini satu-satunya Task yang berbicara ke Kubernetes API, dan satu-satunya yang butuh RBAC.

```sh
kubectl apply -n dev -f k8s/backend-deployment.yaml
kubectl apply -n dev -f k8s/backend-service.yaml
kubectl apply -n dev -f k8s/frontend-deployment.yaml
kubectl apply -n dev -f k8s/frontend-service.yaml

kubectl set image -n dev deployment/employee-backend  backend=dadin/go-backend:32b21ca
kubectl set image -n dev deployment/employee-frontend frontend=dadin/go-frontend:32b21ca

kubectl rollout status -n dev deployment/employee-backend  --timeout=300s
kubectl rollout status -n dev deployment/employee-frontend --timeout=300s
```

### Apa yang terjadi di dalam Kubernetes saat `set image`

1. Deployment `employee-backend` berubah (image `:latest` -> `:32b21ca`)
2. Karena template pod berubah, Deployment membuat **ReplicaSet baru**
3. ReplicaSet baru membuat pod baru
4. Pod baru menarik image `dadin/go-backend:32b21ca` dari Docker Hub
5. Kubernetes menunggu **readinessProbe** (`GET /api/health`) berhasil
6. Setelah pod baru siap, pod lama masuk status `Terminating`
7. `rollout status` baru selesai di titik ini

Anda bisa melihatnya berlangsung:

```powershell
kubectl get pods -n dev -w
# employee-frontend-7bc4d4f5c6-hrz7j   1/1   Running       # baru
# employee-frontend-bf87bfb97-7tjw9    1/1   Terminating   # lama
```

Inilah **rolling update** — aplikasi tidak pernah mati sepenuhnya.

> **Kenapa tag SHA penting di sini.** Kalau tag-nya tetap (`v1`), langkah 1 tidak terjadi: `set image` menulis nilai yang sama persis dengan yang sudah terpasang, Deployment tidak berubah, tidak ada pod baru, dan `rollout status` langsung sukses. Pipeline hijau, tapi kode lama tetap jalan. Lihat bab 5 kasus #4.

---

## Detik 160 — Selesai

```powershell
kubectl get pipelinerun -n cicd
# NAME                   SUCCEEDED   REASON      STARTTIME   COMPLETIONTIME
# employee-ci-cd-2ccdv   True        Succeeded   2m38s       12s
```

Sekarang aplikasinya hidup di <http://localhost:8090>.

---

## Ringkasan waktu

| Task | Durasi | Image |
|---|---|---|
| `clone` | ~20 dtk | `alpine/git:2.49.1` |
| `backend-test` | ~20 dtk | `golang:1.27-alpine` |
| `frontend-test` | ~25 dtk | `node:22-alpine` |
| `backend-build` | ~60 dtk | Kaniko |
| `frontend-build` | ~60 dtk | Kaniko |
| `deploy` | ~30 dtk | `alpine/k8s:1.36.1` |
| **Total** | **~2 mnt 40 dtk** | (karena ada yang paralel) |

Run pertama biasanya lebih lama karena semua base image harus ditarik dulu.

---

## Melihat sendiri isi tiap tahap

```powershell
# Semua TaskRun dari run terakhir
kubectl get taskrun -n cicd

# Log satu task tertentu
tkn taskrun logs -n cicd employee-ci-cd-2ccdv-backend-build -f

# Semua log pipeline
tkn pipelinerun logs -n cicd --last -f

# Result yang dihasilkan sebuah task
kubectl get taskrun -n cicd employee-ci-cd-2ccdv-clone -o jsonpath='{.status.results}'

# Urutan lengkap + status
kubectl describe pipelinerun -n cicd employee-ci-cd-2ccdv
```

Lanjut ke [Bab 5 — Troubleshooting](05-troubleshooting.md).
