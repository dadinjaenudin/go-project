# Bab 8 — Trigger Otomatis saat `git push`

Sampai bab 7, pipeline dijalankan manual dengan `kubectl create -f tekton/pipelinerun.yaml`. Bab ini membuatnya berjalan sendiri setiap kali Anda `git push`.

---

## 8.1 Empat objek baru

Tekton Triggers menambahkan empat objek di atas yang sudah Anda kenal:

```
HTTP POST masuk
      |
      v
+------------------+
| EventListener    |  pod yang menunggu request di port 8080
+--------+---------+
         |
         v
+------------------+
| Interceptor      |  SARINGAN: tanda tangan sah? event push? branch main?
+--------+---------+
         |
         v
+------------------+
| TriggerBinding   |  AMBIL: url repo + nama branch dari payload JSON
+--------+---------+
         |
         v
+------------------+
| TriggerTemplate  |  CETAK: PipelineRun baru
+--------+---------+
         |
         v
   PipelineRun berjalan
```

| Objek | Analogi | File |
|---|---|---|
| **EventListener** | resepsionis yang menerima tamu | `tekton/triggers/event-listener.yaml` |
| **Interceptor** | satpam yang memeriksa identitas | (di dalam event-listener.yaml) |
| **TriggerBinding** | formulir yang mencatat data tamu | `tekton/triggers/trigger-binding.yaml` |
| **TriggerTemplate** | blangko surat tugas | `tekton/triggers/trigger-template.yaml` |

---

## 8.2 Kendala: GitHub tidak bisa menjangkau laptop Anda

Ini yang harus dipahami sebelum apa pun.

```powershell
kubectl cluster-info
# Kubernetes control plane is running at https://127.0.0.1:56611
```

`127.0.0.1` artinya **hanya bisa diakses dari komputer ini**. Server GitHub di internet tidak punya jalan masuk ke sana. Webhook GitHub yang sesungguhnya butuh URL publik.

Karena itu ada dua cara memakai setup ini:

| Mode | Cara kerja | Butuh internet masuk? | Cocok untuk |
|---|---|---|---|
| **A. Git hook lokal** | hook `pre-push` di laptop mengirim sendiri webhook ke `localhost:8095` | tidak | belajar, kerja sendirian |
| **B. Webhook GitHub** | GitHub mengirim webhook lewat terowongan publik | ya (tunnel) | tim, mendekati production |

Mode A sudah aktif dan berjalan. Mode B dijelaskan di bagian 8.6.

Yang penting: **infrastruktur Tekton-nya sama persis**. Bedanya cuma siapa yang menekan tombolnya.

---

## 8.3 Pemasangan

```powershell
powershell -ExecutionPolicy Bypass -File tekton\setup-triggers.ps1
```

Prasyarat: `tekton\setup.ps1` sudah pernah dijalankan.

Script ini mengerjakan enam hal:

1. Memasang Tekton Triggers kalau belum ada
2. Membuat token webhook acak 64 karakter di `webhook-secret.txt`
3. Membuat Secret `github-webhook-secret` di namespace `cicd`
4. Menerapkan RBAC, TriggerBinding, TriggerTemplate, EventListener
5. Membuat Service LoadBalancer supaya EventListener bisa dihubungi di `localhost:8095`
6. Menyalakan git hook lewat `git config core.hooksPath githooks`

### Verifikasi

```powershell
# EventListener hidup?
kubectl get pods -n cicd -l eventlistener=employee-push-listener
# el-employee-push-listener-xxx   1/1   Running

# Bisa dihubungi dari Windows?
kubectl get svc -n cicd el-webhook
# el-webhook   LoadBalancer   10.96.216.106   172.80.11.6   8095:31829/TCP

netstat -ano | Select-String ":8095"
# TCP 0.0.0.0:8095 LISTENING

# Hook aktif?
git config core.hooksPath
# githooks
```

### Coba

```powershell
git commit --allow-empty -m "uji trigger"
git push origin main
```

Yang muncul:

```
[tekton] push ke main terdeteksi (a1b2c3d)
[tekton] pipeline akan dipicu setelah commit sampai di GitHub
[tekton] pantau: kubectl get pipelinerun -n cicd -l trigger=github-push
```

