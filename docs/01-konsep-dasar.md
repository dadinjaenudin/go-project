# Bab 1 — Konsep Dasar

Sebelum menyentuh perintah apa pun, pahami dulu lima benda ini dan hubungannya.

---

## 1.1 Container dan Image

**Masalah yang dipecahkan:** "di laptop saya jalan, di server tidak."

Penyebabnya biasanya versi yang beda — Go 1.27 di laptop, Go 1.21 di server; atau library yang ada di satu tempat tapi tidak di tempat lain.

**Image** adalah paket berisi *semua* yang dibutuhkan aplikasi: sistem operasi minimal, runtime, library, dan aplikasi Anda sendiri. Sekali dibuat, isinya beku.

**Container** adalah image yang sedang dijalankan.

> Analogi: **image** itu resep + semua bahan yang sudah ditakar dan disegel. **Container** itu masakan yang sedang dimasak dari paket tadi. Dari satu paket bisa dimasak berkali-kali, hasilnya selalu sama.

### Dockerfile — cara membuat image

`Dockerfile` adalah daftar instruksi pembuatan image. Contoh dari project ini (`Dockerfile-go`, disederhanakan):

```dockerfile
FROM golang:1.27-alpine AS builder   # mulai dari image yang sudah ada Go-nya
WORKDIR /app                         # pindah ke folder /app di dalam image
COPY go.mod go.sum ./                # salin file dari komputer ke image
RUN go mod download                  # jalankan perintah saat build
COPY main.go ./
RUN go build -o /out/server main.go  # hasilkan binary

FROM alpine:3.22                     # MULAI IMAGE BARU yang bersih
COPY --from=builder /out/server ./   # ambil binary saja dari tahap sebelumnya
CMD ["./server"]                     # perintah saat container dijalankan
```

Dua hal penting di situ:

**a. Multi-stage build.** Ada dua `FROM`. Tahap pertama punya seluruh compiler Go (~800 MB), tahap kedua hanya menyalin binary hasilnya ke Alpine yang kecil. Hasil akhirnya **29,8 MB** — compiler tidak ikut. Ini praktik standar.

**b. Layer dan cache.** Tiap instruksi membuat satu *layer*. Kalau layer tidak berubah, Docker memakai hasil sebelumnya (cache) dan tidak mengulang. Karena itu `COPY go.mod go.sum` diletakkan **sebelum** `COPY main.go`:

```
COPY go.mod go.sum   <- jarang berubah, cache jarang batal
RUN go mod download  <- lambat, hasilnya di-cache
COPY main.go         <- sering berubah
RUN go build         <- hanya bagian ini yang diulang
```

Kalau urutannya dibalik, setiap kali `main.go` diubah, seluruh dependency di-download ulang. Build jadi lambat berkali-kali lipat.

### Perintah dasar

```powershell
docker build -f Dockerfile-go -t dadin/go-backend:v1 .   # buat image
docker images                                            # lihat daftar image
docker run --rm -p 8888:8888 dadin/go-backend:v1         # jalankan
docker ps                                                # lihat yang sedang jalan
docker logs <nama-container>                             # lihat log
docker rm -f <nama-container>                            # hentikan + hapus
```

Arti `-t dadin/go-backend:v1`:

```
dadin      /  go-backend  :  v1
|             |              |
namespace     nama repo      tag
(akun)                       (versi)
```

---

## 1.2 Registry dan Docker Hub

Image yang dibuat di laptop hanya ada di laptop. Supaya Kubernetes bisa memakainya, image harus disimpan di tempat yang bisa diakses bersama — itulah **registry**.

**Docker Hub** adalah registry publik paling umum. Alamat lengkapnya `docker.io`, dan itu default-nya: saat Anda menulis `nginx:1.29-alpine`, sebenarnya artinya `docker.io/library/nginx:1.29-alpine`.

