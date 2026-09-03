# Bab 3 — Anatomi File

Bab ini membedah tiap file: apa fungsinya, baris mana yang penting, dan kenapa ditulis begitu.

## Peta folder

```
go-project/
├── main.go                     backend Go (API)
├── main_test.go                unit test backend
├── go.mod / go.sum             daftar dependency Go
├── data/
│   └── data_master_karyawan.csv    satu-satunya sumber data (50 baris)
│
├── ui/                         frontend Vue
│   ├── src/components/myComponent.vue      SELURUH logika UI (465 baris)
│   ├── src/components/__tests__/           unit test frontend
│   ├── package.json            dependency + script npm
│   ├── vite.config.js          konfigurasi build + test + proxy dev
│   ├── nginx.conf              konfigurasi nginx untuk produksi
│   └── Dockerfile              resep image frontend
│
├── Dockerfile-go               resep image backend
│
├── k8s/                        manifest APLIKASI (namespace dev)
│   ├── namespace.yaml
│   ├── backend-deployment.yaml
│   ├── backend-service.yaml
│   ├── frontend-deployment.yaml
│   └── frontend-service.yaml
│
├── tekton/                     manifest CI/CD (namespace cicd)
│   ├── rbac.yml                izin
│   ├── task-git-clone.yaml     6 task
│   ├── task-backend-test.yaml
│   ├── task-frontend-test.yaml
│   ├── task-backend-build.yaml
│   ├── task-frontend-build.yaml
│   ├── task-deploy.yaml
│   ├── pipeline.yaml           urutan task
│   ├── pipelinerun.yaml        tombol jalankan
│   ├── setup.ps1               bootstrap (Windows)
│   └── setup.sh                bootstrap (Git Bash)
│
├── secret.md                   token Docker Hub — TIDAK di-commit
└── .gitignore
```

Aturan pembagiannya: **`k8s/` untuk aplikasi, `tekton/` untuk mesin CI/CD.** Jangan campur.

---

## 3.1 Aplikasi

### `main.go` — backend

Isinya cuma dua endpoint dan satu fungsi pembaca CSV.

```go
func readCSV(filename string) ([]map[string]string, error) {
    headers, err := reader.Read()          // baris pertama = nama kolom

    if len(headers) > 0 {
        headers[0] = strings.TrimPrefix(headers[0], "\ufeff")
    }
    ...
    row[headers[i]] = value                // kunci map = nama kolom CSV
}
```

**Baris `TrimPrefix` itu penting dan sering tidak disadari.** File CSV yang disimpan Excel atau Notepad diawali tiga byte tersembunyi `EF BB BF` — namanya **BOM** (Byte Order Mark). Library `encoding/csv` Go tidak membuangnya, sehingga nama kolom pertama menjadi `"\ufeffNP"`, bukan `"NP"`.

Akibatnya di frontend, `employee.NP` bernilai `undefined` dan kolom NP tampil kosong — tanpa error di mana pun. Bug seperti ini sulit dilacak karena semuanya "kelihatan jalan".

Cara memeriksa BOM sendiri:

```powershell
Format-Hex data\data_master_karyawan.csv | Select-Object -First 1
# kalau diawali EF BB BF, ada BOM
```