Lalu:

```powershell
kubectl get pipelinerun -n cicd -l trigger=github-push
# employee-ci-cd-auto-xbmp4   Unknown   Running
```

---

## 8.4 Jebakan waktu: kenapa hook memakai proses latar

Ini bagian paling penting di bab ini.

**Git tidak punya hook `post-push`.** Yang tersedia hanya `pre-push`, dan namanya jujur — ia berjalan **sebelum** commit sampai di GitHub.

Kalau webhook dikirim saat itu juga:

```
detik 0   hook jalan, kirim webhook
detik 1   Tekton buat PipelineRun
detik 3   task git-clone menarik dari GitHub  <-- commit BARU BELUM ADA
detik 4   yang ter-clone adalah commit LAMA
...
          pipeline HIJAU, tapi yang di-build versi sebelumnya
```

Ini persis jenis bug yang paling sulit disadari, sekelas dengan kasus #4 di bab 5: semuanya tampak sukses, tapi hasilnya salah.

Solusinya ada di `githooks/pre-push`:

```sh
kirim_setelah_sampai() {
    while :; do
        sha_remote=$(git ls-remote "$REMOTE_NAME" "refs/heads/$branch" | cut -f1)
        [ "$sha_remote" = "$sha" ] && break        # GitHub sudah punya
        sleep 2
    done
    # baru kirim webhook
}

kirim_setelah_sampai "$local_sha" "$BRANCH" "$REMOTE_URL" &   # <- dilepas ke latar
```

Prosesnya menunggu sampai `git ls-remote` membuktikan GitHub benar-benar sudah punya commit itu, baru mengirim webhook. Tanda `&` di ujung membuatnya berjalan di latar, sehingga `git push` Anda tidak ikut tertahan.

Batas tunggunya 90 detik. Kalau lewat, kegagalannya dicatat di log dan tidak ada pipeline yang dijalankan — lebih baik tidak jalan daripada jalan dengan kode yang salah.

---

## 8.5 Keamanan: kenapa ada tanda tangan

`localhost:8095` menerima POST dari siapa pun yang bisa menjangkaunya. Tanpa perlindungan, program apa pun di laptop Anda — atau siapa pun di jaringan yang sama, kalau port-nya terekspos — bisa menjalankan pipeline Anda kapan saja.

Perlindungannya adalah **HMAC-SHA256**: pengirim dan penerima sama-sama tahu satu token rahasia. Pengirim menghitung sidik jari dari isi pesan + token, dan menaruhnya di header:

```
X-Hub-Signature-256: sha256=a3f5b8...
```

EventListener menghitung ulang dengan token yang ia punya. Kalau tidak sama, request ditolak.

```yaml
- ref:
    name: github
  params:
    - name: secretRef
      value:
        secretName: github-webhook-secret
        secretKey: secretToken
    - name: eventTypes
      value: ["push"]
```

Token ini yang harus dijaga, dan karena itu `webhook-secret.txt` ada di `.gitignore` — sama seperti `secret.md`.

### Membuktikan penyaringan benar-benar bekerja

Empat pengujian ini sudah dijalankan pada setup Anda:

| Yang dikirim | Hasil |
|---|---|
| Tanpa tanda tangan | ditolak, tidak ada PipelineRun |
| Tanda tangan salah | ditolak, tidak ada PipelineRun |
| Tanda tangan benar, branch `fitur-baru` | disaring CEL, tidak ada PipelineRun |
| Tanda tangan benar, branch `main` | **PipelineRun dibuat** |

> **Catatan yang membingungkan:** EventListener selalu membalas **HTTP 202**, bahkan untuk request yang ditolak. Interceptor berjalan asinkron setelah balasan dikirim. Jadi **jangan pakai kode HTTP untuk menilai berhasil atau tidak** — periksa apakah PipelineRun benar-benar terbuat:
>
> ```powershell
> kubectl get pipelinerun -n cicd -l trigger=github-push
> ```

---

## 8.6 Mode B: webhook GitHub sungguhan

