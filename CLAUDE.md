# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Ringkasan

Aplikasi "Data Master Karyawan": backend Go (Echo v4) membaca satu file CSV dan mengeksposnya sebagai JSON, frontend Vue 3 menampilkannya sebagai tabel dengan search, filter gender, dan ringkasan statistik. Tidak ada database — `data/data_master_karyawan.csv` dibaca ulang dari disk setiap kali `/api/data` dipanggil. Endpoint hanya `/api/data` dan `/api/health`.

Deployment-nya **dua image terpisah**: backend Go, dan frontend Vue yang di-build statis lalu disajikan nginx. nginx yang mem-proxy `/api/` ke Service backend.

## Perintah

```bash
# Backend — listen di :8888 (butuh Go 1.27; tidak terpasang di mesin ini, pakai Docker)
go run main.go
go vet ./...
go test ./... -v

# Tanpa Go lokal — jalankan di container yang sama dengan Tekton:
docker run --rm -v "D:\MY-Project\go-project:/src" -w /src golang:1.27-alpine \
  sh -c "go vet ./... && go test ./... -count=1"

# Frontend — dari folder ui/
npm install
npm run dev            # Vite dev server :5173, mem-proxy /api ke :8888
npm test               # vitest run
npm run test:watch
npm run build          # -> ui/dist

# Image
docker build -f Dockerfile-go -t dadin/go-backend:v1 .
docker build -f ui/Dockerfile -t dadin/go-frontend:v1 ui    # context-nya ui/, bukan root
```

Development normal: `go run main.go` + `npm run dev`, lalu buka **:5173**.

## Arsitektur

```
data/data_master_karyawan.csv
  → readCSV() di main.go — tiap baris jadi map[string]string berkunci header CSV
  → GET /api/data mengembalikan {"data": [...]}
  → ui/src/components/myComponent.vue merender lewat nama kolom literal
```

Kunci map berasal langsung dari baris header CSV (`NP`, `Nama`, `Unit Kerja`, `Jabatan`, `Gaji`, `Umur`, `Jenis Kelamin`), dan template Vue mengaksesnya dengan nama persis itu (`employee["Unit Kerja"]`). **Mengubah nama header CSV akan mengosongkan kolom di frontend tanpa error di mana pun.** `TestReadCSVDataAsli` di `main_test.go` menjaga ini — test itu gagal kalau ada kolom yang hilang.

**Seluruh logika frontend ada di satu file:** `ui/src/components/myComponent.vue` (465 baris — template, Options-API `setup()`, dan `<style>`). `App.vue` hanya me-render komponen itu, dan masih meng-import `HelloWorld.vue` (sisa scaffold Vite) tanpa memakainya.

**Frontend memanggil `/api/data` relatif, bukan URL absolut.** Yang menyambungkannya ke backend berbeda per lingkungan:

| Lingkungan | Penyambung |
|---|---|
| `npm run dev` | proxy di `ui/vite.config.js` → `localhost:8888` |
| Kubernetes | `ui/nginx.conf` → `proxy_pass http://employee-backend:8888` |

Jangan kembalikan ke `http://localhost:8888/...` — itu memutus deployment dan membuat CORS jadi syarat.

## CI/CD (Tekton)

Semua di `tekton/`. Resource pipeline hidup di namespace **`cicd`**, aplikasi dideploy ke namespace **`dev`**.

```
clone → (backend-test ‖ frontend-test) → (backend-build ‖ frontend-build) → deploy
```

Kedua build sengaja menunggu **kedua** test hijau, supaya image tidak terlanjur ter-push saat satu sisi gagal.

```powershell
# Windows / PowerShell
powershell -ExecutionPolicy Bypass -File tekton\setup.ps1
kubectl create -f tekton\pipelinerun.yaml   # create, bukan apply — pakai generateName
tkn pipelinerun logs -n cicd --last -f
```

```bash
# Git Bash — sama persis, hanya beda script
bash tekton/setup.sh
kubectl create -f tekton/pipelinerun.yaml
```

Aplikasi terbuka di **<http://localhost:8090>**.

### Lingkungan: Docker Desktop di Windows, bukan Minikube

Cluster-nya Kubernetes bawaan **Docker Desktop** — context `docker-desktop`, node tunggal `desktop-control-plane`, berjalan di WSL2. Perintah `minikube ...` tidak berlaku di sini.

