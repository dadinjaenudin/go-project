# Bab 7 — Latihan

Membaca saja tidak cukup. Kerjakan latihan ini berurutan — tiap latihan membangun pemahaman untuk latihan berikutnya.

Format tiap latihan: **tujuan -> langkah -> yang harus Anda amati -> jawaban**.

---

## Latihan 1 — Buktikan pipeline membaca dari GitHub, bukan folder Anda

**Tujuan:** memahami kesalahpahaman paling umum bagi pemula.

### Langkah

1. Ubah judul aplikasi di `ui/src/components/myComponent.vue`:

   ```html
   <h1>Data Master Karyawan v2</h1>
   ```

2. **Jangan** di-commit. Langsung jalankan pipeline:

   ```powershell
   kubectl create -f tekton\pipelinerun.yaml
   tkn pipelinerun logs -n cicd --last -f
   ```

3. Setelah selesai, buka <http://localhost:8090>

### Yang harus Anda amati

Judulnya **tidak berubah**. Pipeline sukses, tapi perubahan Anda tidak ikut.

4. Sekarang commit dan push, lalu jalankan lagi:

   ```powershell
   git add -A
   git commit -m "judul v2"
   git push origin main
   kubectl create -f tekton\pipelinerun.yaml
   ```

Sekarang judulnya berubah.

### Jawaban

Task `git-clone` menjalankan `git clone` dari URL GitHub. Folder lokal Anda tidak pernah dibaca sama sekali. Buktinya ada di log task clone:

```
Cloning into '.'...
Checked out main @ <sha>
```

SHA itu adalah commit terakhir di **GitHub**, bukan di laptop Anda.

---

## Latihan 2 — Lihat rolling update terjadi

**Tujuan:** memahami cara Kubernetes mengganti versi tanpa downtime.

### Langkah

Buka **dua** jendela PowerShell.

Jendela 1 — pantau pod:

```powershell
kubectl get pods -n dev -w
```

Jendela 2 — ganti image ke versi lama:

```powershell
# Lihat tag apa saja yang ada
kubectl get deploy -n dev -o custom-columns='NAME:.metadata.name,IMAGE:.spec.template.spec.containers[0].image'

# Ganti ke latest
kubectl set image -n dev deployment/employee-backend backend=dadin/go-backend:latest
```

### Yang harus Anda amati

Di jendela 1:

```
employee-backend-xxx   0/1   Pending       # pod BARU dibuat dulu
employee-backend-xxx   0/1   ContainerCreating
employee-backend-xxx   1/1   Running       # baru siap
employee-backend-yyy   1/1   Terminating   # pod LAMA baru dimatikan
```

### Pertanyaan

Kenapa pod lama tidak dimatikan lebih dulu?

### Jawaban

Supaya tidak ada waktu kosong tanpa pod yang melayani. Kubernetes menunggu **readinessProbe** pod baru lulus sebelum mematikan yang lama. Coba hapus `readinessProbe` dari deployment, lalu ulangi — Anda akan melihat pod lama mati lebih cepat, dan sempat ada jeda saat aplikasi tidak bisa diakses.

---

## Latihan 3 — Bikin test gagal dengan sengaja

**Tujuan:** membuktikan pipeline benar-benar menghentikan build yang rusak.

### Langkah

1. Rusak sebuah test di `main_test.go`:

   ```go
   if len(rows) != 2 {        // ubah 2 menjadi 99
   ```

2. Commit, push, jalankan pipeline.

### Yang harus Anda amati

```powershell
kubectl get taskrun -n cicd
# backend-test     False   Failed
# frontend-test    True    Succeeded
# backend-build    (tidak pernah muncul)
# frontend-build   (tidak pernah muncul)
# deploy           (tidak pernah muncul)
```

### Pertanyaan

Kenapa `frontend-build` juga tidak jalan, padahal test frontend hijau?

### Jawaban

Karena di `pipeline.yaml`:

```yaml
- name: frontend-build
  runAfter: [backend-test, frontend-test]     # menunggu KEDUANYA
```

Ini disengaja. Kalau `frontend-build` hanya menunggu `frontend-test`, image frontend akan ter-push ke Docker Hub padahal backend-nya rusak — registry jadi berisi versi yang tidak pernah lolos test.

