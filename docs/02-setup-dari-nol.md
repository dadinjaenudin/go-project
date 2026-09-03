# Bab 2 — Setup dari Nol

Bab ini membawa Anda dari komputer kosong sampai aplikasi jalan lewat pipeline. Kerjakan berurutan, dan **jangan lompat** — tiap langkah punya cara verifikasi supaya Anda tahu pasti sudah benar sebelum lanjut.

---

## Langkah 0 — Prasyarat

### 0.1 Docker Desktop

Unduh dari <https://www.docker.com/products/docker-desktop>. Setelah terpasang:

```powershell
docker --version
# Docker version 29.6.1, build 8900f1d
```

### 0.2 Aktifkan Kubernetes di Docker Desktop

Ini yang sering terlewat pemula. Kubernetes **tidak** aktif secara default.

1. Buka Docker Desktop
2. Klik ikon roda gigi (**Settings**)
3. Pilih **Kubernetes** di menu kiri
4. Centang **Enable Kubernetes**
5. **Apply & Restart** — proses ini butuh 5-10 menit saat pertama kali

Verifikasi:

```powershell
kubectl cluster-info
# Kubernetes control plane is running at https://127.0.0.1:xxxxx

kubectl get nodes
# NAME                    STATUS   ROLES           AGE   VERSION
# desktop-control-plane   Ready    control-plane   1h    v1.36.1
```

> Kalau nama node-nya `desktop-control-plane`, berarti benar Docker Desktop. Kalau `minikube`, Anda sedang memakai cluster lain — perhatikan catatan Docker Desktop di dokumen ini tidak berlaku.

Pastikan juga context-nya benar:

```powershell
kubectl config current-context
# docker-desktop
```

Kalau bukan `docker-desktop`:

```powershell
kubectl config use-context docker-desktop
```

### 0.3 Pasang Tekton Pipelines

Tekton tidak bawaan; harus dipasang ke cluster.

```powershell
kubectl apply -f https://storage.googleapis.com/tekton-releases/pipeline/latest/release.yaml
```

Tunggu semua pod siap (butuh 1-3 menit):

```powershell
kubectl get pods -n tekton-pipelines
```

Semua harus `Running`. Kalau masih `ContainerCreating`, tunggu saja.

Verifikasi CRD-nya masuk:

```powershell
kubectl get crd | Select-String tekton
# pipelineruns.tekton.dev
# pipelines.tekton.dev
# taskruns.tekton.dev
# tasks.tekton.dev
```

**CRD** (Custom Resource Definition) adalah cara Tekton menambahkan jenis objek baru ke Kubernetes. Setelah CRD terpasang, `kubectl` mengerti kata `Task` dan `Pipeline`.

### 0.4 Pasang Tekton CLI (`tkn`)

Opsional tapi sangat membantu — membaca log jadi jauh lebih mudah.

```powershell
choco install tektoncd-cli        # kalau punya Chocolatey
# atau unduh .zip dari https://github.com/tektoncd/cli/releases
```

```powershell
tkn version
# Client version: 0.46.0
# Pipeline version: v1.6.0
```

Kalau baris `Pipeline version` muncul, artinya `tkn` berhasil terhubung ke cluster.

### 0.5 Tekton Dashboard (opsional, sangat disarankan untuk pemula)

Tampilan web untuk melihat pipeline berjalan — jauh lebih mudah dipahami daripada membaca log mentah.

```powershell
kubectl apply -f https://storage.googleapis.com/tekton-releases/dashboard/latest/release.yaml
kubectl port-forward -n tekton-pipelines svc/tekton-dashboard 9097:9097
```

Buka <http://localhost:9097>. Biarkan jendela PowerShell itu terbuka selama Anda ingin memakai dashboard.

---

## Langkah 1 — Siapkan akun Docker Hub

### 1.1 Buat akun dan token

1. Daftar di <https://hub.docker.com>
2. **Account Settings** -> **Personal access tokens** -> **Generate new token**
3. Beri nama (mis. `tekton-local`), permission **Read, Write, Delete**
4. Salin token (`dckr_pat_...`) — hanya muncul sekali

### 1.2 Simpan token dengan aman

Buat file `secret.md` di root project, isinya **hanya token itu saja**, satu baris:

```
dckr_pat_<TEMPEL-TOKEN-ANDA-DI-SINI>
```

> Perhatikan placeholder di atas sengaja memakai tanda `<...>`. Contoh palsu yang
> formatnya terlalu mirip token asli (mis. `dckr_pat_` diikuti 27 huruf) akan
> diblokir GitHub Push Protection walaupun isinya bukan token sungguhan.
> Lihat bab 5 kasus #11.

Lalu **pastikan** file itu diabaikan Git:

```powershell
Get-Content .gitignore | Select-String secret
# secret.md

git check-ignore -v secret.md
# .gitignore:2:secret.md  secret.md
```

> Kalau perintah `git check-ignore` tidak mengeluarkan apa-apa, berarti file itu **belum** diabaikan dan berisiko ikut ter-commit. Jangan lanjut sebelum ini beres.