- **NodePort tidak bisa diakses dari Windows.** `http://localhost:30080` ditolak (connection refused). Yang diteruskan Docker Desktop ke host hanyalah Service bertipe **LoadBalancer**, lewat proses `com.docker.backend` + `wslrelay`. Karena itu `k8s/frontend-service.yaml` bertipe `LoadBalancer` di port **8090**, bukan NodePort. Jangan diubah ke NodePort kalau targetnya tetap Docker Desktop.
- **Mengubah `port` pada Service LoadBalancer yang sudah ada tidak mem-bind ulang listener di host.** Service-nya harus dihapus dulu: `kubectl delete svc -n dev employee-frontend` lalu `kubectl apply -f k8s/frontend-service.yaml`. Tanpa itu port lama tetap mati dan port baru tidak pernah terbuka.
- **Docker Desktop berbagi image store dengan cluster.** Image hasil `docker build` di Windows langsung terlihat oleh kubelet, jadi manifest bisa diuji tanpa push ke Docker Hub sama sekali — cukup `kubectl set image` ke tag lokal. Berguna untuk memisahkan masalah manifest dari masalah registry.
- Storage class default `standard` (rancher.io/local-path, `WaitForFirstConsumer`). PVC `ReadWriteOnce` 5Gi dari `volumeClaimTemplate` di PipelineRun jalan normal di node tunggal.

Hal yang perlu diketahui:

- **Tag image adalah SHA commit, bukan tag statis.** Ini disengaja: dengan tag tetap seperti `v1`, `kubectl set image` menulis nilai yang identik dengan yang sudah terpasang, Deployment tidak berubah, rollout tidak pernah jalan, dan pipeline **melaporkan sukses sambil tetap menjalankan kode lama**. Task `git-clone` mengeluarkan result `commit-short` yang dipakai kedua build dan task deploy.
- **`secret.md` berisi Docker Hub access token dan ada di `.gitignore`. Jangan pernah menyalin isinya ke file lain.** `tekton/setup.sh` membacanya dan membuat Secret `dockerhub-secret` di namespace `cicd`; rotasi token cukup dengan mengubah `secret.md` lalu menjalankan ulang script itu.
- **RBAC-nya Role namespaced, bukan ClusterRole.** ServiceAccount `tekton-deployer` ada di `cicd`, Role + RoleBinding-nya di `dev`. Verifikasi setelah mengubah: `kubectl auth can-i create deployments.apps -n dev --as=system:serviceaccount:cicd:tekton-deployer` harus `yes`, dan `-n default` harus `no`.
- **Task deploy meng-apply backend lebih dulu.** nginx me-resolve `employee-backend` saat load config, jadi Service backend harus sudah ada sebelum pod frontend start. Jangan tukar urutannya di `tekton/task-deploy.yaml`.
- **Tag image di `k8s/*-deployment.yaml` hanya placeholder** (`:latest`); tag sebenarnya dipasang task deploy lewat `kubectl set image`.
- **CSV dibakar ke dalam image backend** (`COPY data ./data`). Tidak ada ConfigMap — kalau CSV berubah, image harus di-build ulang.
- `git-clone` ditulis sendiri di `tekton/task-git-clone.yaml` supaya repo tidak bergantung pada Tekton Hub.

## Yang perlu diperhatikan

- **CSV asli diawali UTF-8 BOM.** `encoding/csv` tidak membuangnya, jadi `readCSV()` mem-`TrimPrefix` `\ufeff` dari header pertama secara eksplisit. Tanpa itu kunci kolom pertama jadi `"\ufeffNP"` dan `employee.NP` di frontend bernilai `undefined`. Jangan hapus baris itu — dan **jangan tulis karakter BOM literal di source Go**, kompilernya menolak dengan `illegal byte order mark`; pakai escape `\ufeff`.
- **`prompt.md` adalah catatan permintaan, bukan dokumentasi.** Isinya menyebut frontend "next.js" padahal frontend repo ini Vue. Blok pertamanya (GitHub Actions) belum dikerjakan; blok keduanya (Tekton) sudah.
- **Branch `fix/ci-manifest-paths` menyimpan setup CI/CD versi lama** (namespace `cicd` untuk segalanya, image `aripribadi010187/*`, frontend berupa container Vite dev server, plus workflow GitHub Actions). Sudah digantikan `tekton/` di `main`; berguna hanya sebagai rujukan.