Kalau ingin GitHub yang memicu langsung (misalnya supaya push dari rekan tim ikut memicu), EventListener harus punya alamat publik. Cara termudah adalah terowongan.

### Dengan cloudflared

```powershell
winget install --id Cloudflare.cloudflared
cloudflared tunnel --url http://localhost:8095
```

Akan muncul URL seperti `https://random-kata-kata.trycloudflare.com`. Biarkan jendela itu terbuka.

### Daftarkan di GitHub

1. Buka repo -> **Settings** -> **Webhooks** -> **Add webhook**
2. **Payload URL**: URL dari cloudflared tadi
3. **Content type**: `application/json`
4. **Secret**: isi dengan isi `webhook-secret.txt`

   ```powershell
   Get-Content webhook-secret.txt
   ```
5. **Which events**: *Just the push event*
6. **Add webhook**

GitHub langsung mengirim satu ping percobaan. Di halaman webhook, tab **Recent Deliveries** memperlihatkan respons — harus `202`.

### Matikan hook lokal supaya tidak dobel

```powershell
git config --unset core.hooksPath
```

Kalau keduanya aktif, satu push menghasilkan dua PipelineRun.

> URL `trycloudflare.com` gratis dan berubah setiap kali cloudflared dijalankan ulang, jadi webhook GitHub harus diperbarui tiap kali. Untuk pemakaian menetap, pakai named tunnel Cloudflare atau ngrok berbayar.

---

## 8.7 Cara memakai sehari-hari

Alurnya jadi lebih pendek dari bab 2:

```powershell
# 1. Ubah kode, uji lokal
docker run --rm -v "D:\MY-Project\go-project:/src" -w /src golang:1.27-alpine sh -c "go test ./..."

# 2. Commit + push -- pipeline jalan SENDIRI
git add -A
git commit -m "perubahan X"
git push origin main

# 3. Pantau
kubectl get pipelinerun -n cicd -l trigger=github-push
tkn pipelinerun logs -n cicd --last -f
```

### Melewati trigger untuk satu push

Berguna saat hanya mengubah dokumentasi:

```powershell
$env:SKIP_TEKTON=1
git push origin main
$env:SKIP_TEKTON=$null
```

### Mematikan sepenuhnya

```powershell
git config --unset core.hooksPath
```

### Menjalankan manual (tetap bisa)

```powershell
kubectl create -f tekton\pipelinerun.yaml
```

Bedakan keduanya lewat label:

```powershell
kubectl get pipelinerun -n cicd -l trigger=github-push    # otomatis
kubectl get pipelinerun -n cicd                           # semua
```

Run otomatis bernama `employee-ci-cd-auto-*`, run manual `employee-ci-cd-*`.

---

## 8.8 Melacak asal sebuah run

TriggerTemplate memasang label pada setiap PipelineRun:

```powershell
kubectl get pipelinerun -n cicd -l trigger=github-push `
  -o custom-columns='NAME:.metadata.name,PUSHER:.metadata.labels.git-pusher,COMMIT:.metadata.labels.git-commit'

# NAME                        PUSHER          COMMIT
# employee-ci-cd-auto-xbmp4   dadinjaenudin   23c7bbf831e3293b592650ed05a492ab9847ecd6
```

Dari situ Anda bisa langsung melihat kodenya:

```powershell
git show 23c7bbf
```

---

## 8.9 Troubleshooting

### Hook tidak jalan sama sekali saat push

```powershell
git config core.hooksPath
# harus "githooks"