> Analogi: registry itu **perpustakaan**. `docker push` = menaruh buku, `docker pull` = meminjam buku. Repository = satu judul buku, tag = edisi cetaknya.

### Access token, bukan password

Untuk push, Anda harus login. **Jangan pakai password akun.** Pakai *Personal Access Token* (PAT):

1. Buka <https://hub.docker.com> -> Account Settings -> **Personal access tokens**
2. **Generate new token**, beri nama (mis. `tekton-local`), pilih permission **Read, Write, Delete**
3. Salin token-nya — hanya ditampilkan **sekali**. Bentuknya `dckr_pat_xxxxx...`

Kenapa token lebih baik dari password:

- Bisa dicabut satu per satu tanpa mengganti password akun
- Bisa dibatasi permission-nya
- Tetap jalan meski akun pakai 2FA

Di project ini token disimpan di `secret.md`, dan file itu **wajib** masuk `.gitignore`:

```gitignore
secret.md
```

> **Aturan yang tidak boleh dilanggar:** kredensial tidak pernah masuk ke Git. Sekali ter-push, token itu harus dianggap bocor selamanya — menghapusnya di commit berikutnya tidak menolong, karena masih tersimpan di riwayat.

### Tag: kenapa `latest` berbahaya

```powershell
docker pull dadin/go-backend:latest
```

`latest` **bukan** berarti "versi terbaru" — itu cuma nama tag biasa yang kebetulan sering dipakai. Masalahnya: isinya berubah-ubah, jadi Anda tidak pernah tahu persis kode mana yang sedang jalan.

Di project ini tag yang dipakai untuk deploy adalah **SHA commit Git**:

```
dadin/go-backend:32b21ca
```

`32b21ca` adalah 7 karakter pertama hash commit. Keuntungannya: dari tag image yang sedang jalan, Anda bisa langsung tahu commit persisnya.

```powershell
git show 32b21ca      # lihat persis kode yang sedang jalan
```

Bab 5 menjelaskan bug nyata yang muncul kalau memakai tag statis seperti `v1`.

---

## 1.3 Kubernetes

Kalau Docker menjalankan satu container di satu mesin, **Kubernetes** (sering disingkat **k8s**) mengatur banyak container di banyak mesin: menjadwalkan, merestart yang mati, menyeimbangkan beban, dan mengganti versi tanpa downtime.

> Analogi: Docker = **memasak satu piring**. Kubernetes = **manajer dapur restoran** yang mengatur banyak koki, mengganti koki yang sakit, dan menambah koki saat ramai.

### Deklaratif, bukan imperatif

Kubernetes bekerja dengan **objek** yang dideklarasikan dalam YAML. Anda menulis *keadaan yang diinginkan*, lalu Kubernetes berusaha mewujudkannya terus-menerus.

Anda tidak bilang "jalankan container", tapi "saya mau selalu ada 1 pod backend". Kalau pod-nya mati, Kubernetes yang menghidupkan lagi — tanpa Anda perintahkan. Ini perbedaan mendasar dengan `docker run`.

### Objek yang perlu Anda kenal

#### Pod

Unit terkecil. Satu pod berisi satu container (atau beberapa yang saling erat). Pod **fana** — bisa mati dan diganti kapan saja, dan IP-nya berubah.

```powershell
kubectl get pods -n dev
```

#### Deployment

Mengelola pod: berapa jumlahnya (`replicas`), image apa yang dipakai, dan bagaimana cara menggantinya saat update.

Dari `k8s/backend-deployment.yaml`:

```yaml
spec:
  replicas: 1                          # mau ada 1 pod
  selector:
    matchLabels:
      app: employee-backend            # pod mana yang "milik" deployment ini
  template:                            # cetakan pod-nya
    spec:
      containers:
        - name: backend
          image: dadin/go-backend:latest
          ports:
            - containerPort: 8888
```

Saat image diganti, Deployment melakukan **rolling update**: pod baru dibuat dulu, ditunggu sampai siap, baru pod lama dimatikan. Karena itu aplikasi tidak mati saat update.