**Jangan lupa kembalikan** angkanya ke `2` dan push lagi.

---

## Latihan 4 — Buktikan RBAC benar-benar membatasi

**Tujuan:** memahami least privilege.

### Langkah

```powershell
$SA = "system:serviceaccount:cicd:tekton-deployer"

kubectl auth can-i create deployments.apps -n dev         --as=$SA
kubectl auth can-i create deployments.apps -n default     --as=$SA
kubectl auth can-i create deployments.apps -n kube-system --as=$SA
kubectl auth can-i delete namespaces                      --as=$SA
kubectl auth can-i --list -n dev --as=$SA
```

### Yang harus Anda amati

```
yes    <- dev
no     <- default
no     <- kube-system
no     <- namespaces
```

### Latihan lanjutan

Coba jalankan deploy ke namespace `default`:

```powershell
kubectl create ns coba
kubectl apply -f tekton\pipelinerun.yaml    # setelah mengubah deploy-namespace ke "coba"
```

Task deploy akan gagal dengan pesan `forbidden`. Untuk membuatnya jalan, Anda harus menambah `Role` + `RoleBinding` baru di namespace `coba`.

### Jawaban

Izin di Kubernetes tidak diwariskan antar-namespace. Satu `RoleBinding` hanya berlaku di namespace tempat ia dibuat. Kalau ingin izin di semua namespace, harus pakai `ClusterRole` + `ClusterRoleBinding` — tapi itu memberi kuasa jauh lebih besar dan sebaiknya dihindari.

---

## Latihan 5 — Tambah satu Task baru ke pipeline

**Tujuan:** benar-benar memahami hubungan Task, Pipeline, dan `runAfter`.

Buat task yang memeriksa ukuran image tidak melebihi batas.

### Langkah

1. Buat `tekton/task-lint.yaml`:

   ```yaml
   apiVersion: tekton.dev/v1
   kind: Task
   metadata:
     name: lint-check
     namespace: cicd
   spec:
     workspaces:
       - name: source
     steps:
       - name: cek-file-wajib
         image: alpine:3.22
         workingDir: $(workspaces.source.path)
         script: |
           #!/bin/sh
           set -eu
           for f in Dockerfile-go ui/Dockerfile ui/nginx.conf; do
             if [ ! -f "$f" ]; then
               echo "GAGAL: $f tidak ada"
               exit 1
             fi
             echo "OK: $f"
           done
   ```

2. Pasang:

   ```powershell
   kubectl apply -f tekton\task-lint.yaml
   ```

3. Tambahkan ke `tekton/pipeline.yaml`, di bagian `tasks:`:

   ```yaml
   - name: lint
     runAfter: [clone]
     taskRef:
       name: lint-check
     workspaces:
       - name: source
         workspace: shared-workspace
   ```

4. Buat kedua build menunggu lint juga:

   ```yaml
   - name: backend-build
     runAfter: [backend-test, frontend-test, lint]
   ```

5. Terapkan dan jalankan:

   ```powershell
   kubectl apply -f tekton\pipeline.yaml
   kubectl create -f tekton\pipelinerun.yaml
   ```

### Yang harus Anda amati

`lint` berjalan **bersamaan** dengan kedua test, karena `runAfter`-nya sama-sama `[clone]`.

### Latihan lanjutan

Ubah `runAfter: [clone]` menjadi `runAfter: [backend-test]` lalu jalankan lagi. Perhatikan `lint` sekarang menunggu, tidak lagi paralel — dan pipeline jadi lebih lambat.

---

## Latihan 6 — Reproduksi bug tag statis

**Tujuan:** merasakan sendiri kasus #4 di bab 5, bug paling berbahaya karena tidak memunculkan error.

### Langkah

1. Ubah `tekton/pipeline.yaml`, ganti tag SHA jadi tetap:

   ```yaml
   - name: TAG
     value: "v1"                # bukan $(tasks.clone.results.commit-short)
   ```

   (ganti di **tiga** tempat: backend-build, frontend-build, deploy)

2. Terapkan dan jalankan sekali. Catat waktu pod:

   ```powershell
   kubectl apply -f tekton\pipeline.yaml
   kubectl create -f tekton\pipelinerun.yaml
   kubectl get pods -n dev
   ```

