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

Spesifikasi lengkap beserta alasan tiap langkah ada di `.github/workflows/prompt.md`; ubah dokumen itu lebih dulu kalau workflow-nya diubah. Job `manifests` memverifikasi tiap path `k8s/...` yang di-apply `deploy.yaml` benar-benar ada — kalau merah, step deploy Tekton pasti gagal.

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
- **Semua manifest yang di-apply `deploy.yaml` wajib ada di `k8s/`.** Dulu task ini merujuk tiga file dengan nama salah (`.yml` vs `.yaml`, dan `frontend-service` yang hanya ada di root); sudah diperbaiki dan sekarang dijaga job `manifests` di CI. Saat menambah manifest, taruh di `k8s/` dan pakai nama persis seperti di `deploy.yaml`.
- **Kedua task Kaniko me-mount Secret `dockerhub-secret` sebagai `config.json`.** `backend-build.yaml` dan `frontend-build.yaml` harus identik di blok `volumes` — pernah ada regresi di sini (teks perintah shell tertempel ke nilai `path`) yang membuat push image frontend gagal autentikasi.
- **Tata letak YAML: root hanya untuk Tekton + compose, `k8s/` hanya untuk manifest aplikasi.** Salinan manifest yang dulu menganggur di root sudah dihapus; jangan hidupkan lagi — `deploy.yaml` hanya membaca `k8s/`, sehingga salinan root pasti divergen tanpa ketahuan.
- **Dua definisi RBAC yang tumpang tindih:** `rbac.yaml` (ClusterRole) dan `deploy-rbac.yml` (Role namespaced), keduanya membuat ServiceAccount `tekton-deployer` yang sama. Pilih salah satu; `pipelinerun.yaml` hanya butuh SA tersebut ada.
- **`backend_deployment.yml` me-mount ConfigMap `employee-data` ke `/app/data`,** tapi tidak ada manifest yang membuatnya. Buat manual: `kubectl create configmap employee-data --from-file=data/data_master_karyawan.csv -n cicd`, kalau tidak pod backend tidak akan start.
- File kosong/artefak yang bisa diabaikan: `a`, `pipeline.yml`, `tasks.yml` (semua 0 byte), dan `main.exe` (binary hasil build yang ikut ter-commit).