#### Service

Karena IP pod berubah-ubah, dibutuhkan alamat tetap. **Service** memberi nama DNS tetap yang otomatis mengarah ke pod yang sehat.

```yaml
kind: Service
metadata:
  name: employee-backend
spec:
  type: ClusterIP
  selector:
    app: employee-backend     # cari pod berlabel ini
  ports:
    - port: 8888
```

Setelah ini, container mana pun di namespace yang sama bisa memanggil `http://employee-backend:8888` — dan itulah yang dilakukan nginx di frontend.

Tiga tipe Service yang perlu diketahui:

| Tipe | Bisa diakses dari | Dipakai di project ini |
|---|---|---|
| `ClusterIP` | hanya dari dalam cluster | backend |
| `NodePort` | port tinggi (30000-32767) di node | **tidak jalan di Docker Desktop** |
| `LoadBalancer` | dari luar cluster | frontend, port 8090 |

> **Khusus Docker Desktop:** NodePort **tidak** diteruskan ke `localhost`. Yang diteruskan Docker Desktop hanyalah `LoadBalancer`. Ini sudah diuji — `http://localhost:30080` ditolak, `http://localhost:8090` (LoadBalancer) jalan. Detailnya di bab 5 kasus #6.

#### Namespace

Sekat logis di dalam cluster, seperti folder. Project ini memakai dua:

| Namespace | Isi | Alasan dipisah |
|---|---|---|
| `cicd` | Task, Pipeline, PipelineRun, ServiceAccount Tekton | mesin CI/CD |
| `dev` | Deployment + Service aplikasi | aplikasi yang dilayani |

Memisahkannya bukan sekadar rapi: dengan begitu izin pipeline bisa dibatasi hanya ke `dev` saja (lihat RBAC di bawah).

#### Probe — bagaimana Kubernetes tahu aplikasi siap

```yaml
readinessProbe:                   # "sudah siap menerima trafik?"
  httpGet:
    path: /api/health
    port: http
  initialDelaySeconds: 3
  periodSeconds: 10

livenessProbe:                    # "masih hidup? kalau tidak, restart"
  httpGet:
    path: /api/health
    port: http
```

Bedanya penting:

- **readiness** gagal -> pod **tidak diberi trafik**, tapi tidak di-restart
- **liveness** gagal -> pod **di-restart**

Tanpa readinessProbe, Service bisa mengirim trafik ke pod yang belum siap, dan pengguna melihat error saat deploy.

### kubectl — alat komunikasi ke Kubernetes

```powershell
kubectl get pods -n dev                  # daftar pod
kubectl get all -n dev                   # semua objek utama
kubectl describe pod <nama> -n dev       # detail + Events (paling berguna saat error)
kubectl logs <nama-pod> -n dev           # log aplikasi
kubectl logs <nama-pod> -n dev -f        # ikuti terus
kubectl apply -f file.yaml               # terapkan YAML
kubectl delete -f file.yaml              # hapus
```

Dua kebiasaan yang menghemat banyak waktu:

```powershell
# 1. Cek YAML valid TANPA benar-benar menerapkan
kubectl apply --dry-run=server -f k8s/backend-deployment.yaml

# 2. Saat pod bermasalah, bagian "Events" di bawah describe
#    hampir selalu memberitahu penyebabnya
kubectl describe pod <nama> -n dev
```