3. Ubah sesuatu yang terlihat di `myComponent.vue`, commit, push, jalankan pipeline lagi.

4. Periksa:

   ```powershell
   kubectl get pods -n dev        # perhatikan kolom AGE
   ```

### Yang harus Anda amati

Pipeline **sukses**, tapi `AGE` pod tidak reset — pod lama masih jalan, dan perubahan Anda tidak muncul di browser.

### Jawaban

`kubectl set image` menulis `dadin/go-backend:v1`, nilai yang sudah terpasang. Karena tidak ada perubahan pada spesifikasi Deployment, Kubernetes tidak melakukan apa pun.

**Kembalikan** ke `$(tasks.clone.results.commit-short)` setelah selesai.

---

## Latihan 7 — Buktikan proxy nginx bekerja

**Tujuan:** memahami kenapa frontend memakai path relatif.

### Langkah

```powershell
# 1. Dari luar - lewat LoadBalancer, masuk ke nginx, diteruskan ke backend
curl.exe http://localhost:8090/api/health

# 2. Dari dalam cluster - langsung ke backend, tanpa nginx
kubectl run smoke --rm -i --restart=Never -n dev --image=curlimages/curl:8.11.1 -- `
  curl -s http://employee-backend:8888/api/health

# 3. Dari dalam cluster - lewat frontend
kubectl run smoke --rm -i --restart=Never -n dev --image=curlimages/curl:8.11.1 -- `
  curl -s http://employee-frontend:8090/api/health
```

Ketiganya harus menjawab `{"status":"OK"}`.

### Percobaan yang menggagalkan

Ubah `myComponent.vue` kembali ke URL absolut:

```js
const response = await axios.get("http://localhost:8888/api/data");
```

Commit, push, jalankan pipeline, lalu buka <http://localhost:8090>.

### Yang harus Anda amati

Tabelnya kosong dengan pesan "Gagal mengambil data". Buka DevTools browser (F12) -> tab Network — ada permintaan gagal ke `localhost:8888`.

### Jawaban

`localhost` di kode frontend artinya **komputer pengguna**, bukan server. Tidak ada apa pun di port 8888 laptop Anda. Dengan path relatif `/api/data`, browser memanggil host yang sama dengan halaman (`localhost:8090`), lalu nginx yang meneruskannya ke Service backend di dalam cluster.

**Kembalikan** ke `/api/data`.

---

## Latihan 8 — Rollback

**Tujuan:** tahu cara kembali ke versi sebelumnya saat deploy bermasalah.

### Langkah

```powershell
# Lihat riwayat
kubectl rollout history -n dev deployment/employee-backend

# Kembali satu versi
kubectl rollout undo -n dev deployment/employee-backend

# Kembali ke revisi tertentu
kubectl rollout undo -n dev deployment/employee-backend --to-revision=2

# Pastikan selesai
kubectl rollout status -n dev deployment/employee-backend

# Cek image sekarang apa
kubectl get deploy -n dev -o custom-columns='NAME:.metadata.name,IMAGE:.spec.template.spec.containers[0].image'
```

### Pertanyaan

Kenapa rollback bisa cepat sekali?

### Jawaban

Kubernetes menyimpan ReplicaSet lama (default 10 revisi terakhir). Rollback hanya berarti menaikkan kembali jumlah replica ReplicaSet lama dan menurunkan yang baru — image-nya bahkan masih ada di node, jadi tidak perlu menarik ulang.

```powershell
kubectl get rs -n dev
# ReplicaSet lama masih ada dengan DESIRED=0
```

Ini juga alasan lain kenapa tag SHA lebih baik dari `latest`: dengan `latest`, ReplicaSet lama menunjuk tag yang isinya sudah berubah, sehingga rollback belum tentu mengembalikan kode yang sama.

---

## Latihan 9 — Baca log seperti seorang engineer

**Tujuan:** melatih diagnosa mandiri.

### Langkah

Rusak sesuatu dengan sengaja, lalu cari penyebabnya **tanpa** melihat bab 5.

Pilih salah satu:

