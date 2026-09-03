Yang perlu Anda lakukan

```powershell
git add .
git commit -m "Set cache headers on frontend, document deploy verification"
git push origin main
```

Setelah itu, cara memastikan sebuah perubahan sudah benar-benar mendarat — dua baris ini harus cocok:

```powershell
git rev-parse --short HEAD
kubectl get deploy employee-frontend -n dev -o jsonpath='{.spec.template.spec.containers[0].image}'
```

```powershell
 Script pengecek
.\cek.cmd            cek sekali
.\cek.cmd -Watch     pantau tiap 5 detik sampai selesai


Kalau cocok tapi browser masih lama: **Ctrl+Shift+R**.
