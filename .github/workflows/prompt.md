# Spesifikasi CI — `.github/workflows/workflow.yml`

Dokumen ini adalah sumber kebenaran untuk workflow GitHub Actions di folder ini.
Kalau `workflow.yml` perlu diubah, ubah spesifikasi di sini dulu supaya alasan tiap
langkah tidak hilang.

## Tujuan

Memberi umpan balik cepat pada setiap push/PR ke `main` **tanpa menyentuh cluster
dan tanpa butuh satu pun secret**. Deployment tetap urusan pipeline Tekton
(`pipeline.yaml`) yang berjalan di Minikube namespace `cicd`.

Pembagian tanggung jawab:

| Tahap | GitHub Actions | Tekton |
|---|---|---|
| Test & vet Go | ya | ya (`backend-test.yaml`) |
| Build Vue | ya | lewat Dockerfile |
| Build image Docker | ya, validasi saja | ya (Kaniko) |
| Push ke Docker Hub | **tidak** | ya |
| Apply manifest k8s | **tidak** | ya (`deploy.yaml`) |

## Trigger

`push` ke `main`, `pull_request` ke `main`, dan `workflow_dispatch` manual.
Run lama pada ref yang sama dibatalkan (`concurrency` + `cancel-in-progress`)
supaya push beruntun tidak menumpuk antrean.

Permission dikunci ke `contents: read` — workflow ini tidak menulis apa pun
ke repo maupun ke registry.

## Job

### 1. `backend` — Go

Cermin dari task Tekton `backend-test.yaml`, supaya kegagalan tertangkap di PR
bukan di tengah pipeline deploy:

- versi Go dibaca dari `go.mod` (`go-version-file`), jangan di-hardcode — saat ini
  `1.27.0` dan harus tetap seiring dengan image `golang:1.27-alpine` di `Dockerfile-go`
- `go mod download` → `go vet ./...` → `go test ./...`
- build binary dengan `CGO_ENABLED=0 GOOS=linux GOARCH=amd64`, sama persis dengan
  flag di `Dockerfile-go`, supaya error khusus cross-compile ketahuan lebih awal

Catatan: repo belum punya file `_test.go` sama sekali, jadi `go test` saat ini lolos
kosong. Begitu test pertama ditulis, job ini langsung berguna tanpa perlu diubah.

### 2. `frontend` — Vue

- Node 22, menyamai `node:22-alpine` di kedua Dockerfile
- `npm ci` (bukan `npm install`) supaya `package-lock.json` yang dipakai apa adanya;
  lockfile v3 dan sudah memuat axios, jadi trik `npm install axios` terpisah di
  Dockerfile tidak diperlukan di sini
- `npm run build`, lalu `ui/dist` diunggah sebagai artifact (retensi 7 hari) untuk
  memudahkan inspeksi hasil build dari PR

Sengaja **tidak** memanggil `npm test`: `ui/package.json` belum punya script `test`,
jadi perintah itu pasti gagal. Task Tekton `frontend-test.yaml` memanggilnya, tapi task
tersebut memang tidak dirangkai di `pipeline.yaml` sehingga tidak pernah jalan.
Kalau nanti test frontend ditambahkan, tambahkan script `test` di `package.json`,
lalu sisipkan langkahnya di sini sebelum `npm run build`.

### 3. `docker` — validasi image

Jalan setelah `backend` dan `frontend` hijau. Build kedua image dengan
`docker build`, **tanpa push**, murni untuk memastikan Dockerfile tidak rusak:

- `Dockerfile-go` dengan context root
- `ui/Dockerfile-vue` dengan context `ui`

Tidak ada login registry, jadi job ini aman dijalankan dari PR fork.

### 4. `manifests` — non-blocking

Membaca semua path `k8s/...` yang di-apply `deploy.yaml`, lalu memastikan tiap file
benar-benar ada. Diberi `continue-on-error: true` supaya statusnya jadi peringatan,
bukan penghalang merge.

Job ini saat ini **memang gagal**, dan itu disengaja — ia menangkap bug nyata:

```
OK      k8s/backend_deployment.yml
MISSING k8s/backend-hpa.yml       -> yang ada k8s/backend-hpa.yaml
MISSING k8s/backend-service.yml   -> yang ada k8s/backend-service.yaml
OK      k8s/frontend_deployment.yml
MISSING k8s/frontend-service.yml  -> hanya ada di root repo
```

Begitu `deploy.yaml` atau nama file di `k8s/` diselaraskan, job ini hijau dan
`continue-on-error` boleh dihapus supaya jadi blocking.

## Batasan yang harus dijaga

- Jangan menambahkan langkah yang butuh secret (`DOCKERHUB_*`, `KUBECONFIG`,
  `ANTHROPIC_API_KEY`, dsb.) tanpa persetujuan pemilik repo — nilai utama CI ini
  adalah bisa jalan di PR fork tanpa kredensial.
- Jangan menduplikasi logika deploy dari `deploy.yaml` ke sini; kalau keduanya
  divergen, cluster akan mengikuti Tekton dan CI akan berbohong.
- Versi toolchain hanya boleh ditulis di satu tempat: Go dari `go.mod`, Node
  disamakan manual dengan tag image di Dockerfile.