| Kerusakan | Cara |
|---|---|
| A | Ubah image di `task-deploy.yaml` menjadi `alpine/k8s:9.9.9` |
| B | Hapus `--dockerfile` dari args di `task-backend-build.yaml` |
| C | Ubah `secretName` di task build menjadi `salah-nama` |
| D | Ubah `readinessProbe` path menjadi `/tidak-ada` |

Untuk tiap kerusakan, jawab:

1. Task mana yang gagal?
2. Apa pesan error persisnya?
3. Perintah mana yang paling cepat menunjukkan penyebabnya?
4. Bagaimana memperbaikinya?

### Urutan diagnosa yang disarankan

```powershell
kubectl get pipelinerun -n cicd                             # 1. run gagal?
kubectl get taskrun -n cicd                                 # 2. task mana?
kubectl describe taskrun -n cicd <nama>                     # 3. kenapa?
tkn taskrun logs -n cicd <nama>                             # 4. detail
kubectl get events -n cicd --sort-by=.lastTimestamp         # 5. kalau pod tak mulai
```

### Kunci jawaban

- **A** -> `deploy` gagal `ErrImagePull ... not found`. Terlihat di `kubectl get events`. Kasus #8.
- **B** -> `backend-build` gagal, Kaniko mencari `Dockerfile` (nama default) yang tidak ada di repo ini. Terlihat di log task.
- **C** -> pod build macet di `ContainerCreating`. `kubectl describe pod` menyebut `secret "salah-nama" not found`. Ini kasus di mana log **kosong** — karena container belum pernah jalan, jadi `describe` satu-satunya sumber.
- **D** -> pipeline gagal di `rollout status` setelah timeout 300 detik. Pod `0/1 Running` selamanya. `kubectl describe pod` menampilkan `Readiness probe failed: HTTP probe failed with statuscode: 404`.

Kasus **C** dan **D** adalah pelajaran terpenting di sini: **kalau log kosong, pakai `describe`.** Log hanya ada kalau container sudah sempat berjalan.

---

## Latihan 10 — Bangun ulang dari nol

**Tujuan:** memastikan Anda benar-benar bisa mandiri.

### Langkah

```powershell
# Hancurkan semuanya
kubectl delete namespace cicd dev

# Bangun ulang tanpa melihat dokumentasi
```

Anda dianggap lulus kalau bisa menyebutkan urutannya sendiri:

1. Buat namespace `cicd` dan `dev`
2. Buat Secret Docker Hub dari `secret.md`
3. Terapkan RBAC
4. Terapkan 6 Task
5. Terapkan Pipeline
6. `kubectl create` PipelineRun
7. Verifikasi: pipelinerun `True`, pod `1/1`, image bertag SHA, `localhost:8090` menjawab

Langkah 1-5 itulah persis isi `tekton/setup.ps1`. Buka file itu dan bandingkan dengan urutan yang Anda tulis sendiri.

---

## Setelah ini

Kalau kesepuluh latihan sudah selesai, Anda sudah menguasai dasar yang cukup. Arah lanjutan yang masuk akal:

| Topik | Kenapa berguna | Mulai dari |
|---|---|---|
| **Tekton Triggers** | pipeline jalan otomatis saat `git push`, tanpa `kubectl create` manual | `EventListener`, `TriggerBinding`, `TriggerTemplate` |
| **Helm** | mengelola manifest dengan template dan nilai per-environment | `helm create` |
| **Ingress** | satu pintu masuk untuk banyak aplikasi, dengan domain dan TLS | ingress-nginx |
| **ConfigMap & Secret** | konfigurasi terpisah dari image | ubah CSV jadi ConfigMap |
| **HPA** | menambah pod otomatis saat beban naik | `kubectl autoscale` |
| **Multi-environment** | namespace `dev`, `staging`, `prod` dengan pipeline sama | parameter `deploy-namespace` sudah ada di pipeline ini |

Latihan pertama yang bagus untuk melanjutkan: buat pipeline ini men-deploy ke namespace `staging` selain `dev`, dengan memanfaatkan parameter `deploy-namespace` yang sudah tersedia. Anda perlu menambah `Role` + `RoleBinding` baru di namespace itu — pengetahuan dari Latihan 4.