### 1.3 Uji token benar-benar bekerja

Ini penting dilakukan **sekarang**, bukan nanti setelah pipeline berjalan 3 menit lalu gagal di langkah terakhir:

```powershell
Get-Content secret.md | docker login -u dadin --password-stdin
# Login Succeeded
```

Ganti `dadin` dengan username Docker Hub Anda.

> **Username Docker Hub bisa berbeda dengan username GitHub.** Kalau `Login Succeeded` tidak muncul, username-nya salah. Perbaiki dulu, dan sesuaikan juga nama image di `tekton/pipelinerun.yaml`.

---

## Langkah 2 — Siapkan kode

### 2.1 Ambil kode

```powershell
git clone https://github.com/dadinjaenudin/go-project.git
cd go-project
```

### 2.2 Pahami: pipeline mengambil kode dari GitHub, bukan dari folder Anda

Ini **konsep paling sering disalahpahami pemula**.

```
Folder di laptop Anda          GitHub                   Pipeline Tekton
D:\MY-Project\go-project  -->  github.com/...  -->      git clone
                          push                  ambil dari sini
```

Task `git-clone` menarik kode dari **GitHub**. Perubahan yang belum di-`push` **tidak terlihat** oleh pipeline.

Artinya, setiap kali Anda mengubah kode aplikasi:

```powershell
git add -A
git commit -m "pesan perubahan"
git push origin main        # <- TANPA INI, PIPELINE PAKAI KODE LAMA
```

> Pengecualian: file di `tekton/` diterapkan langsung ke cluster dengan `kubectl apply`, jadi perubahan Task/Pipeline berlaku begitu di-apply — tidak perlu push. Tapi tetap di-commit supaya repo konsisten.

### 2.3 Uji dulu di lokal sebelum masuk pipeline

Kebiasaan bagus: pastikan test lulus di laptop dulu. Kalau gagal di sini, pasti gagal juga di pipeline — dan mencari tahunya jauh lebih cepat di lokal.

```powershell
# Test backend (Go tidak perlu terpasang, pakai container)
docker run --rm -v "D:\MY-Project\go-project:/src" -w /src golang:1.27-alpine `
  sh -c "go vet ./... && go test ./... -v"

# Test frontend
cd ui
npm install
npm test
cd ..
```

Hasil yang benar:

```
ok      go-project      0.017s
Test Files  1 passed (1)
     Tests  13 passed (13)
```

---

## Langkah 3 — Bootstrap cluster

Sekarang pasang semua yang dibutuhkan pipeline ke Kubernetes.

### 3.1 Jalankan script setup

```powershell
powershell -ExecutionPolicy Bypass -File tekton\setup.ps1
```

Script ini melakukan lima hal:

| # | Yang dilakukan | Objek yang dibuat |
|---|---|---|
| 1 | Membuat namespace | `cicd`, `dev` |
| 2 | Membaca `secret.md`, membuat Secret Docker Hub | `dockerhub-secret` di `cicd` |
| 3 | Menerapkan RBAC | ServiceAccount + Role + RoleBinding |
| 4 | Menerapkan 6 Task | `git-clone`, `backend-test`, ... |
| 5 | Menerapkan Pipeline | `employee-ci-cd` |

### 3.2 Verifikasi tiap bagian

Jangan percaya begitu saja — periksa satu per satu:

```powershell
# Namespace ada?
kubectl get ns cicd dev

# Secret terbuat, tipenya benar?
kubectl get secret -n cicd
# NAME               TYPE                             DATA   AGE
# dockerhub-secret   kubernetes.io/dockerconfigjson   1      1m

# Semua Task terpasang? Harus ada 6.
kubectl get tasks -n cicd

# Pipeline terpasang?
kubectl get pipeline -n cicd

# RBAC benar? Yang pertama harus "yes", yang kedua harus "no".
kubectl auth can-i create deployments.apps -n dev --as=system:serviceaccount:cicd:tekton-deployer
kubectl auth can-i create deployments.apps -n default --as=system:serviceaccount:cicd:tekton-deployer
```

> Kalau tipe Secret bukan `kubernetes.io/dockerconfigjson`, Kaniko tidak akan bisa memakainya. Tipe ini yang membuat token dibungkus jadi format `config.json` yang dimengerti Docker.

---

## Langkah 4 — Jalankan pipeline

```powershell
kubectl create -f tekton\pipelinerun.yaml
# pipelinerun.tekton.dev/employee-ci-cd-2ccdv created
```

Catat nama yang muncul (`employee-ci-cd-2ccdv`) — itu ID run Anda.

### 4.1 Pantau jalannya

Tiga cara, pilih yang nyaman:

```powershell
# Cara 1 - paling informatif
tkn pipelinerun logs -n cicd --last -f

# Cara 2 - ringkas, lihat status tiap task
kubectl get taskrun -n cicd