`--dry-run=server` mengirim YAML ke API server untuk divalidasi tapi tidak menyimpannya. Ini menangkap salah ketik dan field yang tidak dikenal — di project ini cara itu menemukan satu bug nyata (bab 5 kasus #5).

### RBAC — siapa boleh melakukan apa

Kubernetes menolak semua yang tidak diizinkan secara eksplisit. Ada empat objek:

| Objek | Fungsi |
|---|---|
| **ServiceAccount** | identitas yang dipakai pod (bukan manusia) |
| **Role** | daftar izin **di satu namespace** |
| **ClusterRole** | daftar izin **di seluruh cluster** |
| **RoleBinding** | menempelkan Role ke ServiceAccount |

Project ini memakai `Role` (namespaced), **bukan** `ClusterRole`:

```yaml
kind: ServiceAccount
metadata:
  name: tekton-deployer
  namespace: cicd          # identitas hidup di cicd
---
kind: Role
metadata:
  name: tekton-deployer
  namespace: dev           # tapi izinnya hanya berlaku di dev
rules:
  - apiGroups: ["apps"]
    resources: ["deployments"]
    verbs: ["get", "list", "watch", "create", "update", "patch"]
```

Efeknya: pipeline **bisa** men-deploy ke `dev`, tapi **tidak bisa** menyentuh `kube-system` atau namespace lain. Ini prinsip *least privilege* — beri izin seminimal mungkin. Kalau pipeline pernah dibajak, kerusakannya terbatas.

Cara mengujinya:

```powershell
kubectl auth can-i create deployments.apps -n dev --as=system:serviceaccount:cicd:tekton-deployer
# yes

kubectl auth can-i create deployments.apps -n default --as=system:serviceaccount:cicd:tekton-deployer
# no
```

---

## 1.4 Tekton

**Tekton** adalah sistem CI/CD yang berjalan **di dalam** Kubernetes. Berbeda dengan GitHub Actions atau Jenkins yang butuh server terpisah, Tekton hanyalah objek Kubernetes biasa — dipasang dengan `kubectl apply`, dan tiap langkahnya berjalan sebagai pod.

> Analogi: Tekton itu **resep kerja** yang ditempel di dinding dapur. Tiap langkah dikerjakan oleh koki (pod) yang dipanggil khusus untuk langkah itu, lalu pulang setelah selesai.

### Empat objek utama

```
Pipeline  --berisi-->  Task  --berisi-->  Step  --dijalankan di-->  Container

PipelineRun  = satu kali eksekusi Pipeline
TaskRun      = satu kali eksekusi Task
```

#### Step — satu perintah dalam satu container

```yaml
steps:
  - name: go-test
    image: golang:1.27-alpine     # container tempat perintah dijalankan
    script: |
      #!/bin/sh
      go test ./...
```

Ini kekuatan utama Tekton: **tiap step boleh memakai image berbeda**. Test Go jalan di `golang:1.27-alpine`, test frontend di `node:22-alpine`, deploy di `alpine/k8s:1.36.1`. Tidak perlu satu server yang punya semuanya sekaligus.

#### Task — kumpulan step yang bisa dipakai ulang

```yaml
kind: Task
metadata:
  name: backend-test
spec:
  workspaces:
    - name: source          # folder yang di-share
  steps:
    - name: go-test
      image: golang:1.27-alpine
      workingDir: $(workspaces.source.path)
      script: |
        go vet ./...
        go test ./...
```

#### Pipeline — merangkai Task dan mengatur urutan

```yaml
kind: Pipeline
spec:
  tasks:
    - name: clone
      taskRef: { name: git-clone }

    - name: backend-test
      runAfter: [clone]          # tunggu clone selesai
      taskRef: { name: backend-test }

    - name: frontend-test
      runAfter: [clone]          # juga tunggu clone -> JALAN BARENGAN
      taskRef: { name: frontend-test }
```

**`runAfter` yang menentukan paralel atau berurutan.** Dua task yang `runAfter`-nya sama akan berjalan **bersamaan**. Di pipeline ini `backend-test` dan `frontend-test` jalan barengan sehingga lebih cepat.

#### PipelineRun — tombol "jalankan"

Pipeline hanyalah definisi; ia tidak melakukan apa pun sampai dibuat PipelineRun:

```powershell
kubectl create -f tekton/pipelinerun.yaml
```

> Perhatikan: **`kubectl create`, bukan `apply`.** File ini memakai `generateName` (bukan `name`), sehingga tiap eksekusi mendapat nama unik otomatis seperti `employee-ci-cd-2ccdv`. `apply` butuh nama yang tetap, jadi akan gagal.

### Workspace — cara Task berbagi file

Tiap Task jalan di pod berbeda. Pod tidak berbagi filesystem secara default, jadi hasil `git clone` di Task pertama tidak otomatis terlihat oleh Task kedua.

**Workspace** memecahkan ini: sebuah volume yang di-mount ke semua Task.

```yaml
workspaces:
  - name: shared-workspace
    volumeClaimTemplate:            # buat disk sementara khusus run ini
      spec:
        accessModes: [ReadWriteOnce]
        resources:
          requests:
            storage: 5Gi
```

Alurnya: `clone` menulis source ke workspace -> `backend-test` membacanya -> `backend-build` membacanya juga -> `deploy` membaca folder `k8s/` dari situ.

### Result — cara Task mengoper nilai

Task bisa mengeluarkan nilai kecil untuk dipakai Task lain. Ada **tiga** bagian, dan ketiganya wajib ada:

```yaml
# 1. Di Task git-clone: DEKLARASIKAN
results:
  - name: commit-short
    description: SHA pendek, dipakai sebagai tag image

# 2. Di Task git-clone: TULIS nilainya ke file
steps:
  - script: |
      git rev-parse --short=7 HEAD | tr -d '\n' > "$(results.commit-short.path)"
```

```yaml
# 3. Di Pipeline: PAKAI
params:
  - name: TAG
    value: $(tasks.clone.results.commit-short)
```

> **Jebakan yang benar-benar terjadi di project ini:** result yang *dideklarasikan* (langkah 1) tapi *tidak ditulis* (langkah 2 terlewat) membuat Task yang memakainya gagal validasi — dan pesan errornya (`PipelineValidationFailed`) tidak menyebut result mana yang bermasalah. Bab 5 kasus #1 membahasnya lengkap.

### Kaniko — membangun image tanpa Docker

Ada masalah klasik: untuk build image di dalam Kubernetes, biasanya butuh akses ke Docker daemon. Memberikan akses itu ke pod sama saja memberi kuasa penuh atas node — berbahaya.

**Kaniko** membangun image dari Dockerfile **tanpa** Docker daemon:

```yaml
- name: build-push
  image: gcr.io/kaniko-project/executor:v1.23.2
  args:
    - --dockerfile=$(workspaces.source.path)/Dockerfile-go
    - --context=$(workspaces.source.path)
    - --destination=docker.io/dadin/go-backend:32b21ca
  volumeMounts:
    - name: docker-config
      mountPath: /kaniko/.docker      # kredensial Docker Hub dipasang di sini
```

- `--dockerfile` = resep mana yang dipakai
- `--context` = folder mana yang jadi "root" saat `COPY` dijalankan
- `--destination` = mau di-push ke mana (boleh lebih dari satu)

---

## 1.5 Bagaimana semuanya tersambung

Ringkasan siapa memanggil siapa di project ini:

```
git push
   |
   v
GitHub  --(Task git-clone menarik source)-->  Workspace (disk sementara)
                                                  |
                            +---------------------+---------------------+
                            v                     v                     v
                     backend-test           frontend-test          (menunggu)
                     golang:1.27            node:22
                            |                     |
                            +------ keduanya hijau ------+
                                                         v
                                        +----------------+----------------+
                                        v                                 v
                                 backend-build                     frontend-build
                                 (Kaniko)                          (Kaniko)
                                        |                                 |
                                        +-------- push --> Docker Hub <---+
                                                              |
                                                              v
                                                      deploy (kubectl)
                                                              |
                                                              v
                                                  namespace dev: pod jalan
                                                              |
                                                              v
                                                  http://localhost:8090
```

Lanjut ke [Bab 2 — Setup dari Nol](02-setup-dari-nol.md).
