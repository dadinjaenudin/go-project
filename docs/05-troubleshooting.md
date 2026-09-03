# Bab 5 — Troubleshooting

Semua kasus di bab ini **benar-benar terjadi** saat pipeline ini dibangun. Bukan contoh karangan. Pesan error-nya disalin apa adanya.

Belajar membaca error jauh lebih berguna daripada menghafal solusi, jadi tiap kasus ditulis dengan urutan: **gejala -> cara mendiagnosa -> penyebab -> perbaikan**.

---

## Metode umum: dari mana mulai mencari

Saat sesuatu gagal, telusuri dari luar ke dalam:

```powershell
# 1. Lapisan pipeline - task mana yang merah?
kubectl get pipelinerun -n cicd
kubectl get taskrun -n cicd

# 2. Lapisan task - kenapa merah?
kubectl describe taskrun -n cicd <nama-taskrun>
tkn taskrun logs -n cicd <nama-taskrun>

# 3. Lapisan pod - kalau task bahkan tidak mulai
kubectl get events -n cicd --sort-by=.lastTimestamp | Select-Object -Last 20

# 4. Lapisan aplikasi - kalau pipeline hijau tapi aplikasi tidak jalan
kubectl get pods -n dev
kubectl describe pod -n dev <nama-pod>
kubectl logs -n dev <nama-pod>
```

Aturan praktis: **bagian `Events` pada `kubectl describe` hampir selalu menyebut penyebab sebenarnya.**

---

## Kasus #1 — `PipelineValidationFailed`

### Gejala

```
NAME                   SUCCEEDED   REASON
employee-ci-cd-qp9f7   False       PipelineValidationFailed
```

Anehnya, tiga task justru **berhasil**:

```
employee-ci-cd-qp9f7-clone           True   Succeeded
employee-ci-cd-qp9f7-backend-test    True   Succeeded
employee-ci-cd-qp9f7-frontend-test   True   Succeeded
```

Task build tidak pernah muncul sama sekali. Docker Hub tetap kosong.

### Cara mendiagnosa

```powershell
kubectl describe pipelinerun -n cicd employee-ci-cd-qp9f7
# Tasks Completed: 3 (Failed: 0), Skipped: 1, Failed Validation: 2
```

`Failed Validation: 2` -> dua task ditolak sebelum jalan. Karena yang memakai nilai dari task lain hanyalah task build, periksa result-nya:

```powershell
kubectl get taskrun -n cicd employee-ci-cd-qp9f7-clone -o jsonpath='{.status.results}'
# [{"name":"commit","type":"string","value":"32b21ca5b1..."}]
```

Hanya ada `commit`. **`commit-short` tidak ada**, padahal pipeline memakainya.

### Penyebab

Di `task-git-clone.yaml`, result `commit-short` **dideklarasikan** tapi script **tidak pernah menulisnya**:

```yaml
results:
  - name: commit
  - name: commit-short          # dideklarasikan...

steps:
  - script: |
      git rev-parse HEAD | tr -d '\n' > "$(results.commit.path)"
      # ...tapi tidak ada baris yang menulis commit-short
```

Task `clone` tetap sukses (Tekton tidak mewajibkan semua result terisi), tapi `$(tasks.clone.results.commit-short)` di pipeline tidak bisa di-resolve.

### Perbaikan

```yaml
git rev-parse --short=7 HEAD | tr -d '\n' > "$(results.commit-short.path)"
```

### Pencegahan

Setiap result butuh **tiga** bagian: dideklarasikan, ditulis, dipakai. Cek cepat:

```powershell
# Result yang dideklarasikan
Select-String "- name: commit" tekton\task-git-clone.yaml

# Result yang benar-benar ditulis
Select-String "results\..*\.path" tekton\task-git-clone.yaml
```

Jumlah keduanya harus cocok.

---

## Kasus #2 — `401 Unauthorized` pada cache Kaniko

### Gejala

Di log task build, berulang kali:

```
WARN Error uploading layer to cache: failed to push to destination
index.docker.io/dadin/go-frontend/cache:5ddb08ca...: unexpected status code 401 Unauthorized
```

### Cara mendiagnosa