# Cara 3 - Tekton Dashboard di browser
# http://localhost:9097
```

### 4.2 Yang seharusnya Anda lihat

Urutan status yang normal (total sekitar 2,5-3 menit):

```
[ 20s] clone=Pending
[ 40s] clone=Succeeded  backend-test=Running  frontend-test=Running
[ 60s] backend-test=Succeeded  frontend-test=Succeeded
       backend-build=Running   frontend-build=Running
[120s] backend-build=Succeeded frontend-build=Succeeded  deploy=Pending
[140s] deploy=Running
[160s] deploy=Succeeded   -> SELESAI
```

Perhatikan `backend-test` dan `frontend-test` **jalan bersamaan** — itu efek `runAfter` yang sama.

### 4.3 Pastikan berhasil

```powershell
kubectl get pipelinerun -n cicd
# NAME                   SUCCEEDED   REASON      STARTTIME   COMPLETIONTIME
# employee-ci-cd-2ccdv   True        Succeeded   2m38s       12s
```

Kolom `SUCCEEDED` harus `True`.

---

## Langkah 5 — Verifikasi hasilnya

Jangan berhenti di "pipeline hijau". Periksa hasilnya benar-benar ada.

### 5.1 Image sudah masuk Docker Hub?

Buka <https://hub.docker.com/repositories> — harus ada `go-backend` dan `go-frontend`, masing-masing dengan tag SHA commit dan `latest`.

Cara membuktikan lebih kuat, hapus salinan lokal lalu tarik ulang dari registry:

```powershell
docker rmi dadin/go-backend:32b21ca
docker pull dadin/go-backend:32b21ca
# docker.io/dadin/go-backend:32b21ca
```

Kalau berhasil ditarik setelah dihapus, berarti benar-benar ada di Docker Hub, bukan cuma cache lokal.

### 5.2 Aplikasi jalan di Kubernetes?

```powershell
kubectl get pods -n dev
# employee-backend-76b7bb7996-z5s9n    1/1     Running
# employee-frontend-7bc4d4f5c6-hrz7j   1/1     Running
```

`1/1` artinya 1 container siap dari 1 container. Kalau `0/1`, container jalan tapi readinessProbe belum lulus — tunggu sebentar atau cek log.

### 5.3 Image yang jalan benar dari pipeline?

Ini pemeriksaan yang sering dilewatkan, padahal penting:

```powershell
kubectl get deploy -n dev -o custom-columns='DEPLOYMENT:.metadata.name,IMAGE:.spec.template.spec.containers[0].image'
# DEPLOYMENT          IMAGE
# employee-backend    dadin/go-backend:32b21ca
# employee-frontend   dadin/go-frontend:32b21ca
```

Tag-nya harus **SHA commit**. Kalau masih `:latest` atau tag lama, berarti langkah deploy tidak benar-benar mengganti apa pun.

### 5.4 Aplikasinya bisa dibuka?

```powershell
kubectl get svc -n dev
# employee-frontend   LoadBalancer   10.96.216.180   172.80.11.5   8090:30080/TCP
```

Buka <http://localhost:8090>. Harus muncul tabel 50 karyawan.

Uji juga API-nya:

```powershell
curl.exe http://localhost:8090/api/health
# {"status":"OK"}
```

> **Kenapa `localhost:8090` dan bukan `localhost:30080`?** Karena Service-nya bertipe `LoadBalancer` dengan `port: 8090`. Di Docker Desktop, NodePort (30080) **tidak** diteruskan ke Windows. Lihat bab 5 kasus #6.

---

## Langkah 6 — Siklus kerja sehari-hari

Setelah semuanya jalan, alur kerja normalnya jadi pendek:

```powershell
# 1. Ubah kode
code main.go

# 2. Uji di lokal dulu
docker run --rm -v "D:\MY-Project\go-project:/src" -w /src golang:1.27-alpine sh -c "go test ./..."

# 3. Commit + push (WAJIB, pipeline baca dari GitHub)
git add -A
git commit -m "perbaiki perhitungan gaji"
git push origin main

# 4. Jalankan pipeline
kubectl create -f tekton\pipelinerun.yaml

# 5. Pantau
tkn pipelinerun logs -n cicd --last -f

# 6. Cek hasil
kubectl get deploy -n dev -o custom-columns='NAME:.metadata.name,IMAGE:.spec.template.spec.containers[0].image'
```

Karena tag image memakai SHA commit, tiap `git push` menghasilkan tag baru, dan Kubernetes pasti melakukan rolling update.

---

## Membersihkan

Kalau ingin mengulang dari awal:

```powershell
# Hapus aplikasi saja
kubectl delete -f k8s\ -n dev

# Hapus semua run pipeline (definisinya tetap ada)
kubectl delete pipelinerun --all -n cicd

# Hapus semuanya, termasuk namespace
kubectl delete namespace cicd dev
```

> `kubectl delete namespace` menghapus **semua** isinya. Pastikan tidak ada hal lain di namespace itu.

Lanjut ke [Bab 3 — Anatomi File](03-anatomi-file.md).
