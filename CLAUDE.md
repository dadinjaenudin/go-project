# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Ringkasan

Aplikasi "Data Master Karyawan": backend Go (Echo) yang membaca CSV dan mengeksposnya sebagai JSON, plus frontend Vue 3 (Vite) yang menampilkannya dalam tabel dengan search + filter. Tidak ada database — sumber data satu-satunya adalah `data/data_master_karyawan.csv`, dibaca ulang setiap request ke `/api/data`.

Seluruh sisa repo (Dockerfile, docker-compose, manifest k8s, Task/Pipeline Tekton) adalah pipeline CI/CD ke Minikube namespace `cicd`.

## Perintah

### Development lokal

```bash
# Backend (butuh Go 1.27 sesuai go.mod; saat ini belum terpasang di PATH mesin ini)
go run main.go            # listen di :8888

# Frontend (dari folder ui/)
cd ui && npm install && npm run dev     # Vite dev server di :5173
```

Jalankan keduanya bersamaan untuk development: Vite mem-proxy `/api` ke `localhost:8888` (lihat `ui/vite.config.js`).

### Test

```bash
go test ./...   # belum ada file _test.go sama sekali — selalu lolos kosong
go vet ./...    # dua perintah ini yang dipakai Tekton task backend-test
```

`ui/package.json` tidak punya script `test`, jadi `npm test` gagal. Task `frontend-test.yaml` memanggilnya, tapi task itu **tidak** dirangkai di `pipeline.yaml` sehingga tidak pernah jalan.

### Docker

```bash
docker compose up --build      # backend :8888 + frontend dev server :5173
docker build -f Dockerfile-go -t go-project_backend .
```

### CI GitHub Actions

`.github/workflows/workflow.yml` berjalan pada push/PR ke `main`: `go vet`+`go test`+build binary, `npm ci`+`npm run build`, lalu `docker build` kedua image **tanpa push**. Tidak memakai satu pun secret — push image dan apply manifest tetap tugas Tekton.

Spesifikasi lengkap beserta alasan tiap langkah ada di `.github/workflows/prompt.md`; ubah dokumen itu lebih dulu kalau workflow-nya diubah. Job `manifests` sengaja `continue-on-error` dan saat ini merah — ia mendeteksi nama file yang salah di `deploy.yaml` (lihat bagian bawah).

### Tekton / Kubernetes

Semua resource ada di namespace `cicd`. Urutan apply saat setup dari nol:

```bash
kubectl create namespace cicd
kubectl apply -f rbac.yaml            # ServiceAccount tekton-deployer + ClusterRole
kubectl apply -f workspace.yaml       # PVC shared-workspace
kubectl apply -f backend-test.yaml -f backend-build.yaml -f frontend-build.yaml -f deploy.yaml
kubectl apply -f pipeline.yaml
kubectl create -f pipelinerun.yaml    # create, bukan apply — pakai generateName

tkn pipelinerun logs -n cicd -f       # ikuti log run terakhir
```

Task build butuh Secret `dockerhub-secret` (tipe `kubernetes.io/dockerconfigjson`) di namespace `cicd`; Kaniko push ke Docker Hub `aripribadi010187/go-project_{backend,frontend}`.

## Arsitektur

**Alur data:** CSV → `readCSV()` di `main.go` mengubah tiap baris jadi `map[string]string` berkunci header CSV (`NP`, `Nama`, `Unit Kerja`, `Jabatan`, `Gaji`, `Umur`, `Jenis Kelamin`) → `/api/data` mengembalikan `{"data": [...]}` → `ui/src/components/myComponent.vue` merender langsung dari kunci-kunci itu. **Mengubah header di CSV akan memutus template Vue** karena diakses lewat nama kolom literal (mis. `employee["Unit Kerja"]`). Endpoint lain hanya `/api/health`.

**Semua logika frontend ada di `ui/src/components/myComponent.vue`** (~465 baris: template, Options-API `setup()`, dan style). `App.vue` hanya me-render komponen itu; `HelloWorld.vue` sisa scaffold Vite dan tidak dipakai.

**Dua mode penyajian frontend yang saling bertentangan:**
1. `docker-compose.yml` dan manifest k8s menjalankan frontend sebagai container Vite **dev server** terpisah (`ui/Dockerfile-vue`, port 5173).
2. `Dockerfile-go` (stage 1) mem-build Vue dan menyalin hasilnya ke `./ui/dist` di image backend — tapi `main.go` memanggil `e.Static("/", "ui")`, bukan `"ui/dist"`, jadi build itu tidak pernah tersaji. Kalau ingin single-image deployment, ubah path static ke `ui/dist`.

## Hal yang perlu diketahui sebelum mengubah

- **`myComponent.vue` hardcode `http://localhost:8888/api/data`.** Ini melewati proxy Vite dan pasti gagal di Kubernetes (backend di sana adalah Service ClusterIP `employee-backend:8888`). Pakai path relatif `/api/data` bila menyentuh bagian ini.
- **`deploy.yaml` merujuk nama file yang tidak ada.** Task itu apply `k8s/backend-service.yml`, `k8s/backend-hpa.yml`, dan `k8s/frontend-service.yml`, padahal yang ada `k8s/backend-service.yaml`, `k8s/backend-hpa.yaml`, dan frontend service hanya ada di root sebagai `frontend-service.yml`. Step deploy akan gagal sampai nama/lokasi disamakan.
- **`frontend-build.yaml` baris terakhir korup:** `path: config.jsontkn pipelinerun logs -n cicd -f` — teks perintah shell tidak sengaja tertempel. Seharusnya `path: config.json`, jika tidak mount kredensial Kaniko salah.
- **Manifest k8s terduplikasi persis di root repo** (`backend_deployment.yml`, `backend-hpa.yaml`, `backend-service.yaml`, `frontend_deployment.yml` identik dengan salinannya di `k8s/`). Hanya salinan `k8s/` yang dibaca `deploy.yaml`; edit keduanya atau hapus yang di root agar tidak divergen.
- **Dua definisi RBAC yang tumpang tindih:** `rbac.yaml` (ClusterRole) dan `deploy-rbac.yml` (Role namespaced), keduanya membuat ServiceAccount `tekton-deployer` yang sama. Pilih salah satu; `pipelinerun.yaml` hanya butuh SA tersebut ada.
- **`backend_deployment.yml` me-mount ConfigMap `employee-data` ke `/app/data`,** tapi tidak ada manifest yang membuatnya. Buat manual: `kubectl create configmap employee-data --from-file=data/data_master_karyawan.csv -n cicd`, kalau tidak pod backend tidak akan start.
- File kosong/artefak yang bisa diabaikan: `a`, `pipeline.yml`, `tasks.yml` (semua 0 byte), dan `main.exe` (binary hasil build yang ikut ter-commit).