Perhatikan alamat tujuannya: `dadin/go-frontend/**cache**`. Itu **repository yang berbeda** dari `dadin/go-frontend`, dengan nama bersarang.

### Penyebab

`--cache=true` membuat Kaniko menyimpan layer hasil build ke repository terpisah. Docker Hub **tidak mendukung nama repository bersarang** seperti `user/repo/cache`, jadi selalu ditolak 401.

Ini hanya `WARN`, tidak menggagalkan build — tapi setiap layer dicoba dan gagal, sehingga build jadi lebih lambat dan log penuh sampah.

### Perbaikan

Buang saja cache-nya, karena memang tidak pernah bekerja:

```yaml
args:
  # - --cache=true          <- dihapus
  # - --cache-ttl=24h       <- dihapus
  - --push-retry=3
```

Kalau Anda memang ingin cache, arahkan ke repository yang sudah dibuat manual:

```yaml
- --cache=true
- --cache-repo=docker.io/dadin/build-cache
```

---

## Kasus #3 — `tls: bad record MAC` saat push

### Gejala

Backend berhasil di-push, frontend gagal di detik terakhir:

```
INFO Pushing image to docker.io/dadin/go-frontend:32b21ca
error pushing image: failed to push to destination docker.io/dadin/go-frontend:32b21ca:
Get "https://auth.docker.io/token?scope=...": remote error: tls: bad record MAC
```

### Cara mendiagnosa

Kunci pembedanya: **backend berhasil dengan kredensial yang sama persis**. Kalau ini masalah izin, keduanya akan gagal.

`bad record MAC` adalah error lapisan TLS — paket data rusak di tengah jalan. Ini masalah **jaringan**, bukan konfigurasi.

### Penyebab

Koneksi terputus/rusak saat mengunggah. Umum terjadi pada jaringan WSL2, terutama saat mengunggah layer besar.

### Perbaikan

Suruh Kaniko mencoba ulang:

```yaml
args:
  - --push-retry=3
```

> Pelajaran umum: **error transien terlihat seperti error konfigurasi.** Sebelum membongkar konfigurasi, tanyakan dulu — apakah gagalnya konsisten? Coba jalankan ulang. Kalau kadang berhasil kadang tidak, itu masalah jaringan atau race condition, bukan salah ketik.

---

## Kasus #4 — Pipeline hijau tapi kode lama tetap jalan

### Gejala

Ini yang **paling berbahaya**, karena tidak ada error sama sekali. Pipeline sukses, `rollout status` sukses, tapi aplikasi tetap menjalankan versi lama.

### Cara mendiagnosa

```powershell
kubectl get deploy -n dev -o custom-columns='NAME:.metadata.name,IMAGE:.spec.template.spec.containers[0].image'
# employee-backend    dadin/go-backend:v1     <- sama seperti kemarin

kubectl get rs -n dev
# tidak ada ReplicaSet baru

kubectl get pods -n dev
# AGE pod-nya masih lama, tidak baru dibuat
```

### Penyebab

Dengan tag tetap seperti `v1`:

```
kubectl set image ... backend=dadin/go-backend:v1
```

Nilainya **sama persis** dengan yang sudah terpasang. Kubernetes bersifat deklaratif — kalau keadaan yang diinginkan tidak berubah, tidak ada yang dikerjakan. Tidak ada ReplicaSet baru, tidak ada pod baru, dan `rollout status` langsung selesai karena rollout sebelumnya memang sudah beres.

Ditambah `imagePullPolicy: IfNotPresent`, image `:v1` yang lama sudah ada di node dan tidak pernah ditarik ulang.

### Perbaikan

Pakai tag unik per commit:

```yaml
- name: TAG
  value: $(tasks.clone.results.commit-short)     # mis. 32b21ca
```

Tiap commit menghasilkan tag berbeda -> `set image` benar-benar mengubah Deployment -> rolling update pasti terjadi.

Alternatif lain: pakai digest image (`image@sha256:...`), atau `kubectl rollout restart` setelah `set image`.

---

## Kasus #5 — `unknown field "metadata.imagePullSecrets"`

### Gejala

```
Error from server (BadRequest): error when creating "tekton/rbac.yml":
ServiceAccount in version "v1" cannot be handled as a ServiceAccount:
strict decoding error: unknown field "metadata.imagePullSecrets"
```