Test-Path githooks\pre-push
# harus True
```

Kalau `core.hooksPath` kosong, jalankan ulang `setup-triggers.ps1`.

### Hook jalan, tapi tidak ada PipelineRun

Baca log hook — di situlah jawabannya:

```powershell
Get-Content .git\tekton-trigger.log -Tail 20
```

| Isi log | Artinya |
|---|---|
| `http=202` | webhook terkirim; masalahnya di interceptor, lanjut ke bawah |
| `http=000` | tidak bisa menghubungi `localhost:8095` |
| `GAGAL: setelah 90s...` | GitHub belum punya commit-nya; push gagal atau jaringan lambat |

Untuk `http=000`:

```powershell
kubectl get svc -n cicd el-webhook
netstat -ano | Select-String ":8095"
```

Kalau port tidak terbuka, buat ulang Service-nya (ingat kasus #7 di bab 5):

```powershell
kubectl delete svc -n cicd el-webhook
kubectl apply -f tekton\triggers\service-webhook.yaml
```

### `http=202` tapi tetap tidak ada PipelineRun

Berarti interceptor menolaknya. Periksa log EventListener:

```powershell
kubectl logs -n cicd -l eventlistener=employee-push-listener --tail=50
```

Penyebab tersering:

| Penyebab | Cara memastikan |
|---|---|
| Token di file beda dengan yang di cluster | bandingkan keduanya (perintah di bawah) |
| Push ke branch selain `main` | filter CEL memang menolaknya |
| Header `X-GitHub-Event` bukan `push` | interceptor github menyaringnya |

```powershell
# Bandingkan token file vs cluster
$file = (Get-Content webhook-secret.txt -Raw).Trim()
$b64 = kubectl get secret github-webhook-secret -n cicd -o jsonpath='{.data.secretToken}'
$cluster = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($b64))
if ($file -eq $cluster) { "COCOK" } else { "BEDA - jalankan ulang setup-triggers.ps1" }
```

> Penyebab paling licin di sini adalah **karakter tak terlihat**. Kalau `webhook-secret.txt` punya newline atau carriage return di ujung, token yang dipakai menandatangani berbeda satu byte dari yang ada di cluster, dan semua request ditolak tanpa penjelasan jelas. Karena itu `setup-triggers.ps1` menulis file itu tanpa newline sama sekali, dan hook membacanya dengan `tr -d '\r\n'`.

### EventListener `0/1 Running` terus

```powershell
kubectl logs -n cicd -l eventlistener=employee-push-listener --tail=20
```

Kalau muncul `... is forbidden: ... cannot list resource "interceptors"`, berarti RBAC kurang. `interceptors` (namespaced) dan `clusterinterceptors` (cluster-scoped) adalah **dua resource berbeda** dan keduanya harus diizinkan — yang pertama di `Role`, yang kedua di `ClusterRole`. Keduanya sudah ada di `tekton/triggers/rbac.yml`.

### Satu push menghasilkan dua PipelineRun

Git hook dan webhook GitHub sama-sama aktif. Matikan salah satu:

```powershell
git config --unset core.hooksPath
```

---

## 8.10 Latihan

**Latihan 8.1 — Buktikan penyaringan bekerja**

Kirim request tanpa tanda tangan, lalu periksa tidak ada PipelineRun baru:

```powershell
$sha = git rev-parse HEAD
$body = '{"ref":"refs/heads/main","after":"' + $sha + '","repository":{"clone_url":"x"},"pusher":{"name":"penyusup"}}'
curl.exe -s -o NUL -w "HTTP %{http_code}`n" -X POST http://localhost:8095 `
  -H "Content-Type: application/json" -H "X-GitHub-Event: push" --data $body

kubectl get pipelinerun -n cicd -l git-pusher=penyusup
# harus: No resources found
```

Perhatikan balasannya tetap `202` — dan itulah sebabnya kode HTTP tidak bisa dipakai untuk menilai keberhasilan.

**Latihan 8.2 — Buat trigger untuk branch lain**

Tambahkan trigger kedua di `event-listener.yaml` yang menangkap push ke `staging` dan men-deploy ke namespace `staging`. Petunjuk: `spec.triggers` menerima daftar, jadi tambahkan satu entri lagi dengan filter CEL berbeda dan TriggerTemplate yang mengoper `deploy-namespace: staging`. Anda juga perlu `Role` + `RoleBinding` baru di namespace itu — pakai pengetahuan dari Latihan 4 di bab 7.

**Latihan 8.3 — Reproduksi bug balapan**

Ubah `githooks/pre-push`, hapus fungsi tunggu sehingga webhook dikirim langsung. Lalu ubah sesuatu yang terlihat di UI, commit, push. Perhatikan pipeline hijau tapi perubahan Anda tidak muncul — karena yang ter-clone commit sebelumnya. Kembalikan setelah selesai.