> **Catatan untuk yang menulis kode Go:** jangan pernah menaruh karakter BOM asli di dalam file `.go`. Compiler menolaknya dengan `illegal byte order mark`. Pakai escape `\ufeff`. Ini juga error nyata yang terjadi saat menulis test-nya (bab 5 kasus #7).

```go
e.Static("/", "ui/dist")     // BUKAN "ui"
```

Kalau diarahkan ke `"ui"`, server akan menyajikan seluruh source code dan `node_modules` lewat HTTP. `"ui/dist"` hanya menyajikan hasil build.

### `main_test.go` — unit test backend

Lima test. Yang paling berharga adalah dua ini:

```go
func TestReadCSVMembuangBOMDariHeaderPertama(t *testing.T) {
    path := tulisCSV(t, "\ufeffNP,Nama\nP2016001,Bambang Wijaya\n")
    rows, _ := readCSV(path)

    if got, ok := rows[0]["NP"]; !ok || got != "P2016001" {
        t.Errorf(...)      // gagal kalau BOM tidak dibuang
    }
}

func TestReadCSVDataAsli(t *testing.T) {
    rows, _ := readCSV("data/data_master_karyawan.csv")

    for _, kolom := range []string{"NP", "Nama", "Unit Kerja", ...} {
        if _, ok := rows[0][kolom]; !ok {
            t.Errorf("kolom %q tidak ada", kolom)
        }
    }
}
```

Test kedua memakai **file CSV asli**, bukan data palsu. Fungsinya sebagai jaring pengaman: kalau suatu hari ada yang mengubah nama kolom di CSV, test langsung merah — padahal tanpa test itu, yang terjadi hanyalah kolom kosong di layar tanpa pesan error apa pun.

Menjalankannya:

```powershell
docker run --rm -v "D:\MY-Project\go-project:/src" -w /src golang:1.27-alpine sh -c "go test ./... -v"
```

### `ui/src/components/myComponent.vue` — seluruh frontend

Satu file 465 baris berisi template, logika, dan style. Bagian yang perlu diperhatikan:

```js
const response = await axios.get("/api/data");    // path RELATIF
```

**Bukan** `http://localhost:8888/api/data`. Alasannya: URL absolut hanya benar di laptop. Di Kubernetes, browser pengguna tidak punya apa-apa di `localhost:8888`.

Dengan path relatif, yang menyambungkan ke backend berbeda-beda per lingkungan:

| Lingkungan | Penyambung |
|---|---|
| `npm run dev` | proxy di `vite.config.js` -> `localhost:8888` |
| Kubernetes | `nginx.conf` -> `http://employee-backend:8888` |

Ini pola penting: **kode aplikasi tidak tahu di mana backend berada; infrastruktur yang mengaturnya.**

### `ui/nginx.conf`

```nginx
location /api/ {
    proxy_pass http://employee-backend:8888;
}

location / {
    try_files $uri $uri/ /index.html;
}
```

Blok pertama meneruskan `/api/...` ke Service backend. Nama `employee-backend` bisa dipakai langsung karena Kubernetes menyediakan DNS internal antar-Service di namespace yang sama.

Blok kedua adalah **SPA fallback**: kalau file yang diminta tidak ada, kembalikan `index.html`. Ini yang membuat routing di sisi browser tetap bekerja saat halaman di-refresh.

---

## 3.2 Dockerfile

### `Dockerfile-go` — backend

```dockerfile
FROM golang:1.27-alpine AS builder
COPY go.mod go.sum ./
RUN go mod download                 # layer ini di-cache
COPY main.go ./
RUN CGO_ENABLED=0 GOOS=linux go build -trimpath -ldflags="-s -w" -o /out/server main.go

FROM alpine:3.22
RUN apk add --no-cache ca-certificates wget && adduser -D -u 10001 app
COPY --from=builder /out/server ./server
COPY data ./data
USER app
EXPOSE 8888
HEALTHCHECK CMD wget -qO- http://127.0.0.1:8888/api/health || exit 1
CMD ["./server"]
```

| Bagian | Kenapa |
|---|---|
| `CGO_ENABLED=0` | binary statis, tidak butuh library C — bisa jalan di Alpine yang minim |
| `-ldflags="-s -w"` | buang simbol debug, ukuran binary mengecil |
| `COPY data ./data` | CSV ikut masuk image, jadi tidak perlu ConfigMap terpisah |
| `adduser` + `USER app` | jalan sebagai non-root; kalau ada celah, dampaknya terbatas |
| `HEALTHCHECK` | Docker bisa tahu container sehat atau tidak |

Hasilnya **29,8 MB**.

### `ui/Dockerfile` — frontend

```dockerfile
FROM node:22-alpine AS builder
COPY package.json package-lock.json ./
RUN npm ci
COPY . .
RUN npm run build                    # menghasilkan /app/dist

FROM nginx:1.29-alpine
COPY --from=builder /app/dist /usr/share/nginx/html
COPY nginx.conf /etc/nginx/conf.d/default.conf
RUN sed -i 's|^pid .*|pid /tmp/nginx.pid;|' /etc/nginx/nginx.conf \
    && chown -R nginx:nginx /usr/share/nginx/html /var/cache/nginx
USER nginx
EXPOSE 8080
```

`npm ci` bukan `npm install` — `ci` memasang **persis** versi yang tercatat di `package-lock.json`, jadi hasilnya selalu sama. `install` boleh menaikkan versi minor, yang bikin build tidak reproducible.

Node hanya dipakai untuk **build**. Image akhirnya nginx — Node tidak ikut. Ini kesalahan umum pemula: menjalankan `npm run dev` sebagai container produksi. Dev server lambat, boros memori, dan tidak dirancang untuk itu.

Port **8080**, bukan 80, supaya nginx bisa jalan sebagai user non-root (port di bawah 1024 butuh root).

> **Perhatikan `--context` saat build.** Dockerfile ini menyalin `package.json` dan `nginx.conf` dengan path relatif terhadap folder `ui/`, jadi build context-nya harus `ui/`:
> ```powershell
> docker build -f ui/Dockerfile -t dadin/go-frontend:v1 ui
> #                                                     ^^ context
> ```

---

## 3.3 Manifest Kubernetes (`k8s/`)

### `backend-deployment.yaml`

```yaml
spec:
  replicas: 1
  template:
    spec:
      containers:
        - name: backend
          image: dadin/go-backend:latest      # placeholder
          imagePullPolicy: IfNotPresent
          ports:
            - name: http
              containerPort: 8888
          readinessProbe:
            httpGet: { path: /api/health, port: http }
          livenessProbe:
            httpGet: { path: /api/health, port: http }
          resources:
            requests: { cpu: "50m", memory: "64Mi" }
            limits:   { cpu: "500m", memory: "256Mi" }
```

**Tag `:latest` di sini hanya placeholder.** Task deploy menimpanya dengan tag SHA lewat `kubectl set image`. Manifest tidak pernah menyebut SHA karena SHA-nya baru diketahui saat pipeline berjalan.

`port: http` di probe merujuk **nama** port (`name: http`), bukan angka. Kalau nomor portnya berubah, probe ikut mengikuti otomatis.

`requests` vs `limits`:

- **requests** = jaminan minimum; dipakai penjadwal untuk memilih node
- **limits** = batas maksimum; container yang melewatinya akan dicekik (CPU) atau dimatikan (memori)

### `frontend-service.yaml` — yang paling khusus Docker Desktop

```yaml
spec:
  type: LoadBalancer
  ports:
    - name: http
      port: 8090
      targetPort: http
      nodePort: 30080
```

Kenapa `LoadBalancer` dan bukan `NodePort`, padahal hampir semua tutorial memakai NodePort? Karena di Kubernetes bawaan Docker Desktop, **NodePort tidak diteruskan ke `localhost`**. Sudah diuji: `http://localhost:30080` ditolak, `http://localhost:8090` (LoadBalancer) jalan.

Yang meneruskannya ke Windows adalah proses `com.docker.backend` dan `wslrelay`.

> **Jebakan:** mengubah angka `port` pada Service LoadBalancer yang sudah ada **tidak** membuat Docker Desktop mem-bind ulang. Harus dihapus dulu:
> ```powershell
> kubectl delete svc -n dev employee-frontend
> kubectl apply -f k8s\frontend-service.yaml
> ```

---

## 3.4 Manifest Tekton (`tekton/`)

### `rbac.yml`

Tiga objek, dan yang menarik adalah **lintas namespace**:

```yaml
kind: ServiceAccount
metadata:
  name: tekton-deployer
  namespace: cicd          # identitas ada di cicd
---
kind: Role
metadata:
  namespace: dev           # izin berlaku di dev
---
kind: RoleBinding
metadata:
  namespace: dev
subjects:
  - kind: ServiceAccount
    name: tekton-deployer
    namespace: cicd        # menunjuk SA di namespace LAIN
```

RoleBinding di `dev` boleh menunjuk ServiceAccount yang berada di `cicd`. Inilah cara memberi pipeline izin men-deploy ke `dev` **tanpa** memberi kuasa cluster-wide.

### `task-git-clone.yaml`

```yaml
results:
  - name: commit
  - name: commit-short

steps:
  - name: clone
    image: alpine/git:2.49.1
    script: |
      rm -rf ./* ./.[!.]* 2>/dev/null || true
      git clone --depth 1 --branch "$(params.revision)" "$(params.url)" .
      git rev-parse HEAD           | tr -d '\n' > "$(results.commit.path)"
      git rev-parse --short=7 HEAD | tr -d '\n' > "$(results.commit-short.path)"
```

| Bagian | Kenapa |
|---|---|
| `rm -rf ./*` | workspace bisa dipakai ulang antar-run; sisa run lama harus dibersihkan |
| `--depth 1` | ambil 1 commit terakhir saja, jauh lebih cepat |
| `tr -d '\n'` | buang newline; kalau tidak, tag image jadi `32b21ca\n` dan push gagal |

**Tiap result yang dideklarasikan wajib ditulis.** Melewatkan satu baris `>` saja membuat pipeline gagal validasi (bab 5 kasus #1).

### `task-backend-build.yaml`

```yaml
steps:
  - name: build-push
    image: gcr.io/kaniko-project/executor:v1.23.2
    args:
      - --dockerfile=$(workspaces.source.path)/Dockerfile-go
      - --context=$(workspaces.source.path)
      - --destination=docker.io/$(params.IMAGE):$(params.TAG)
      - --destination=docker.io/$(params.IMAGE):latest
      - --digest-file=$(results.digest.path)
      - --push-retry=3
    volumeMounts:
      - name: docker-config
        mountPath: /kaniko/.docker

volumes:
  - name: docker-config
    secret:
      secretName: dockerhub-secret
      items:
        - key: .dockerconfigjson
          path: config.json          # nama file WAJIB config.json
```

Blok `volumes` di bawah itu yang membuat autentikasi Docker Hub bekerja. Secret `dockerhub-secret` di-mount ke `/kaniko/.docker/config.json` — nama file itu tidak boleh diganti, karena di situlah Kaniko mencarinya.

`--push-retry=3` ditambahkan setelah pipeline sempat gagal dengan `tls: bad record MAC` (bab 5 kasus #3).

Tidak ada `--cache=true`. Sengaja: Kaniko mendorong cache ke repo bersarang `dadin/go-backend/cache` yang tidak didukung Docker Hub, sehingga selalu membalas 401 (bab 5 kasus #2).

### `task-deploy.yaml`

```yaml
image: alpine/k8s:1.36.1

script: |
  #!/bin/bash
  set -euo pipefail

  kubectl apply -n "$NS" -f k8s/backend-deployment.yaml
  kubectl apply -n "$NS" -f k8s/backend-service.yaml
  kubectl apply -n "$NS" -f k8s/frontend-deployment.yaml
  kubectl apply -n "$NS" -f k8s/frontend-service.yaml

  kubectl set image -n "$NS" deployment/employee-backend  backend=$(params.BACKEND_IMAGE):$(params.TAG)
  kubectl set image -n "$NS" deployment/employee-frontend frontend=$(params.FRONTEND_IMAGE):$(params.TAG)

  kubectl rollout status -n "$NS" deployment/employee-backend  --timeout=300s
  kubectl rollout status -n "$NS" deployment/employee-frontend --timeout=300s
```

Tiga hal yang disengaja:

1. **Backend di-apply lebih dulu.** nginx me-resolve nama `employee-backend` saat memuat konfigurasi. Kalau Service backend belum ada, pod frontend gagal start.
2. **Versi image `alpine/k8s:1.36.1` disamakan dengan server (v1.36.1).** kubectl hanya didukung dalam selisih satu versi minor dari server. Image kubectl resmi (`registry.k8s.io/kubectl`) sengaja tidak dipakai karena distroless — tidak punya shell, jadi blok `script:` tidak bisa berjalan.
3. **`rollout status` di akhir.** Tanpa ini, task selesai begitu perintah dikirim, bukan setelah pod benar-benar sehat — pipeline bisa hijau padahal deploy gagal.

### `pipeline.yaml`

```yaml
tasks:
  - name: clone
    taskRef: { name: git-clone }

  - name: backend-test
    runAfter: [clone]

  - name: frontend-test
    runAfter: [clone]

  - name: backend-build
    runAfter: [backend-test, frontend-test]      # tunggu KEDUANYA
    params:
      - name: TAG
        value: $(tasks.clone.results.commit-short)

  - name: frontend-build
    runAfter: [backend-test, frontend-test]

  - name: deploy
    runAfter: [backend-build, frontend-build]
```

Kedua build sengaja menunggu **kedua** test. Kalau `backend-build` hanya menunggu `backend-test`, image backend bisa terlanjur ter-push ke Docker Hub padahal test frontend merah — registry jadi berisi build yang tidak pernah lolos.

### `pipelinerun.yaml`

```yaml
metadata:
  generateName: employee-ci-cd-      # bukan "name"

spec:
  taskRunTemplate:
    serviceAccountName: tekton-deployer
  workspaces:
    - name: shared-workspace
      volumeClaimTemplate:
        spec:
          accessModes: [ReadWriteOnce]
          resources:
            requests: { storage: 5Gi }
```

`generateName` membuat Kubernetes menambahkan akhiran acak, sehingga tiap run punya nama sendiri dan riwayatnya tersimpan. Karena itu file ini dijalankan dengan **`kubectl create`**, bukan `apply`.

`volumeClaimTemplate` membuat disk 5 GB baru setiap run, lalu ikut terhapus saat PipelineRun dihapus.

Lanjut ke [Bab 4 — Alur Pipeline](04-alur-pipeline.md).