### Penyebab

Salah menempatkan field. Pada ServiceAccount, `imagePullSecrets` adalah field **tingkat atas**, bukan di dalam `metadata`:

```yaml
# SALAH
metadata:
  name: tekton-deployer
  imagePullSecrets:
    - name: dockerhub-secret

# BENAR
metadata:
  name: tekton-deployer
imagePullSecrets:
  - name: dockerhub-secret
```

### Cara menemukannya lebih awal

Kesalahan ini ditemukan oleh validasi server **sebelum** pipeline pernah dijalankan:

```powershell
kubectl apply --dry-run=server -f tekton\rbac.yml
```

> **Biasakan `--dry-run=server` untuk setiap YAML baru.** Ini memvalidasi ke API server sungguhan (mengerti CRD Tekton juga) tanpa menyimpan apa pun. `--dry-run=client` lebih lemah — hanya cek format YAML, tidak cek nama field.

Catatan: di project ini `imagePullSecrets` akhirnya dihapus sama sekali, karena pod aplikasi berjalan di namespace `dev` sementara ServiceAccount ada di `cicd` — jadi field itu memang tidak berguna di sana.

---

## Kasus #6 — NodePort tidak bisa diakses di Docker Desktop

### Gejala

```powershell
kubectl get svc -n dev
# employee-frontend   NodePort   10.96.52.196   <none>   80:30080/TCP

curl.exe http://localhost:30080/
# (gagal, connection refused)
```

Padahal dari **dalam** cluster semuanya normal:

```powershell
kubectl run smoke --rm -i --restart=Never -n dev --image=curlimages/curl -- `
  curl -s -o /dev/null -w "%{http_code}" http://employee-frontend/
# 200
```

### Cara mendiagnosa

Kalau dari dalam cluster jalan tapi dari luar tidak, masalahnya bukan aplikasi maupun Service — melainkan **cara cluster mengekspos port ke host**.

### Penyebab

Kubernetes bawaan Docker Desktop (node `desktop-control-plane`) **tidak** meneruskan NodePort ke `localhost` Windows. Yang diteruskan hanyalah Service bertipe `LoadBalancer`, lewat proses `com.docker.backend` dan `wslrelay`.

Banyak tutorial memakai Minikube, di mana NodePort dapat diakses lewat `minikube service` atau IP node. Di Docker Desktop caranya berbeda.

### Perbaikan

```yaml
spec:
  type: LoadBalancer      # bukan NodePort
  ports:
    - port: 8090
