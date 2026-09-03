# Panduan Belajar CI/CD — Data Master Karyawan

Dokumentasi ini ditulis untuk **pemula**. Isinya bukan teori umum, tapi penjelasan
tentang project ini sendiri: kenapa tiap file ada, apa yang terjadi saat pipeline
berjalan, dan error nyata yang benar-benar muncul saat pipeline ini dibangun.

## Urutan baca

Baca berurutan. Tiap bab menganggap Anda sudah paham bab sebelumnya.

| # | File | Isi | Perlu waktu |
|---|------|-----|-------------|
| 1 | [01-konsep-dasar.md](01-konsep-dasar.md) | Container, image, registry, Kubernetes, Tekton — pakai analogi | ~30 menit baca |
| 2 | [02-setup-dari-nol.md](02-setup-dari-nol.md) | Langkah demi langkah sampai aplikasi jalan | ~45 menit praktik |
| 3 | [03-anatomi-file.md](03-anatomi-file.md) | Bedah tiap file: apa fungsinya, baris mana yang penting | ~45 menit baca |
| 4 | [04-alur-pipeline.md](04-alur-pipeline.md) | Apa yang terjadi detik per detik saat pipeline jalan | ~20 menit baca |
| 5 | [05-troubleshooting.md](05-troubleshooting.md) | 9 error nyata dari project ini + cara mendiagnosanya | rujukan |
| 6 | [06-cheatsheet.md](06-cheatsheet.md) | Perintah harian | rujukan |
| 7 | [07-latihan.md](07-latihan.md) | Latihan bertahap untuk memastikan Anda paham | ~2 jam |
| 8 | [08-auto-trigger.md](08-auto-trigger.md) | Pipeline jalan otomatis tiap `git push` (Tekton Triggers + git hook) | ~40 menit |

## Peta besar dalam satu gambar

```
                    ┌─────────────────────────────────────────────┐
     Anda           │  git commit + git push                      │
       │            └──────────────────┬──────────────────────────┘
       │                               ▼
       │                         ┌──────────┐
       │                         │  GitHub  │  kode sumber
       │                         └────┬─────┘
       │                              │ (1) clone
       ▼                              ▼
  kubectl create -f  ──────►  ┌───────────────────┐
  pipelinerun.yaml            │   TEKTON          │
  (atau otomatis dari         │                   │
   git push — lihat bab 8)    │                   │
                              │   namespace cicd  │
                              │                   │
                              │ (2) test backend  │
                              │ (3) test frontend │
                              │ (4) build image   │──(5) push──► ┌────────────┐
                              │ (6) deploy        │              │ Docker Hub │
                              └─────────┬─────────┘              └──────┬─────┘
                                        │ (7) kubectl apply             │
                                        ▼                               │
                              ┌───────────────────┐                     │
                              │  KUBERNETES       │◄────(8) pull image──┘
                              │  namespace dev    │
                              │                   │
                              │  pod backend      │
                              │  pod frontend     │
                              └─────────┬─────────┘
                                        │
                                        ▼
                              http://localhost:8090
```

Delapan langkah itu yang akan dibahas satu per satu.

## Lingkungan yang dipakai dokumentasi ini

Semua contoh sudah diuji di mesin ini:

| Komponen | Versi |
|---|---|
| Windows | 11 Pro |
| Docker Desktop | Engine 29.6.1 |
| Kubernetes | v1.36.1 (bawaan Docker Desktop, **bukan** Minikube) |
| Tekton Pipeline | v1.6.0 |
| Tekton CLI (`tkn`) | 0.46.0 |
| Tekton Dashboard | v0.63.1 |
| Go | 1.27 (lewat container, tidak terpasang di Windows) |
| Node.js | v24.11.0 |

> **Penting:** cluster Anda adalah Kubernetes bawaan **Docker Desktop**. Banyak
> tutorial di internet memakai **Minikube**, dan beberapa perintahnya
> (`minikube service`, `minikube ip`) **tidak berlaku** di sini. Perbedaan yang
> berdampak dijelaskan di bab 2 dan bab 5.

## Aplikasi yang di-deploy

Aplikasi "Data Master Karyawan" — sederhana, supaya fokusnya ke CI/CD:

- **Backend**: Go + Echo, membaca `data/data_master_karyawan.csv`, menyajikan `/api/data` dan `/api/health`.
- **Frontend**: Vue 3, tabel dengan pencarian dan filter, di-build statis lalu disajikan nginx.
- **Tidak ada database.** Sumber data hanya satu file CSV berisi 50 baris.