```

Verifikasi Docker Desktop benar-benar mem-bind port-nya:

```powershell
netstat -ano | Select-String ":8090"
# TCP 0.0.0.0:8090   LISTENING   <pid com.docker.backend>
# TCP 127.0.0.1:8090 LISTENING   <pid wslrelay>
```

Alternatif yang selalu bekerja di cluster mana pun:

```powershell
kubectl port-forward -n dev svc/employee-frontend 8090:8090
```

---

## Kasus #7 — Port LoadBalancer diubah tapi tidak berubah

### Gejala

Service diubah dari `port: 80` ke `port: 8090`. Setelah itu, **kedua** port mati — 80 tidak lagi menjawab, dan 8090 tidak pernah terbuka.

### Cara mendiagnosa

```powershell
netstat -ano | Select-String ":8090"
# (kosong - tidak ada yang listen)
```

Objek Service-nya sendiri terlihat benar:

```powershell
kubectl get svc -n dev employee-frontend
# employee-frontend   LoadBalancer   10.96.52.196   172.80.11.5   8090:30080/TCP
```

Jadi Kubernetes sudah benar, tapi Docker Desktop belum mengikuti.

### Penyebab

Integrasi LoadBalancer Docker Desktop tidak mem-bind ulang listener di host saat nomor port pada Service yang sudah ada diubah.

### Perbaikan

Hapus lalu buat ulang Service-nya:

```powershell
kubectl delete svc -n dev employee-frontend
kubectl apply -f k8s\frontend-service.yaml
```

Setelah itu:

```
TCP 0.0.0.0:8090   LISTENING   39272   (com.docker.backend)
TCP 127.0.0.1:8090 LISTENING   23128   (wslrelay)
```

---

## Kasus #8 — `not found` pada image task

### Gejala

```
Back-off pulling image "bitnami/kubectl:1.34": ErrImagePull:
failed to resolve reference "docker.io/bitnami/kubectl:1.34": not found
```

Task `deploy` berstatus `TaskRunImagePullFailed`, padahal semua task sebelumnya sukses.

### Cara mendiagnosa

```powershell
docker manifest inspect bitnami/kubectl:1.34
# no such manifest
```

### Penyebab

Tag itu tidak ada. Nama repository benar, tapi versinya tidak pernah dipublikasikan.

### Perbaikan

Cek dulu tag yang tersedia sebelum memakainya:

```powershell
foreach ($img in "bitnami/kubectl:latest", "alpine/k8s:1.36.1", "registry.k8s.io/kubectl:v1.36.1") {
  $ok = docker manifest inspect $img 2>$null
  "{0,-34} {1}" -f $img, $(if ($ok) { "TERSEDIA" } else { "tidak ada" })
}
```

Dua pertimbangan saat memilih penggantinya:

1. **Versi kubectl harus dekat dengan versi server.** kubectl hanya didukung dalam selisih satu versi minor. Server di sini v1.36.1, jadi dipilih `alpine/k8s:1.36.1`.
2. **Butuh shell.** Image kubectl resmi `registry.k8s.io/kubectl` bersifat *distroless* — tidak punya `sh` maupun `bash`, sehingga blok `script:` Tekton tidak bisa berjalan di sana.

```powershell
# Cek image punya shell atau tidak
docker run --rm --entrypoint sh alpine/k8s:1.36.1 -c "echo ada shell; kubectl version --client"
```

---

## Kasus #9 — `illegal byte order mark` saat compile Go

### Gejala

```
main_test.go:53:33: illegal byte order mark
```

### Penyebab

File `.go` mengandung karakter BOM (U+FEFF) di tengah file — dalam kasus ini di dalam string literal yang sengaja dipakai untuk menguji penanganan BOM. Compiler Go menolaknya.

### Perbaikan

Pakai escape, bukan karakter aslinya:

```go
// SALAH - karakter BOM asli, tak terlihat di editor
headers[0] = strings.TrimPrefix(headers[0], "<karakter BOM asli, tak terlihat>")

// BENAR
headers[0] = strings.TrimPrefix(headers[0], "\ufeff")
```

Selain lolos compile, versi escape juga lebih baik karena **terlihat**. Karakter tak kasat mata di source code adalah sumber bug yang sangat sulit ditemukan — editor bisa menghapusnya diam-diam saat menyimpan.

Cara memeriksa file mengandung BOM:

```powershell
Format-Hex data\data_master_karyawan.csv | Select-Object -First 1
# EF BB BF di awal = ada BOM
```

---

## Kasus #10 — `ErrImageNeverPull` yang hilang sendiri

### Gejala

```
Warning  ErrImageNeverPull  48s (x2)  Container image "dadin/go-frontend:local"
                                      is not present with pull policy of Never
Normal   Pulled             33s       Container image "dadin/go-frontend:local"
                                      already present on machine
```

Error lalu sukses, tanpa ada yang diubah.

### Penyebab

Race condition: pod dijadwalkan sebelum image selesai terdaftar di penyimpanan image node.

### Pelajaran

Sebelum mengejar sebuah error, **lihat dulu stempel waktunya**. Error 48 detik lalu yang disusul sukses 33 detik lalu bukan masalah aktif. Membaca `Events` dari bawah ke atas (paling baru dulu) menghemat banyak waktu.

```powershell
kubectl get events -n dev --sort-by=.lastTimestamp | Select-Object -Last 15
```

---

## Kasus #11 — `GH013: Push cannot contain secrets`

### Gejala

```
remote: error: GH013: Repository rule violations found for refs/heads/main.
remote: - GITHUB PUSH PROTECTION
remote:     - Push cannot contain secrets
```

Push ditolak GitHub. Yang membingungkan: `secret.md` sudah di `.gitignore` dan
tidak pernah di-commit.

### Cara mendiagnosa

Periksa isi commit yang hendak dikirim, bukan working tree:

```powershell
git diff origin/main..HEAD > $env:TEMP\d.patch
Select-String -Path $env:TEMP\d.patch -Pattern "dckr_pat_[A-Za-z0-9_-]{20,}"
Select-String -Path $env:TEMP\d.patch -Pattern "gh[pousr]_[A-Za-z0-9]{30,}"
Select-String -Path $env:TEMP\d.patch -Pattern "AKIA[0-9A-Z]{16}"
```

Pastikan juga file rahasia memang tidak pernah masuk riwayat:

```powershell
git log --all --oneline -- secret.md
# kosong = aman
```

### Penyebab

**Placeholder di dokumentasi yang formatnya terlalu mirip token asli.** Yang
memicunya adalah baris berisi awalan `dckr_pat_` diikuti langsung oleh 27 huruf
`x` tanpa pemisah apa pun.

(Contoh persisnya sengaja tidak ditulis utuh di sini — menuliskannya akan
memblokir push dokumen ini sendiri. Itu benar-benar terjadi saat bab ini dibuat.)

Pemindai GitHub mencocokkan pola `dckr_pat_` + sederet karakter. Ia tidak tahu
isinya cuma huruf x berulang, jadi tetap diblokir.

### Perbaikan

Buat placeholder yang mustahil disalahartikan — tanda `<`/`>` langsung memutus
pola karena bukan karakter yang sah dalam token:

```
dckr_pat_<TEMPEL-TOKEN-ANDA-DI-SINI>
```

Lalu — **ini bagian yang sering keliru** — memperbaiki file saja tidak cukup.
Push Protection memindai **semua commit dalam push**, jadi commit lama yang
memuat teks itu harus ditulis ulang:

```powershell
# Catat dulu, untuk jaring pengaman
git log --oneline origin/main..HEAD

# Kembalikan HEAD tanpa menyentuh file sama sekali
git reset --soft origin/main

# Commit ulang dengan isi yang sudah bersih
git add -A
git commit -m "pesan"
git push origin main
```

`git reset --soft` **tidak mengubah satu pun file** — hanya memundurkan penunjuk
commit. Commit lama pun masih bisa dipulihkan lewat `git reflog`.

### Kalau yang terdeteksi memang token asli

Jangan pakai tombol "allow secret" dari GitHub. Urutan yang benar:

1. **Cabut token itu sekarang** di Docker Hub / GitHub / penyedia terkait —
   anggap sudah bocor sejak ia tertulis ke disk
2. Terbitkan token baru
3. Bersihkan riwayat commit
4. Baru push

Menghapus token di commit berikutnya **tidak** menghilangkannya dari riwayat.

### Pencegahan

Aturan sederhana: **jangan pernah menulis sesuatu yang formatnya seperti
kredensial**, bahkan sebagai contoh. Pakai `<...>` atau potong dengan `...`.

---

## Tabel rujukan cepat

| Pesan error | Kemungkinan penyebab | Lihat |
|---|---|---|
| `PipelineValidationFailed` | result dideklarasikan tapi tak ditulis | #1 |
| `401 Unauthorized` pada `/cache` | `--cache=true` ke repo bersarang | #2 |
| `tls: bad record MAC` | jaringan transien, coba lagi | #3 |
| Pipeline hijau, kode lama jalan | tag image tidak berubah | #4 |
| `unknown field "..."` | salah letak field di YAML | #5 |
| NodePort tidak bisa diakses | Docker Desktop, pakai LoadBalancer | #6 |
| Port LoadBalancer tidak terbuka | perlu delete + apply ulang | #7 |
| `ErrImagePull ... not found` | tag image tidak ada | #8 |
| `illegal byte order mark` | BOM di source Go | #9 |
| `ErrImageNeverPull` lalu sukses | race, abaikan | #10 |
| `GH013: Push cannot contain secrets` | placeholder mirip token di dokumentasi | #11 |
| `forbidden: User ... cannot ...` | RBAC kurang izin | bab 1.3 |
| Pod `0/1 Running` terus | readinessProbe gagal | cek `kubectl logs` |
| `ImagePullBackOff` | image tak ada / repo privat | #8 |

Lanjut ke [Bab 6 — Cheatsheet](06-cheatsheet.md).
