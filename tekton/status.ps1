# Cek status deploy: dari commit di laptop sampai aplikasi yang jalan.
#
#   powershell -ExecutionPolicy Bypass -File tekton\status.ps1
#   powershell -ExecutionPolicy Bypass -File tekton\status.ps1 -Watch
#
# -Watch  : perbarui tiap 5 detik sampai pipeline selesai
# -Fetch  : ambil dulu keadaan terbaru dari GitHub (butuh jaringan, lebih lambat)

[CmdletBinding()]
param(
    [switch]$Watch,
    [switch]$Fetch
)

$ErrorActionPreference = "Continue"
$ProgressPreference    = "SilentlyContinue"

Set-Location (Join-Path $PSScriptRoot "..")

$NS_CICD = "cicd"
$NS_APP  = "dev"
$APP_URL = "http://localhost:8090"

# Urutan task sesuai pipeline, supaya tampilannya runtut bukan alfabetis.
$URUTAN_TASK = @("clone", "backend-test", "frontend-test", "backend-build", "frontend-build", "deploy")

function Tulis-Judul($teks) {
    Write-Host ""
    Write-Host "  $teks" -ForegroundColor Cyan
    Write-Host "  $('-' * 62)" -ForegroundColor DarkGray
}

function Warna-Status($status) {
    switch ($status) {
        "Succeeded" { "Green" }
        "Running"   { "Yellow" }
        "Failed"    { "Red" }
        "Pending"   { "DarkGray" }
        default     { "DarkGray" }
    }
}

function Ikon($status) {
    switch ($status) {
        "Succeeded" { "[ok]  " }
        "Running"   { "[jalan]" }
        "Failed"    { "[GAGAL]" }
        "Pending"   { "[tunggu]" }
        default     { "[-]   " }
    }
}

function Ambil-Status {

    $hasil = [ordered]@{}

    # ---------- GIT ----------
    if ($Fetch) { git fetch origin --quiet 2>$null }

    $hasil.HeadFull  = (git rev-parse HEAD 2>$null)
    $hasil.Head      = (git rev-parse --short HEAD 2>$null)
    $hasil.Origin    = (git rev-parse --short origin/main 2>$null)
    $hasil.PesanHead = (git log -1 --format=%s 2>$null)

    $belumCommit = @(git status --porcelain 2>$null)
    $hasil.BelumCommit = $belumCommit.Count

    $belumPush = @(git log --oneline origin/main..HEAD 2>$null)
    $hasil.BelumPush = $belumPush.Count

    # ---------- LOG HOOK ----------
    $logPath = ".git/tekton-trigger.log"
    if (Test-Path $logPath) {
        $baris = @(Get-Content $logPath | Where-Object { $_ -match '^\d{4}-' })
        if ($baris.Count -gt 0) { $hasil.HookTerakhir = $baris[-1] }
    }

    # ---------- PIPELINE ----------
    $prRaw = kubectl get pipelinerun -n $NS_CICD -o json 2>$null | Out-String

    if ($prRaw.Trim().Length -gt 0) {
        $prAll = ($prRaw | ConvertFrom-Json).items

        if ($prAll -and $prAll.Count -gt 0) {
            $pr = $prAll | Sort-Object { $_.metadata.creationTimestamp } | Select-Object -Last 1

            $hasil.RunNama   = $pr.metadata.name
            $hasil.RunCommit = $pr.metadata.labels.'git-commit'
            $hasil.RunStatus = $pr.status.conditions[0].reason
            $hasil.RunMulai  = $pr.status.startTime
            $hasil.RunSelesai= $pr.status.completionTime

            if ($pr.status.startTime) {
                $akhir = if ($pr.status.completionTime) { [datetime]$pr.status.completionTime } else { (Get-Date).ToUniversalTime() }
                $hasil.RunDurasi = [int]($akhir - [datetime]$pr.status.startTime).TotalSeconds
            }

            # TaskRun milik run ini
            $trRaw = kubectl get taskrun -n $NS_CICD -o json 2>$null | Out-String
            if ($trRaw.Trim().Length -gt 0) {
                $trAll = ($trRaw | ConvertFrom-Json).items
                $milik = @($trAll | Where-Object { $_.metadata.labels.'tekton.dev/pipelineRun' -eq $pr.metadata.name })

                $tasks = [ordered]@{}
                foreach ($nama in $URUTAN_TASK) {
                    $tr = $milik | Where-Object { $_.metadata.labels.'tekton.dev/pipelineTask' -eq $nama }
                    if ($tr) {
                        $st = $tr.status.conditions[0].reason
                        $dur = ""
                        if ($tr.status.startTime) {
                            $a = if ($tr.status.completionTime) { [datetime]$tr.status.completionTime } else { (Get-Date).ToUniversalTime() }
                            $dur = "$([int]($a - [datetime]$tr.status.startTime).TotalSeconds)s"
                        }
                        $tasks[$nama] = @{ Status = $st; Durasi = $dur; Nama = $tr.metadata.name }
                    } else {
                        $tasks[$nama] = @{ Status = "-"; Durasi = ""; Nama = "" }
                    }
                }
                $hasil.Tasks = $tasks
            }
        }
    }

    # ---------- DEPLOY ----------
    $depRaw = kubectl get deploy -n $NS_APP -o json 2>$null | Out-String
    if ($depRaw.Trim().Length -gt 0) {
        $deps = ($depRaw | ConvertFrom-Json).items
        $daftar = @()
        foreach ($d in $deps) {
            $daftar += [pscustomobject]@{
                Nama  = $d.metadata.name
                Image = $d.spec.template.spec.containers[0].image
                Siap  = "$([int]$d.status.readyReplicas)/$([int]$d.status.replicas)"
            }
        }
        $hasil.Deploy = $daftar
    }

    # ---------- APLIKASI ----------
    $kode = (curl.exe -s -o NUL -w "%{http_code}" -m 5 "$APP_URL/" 2>$null)
    $hasil.HttpRoot = $kode
    $kodeApi = (curl.exe -s -o NUL -w "%{http_code}" -m 5 "$APP_URL/api/health" 2>$null)
    $hasil.HttpApi = $kodeApi

    return $hasil
}

function Tampilkan($s) {

    Clear-Host
    Write-Host ""
    Write-Host "  STATUS DEPLOY  -  $(Get-Date -Format 'HH:mm:ss')" -ForegroundColor White

    # ---------- 1. GIT ----------
    Tulis-Judul "1. GIT"

    Write-Host ("    commit lokal   : {0}  {1}" -f $s.Head, $s.PesanHead)
    Write-Host ("    di GitHub      : {0}" -f $s.Origin)

    if ($s.BelumCommit -gt 0) {
        Write-Host ("    belum commit   : {0} file" -f $s.BelumCommit) -ForegroundColor Yellow
    } else {
        Write-Host "    belum commit   : tidak ada" -ForegroundColor Green
    }

    if ($s.BelumPush -gt 0) {
        Write-Host ("    belum push     : {0} commit" -f $s.BelumPush) -ForegroundColor Yellow
    } else {
        Write-Host "    belum push     : tidak ada" -ForegroundColor Green
    }

    # ---------- 2. TRIGGER ----------
    Tulis-Judul "2. TRIGGER (hook pre-push)"

    if ($s.HookTerakhir) {
        $warna = if ($s.HookTerakhir -match "GAGAL") { "Red" } else { "Gray" }
        Write-Host ("    {0}" -f $s.HookTerakhir) -ForegroundColor $warna
    } else {
        Write-Host "    belum pernah tercatat" -ForegroundColor DarkGray
    }

    # ---------- 3. PIPELINE ----------
    Tulis-Judul "3. PIPELINE"

    if (-not $s.RunNama) {
        Write-Host "    belum ada PipelineRun" -ForegroundColor DarkGray
    } else {
        $cocokCommit = ($s.RunCommit -and $s.HeadFull -and $s.RunCommit -eq $s.HeadFull)

        Write-Host ("    run     : {0}" -f $s.RunNama)

        if ($s.RunCommit) {
            $tandai = if ($cocokCommit) { "  <- commit Anda" } else { "  <- BUKAN commit terakhir Anda" }
            $w = if ($cocokCommit) { "Green" } else { "Yellow" }
            Write-Host ("    commit  : {0}{1}" -f $s.RunCommit.Substring(0, 7), $tandai) -ForegroundColor $w
        }

        $durTeks = if ($s.RunDurasi) { " ({0}s)" -f $s.RunDurasi } else { "" }
        Write-Host ("    status  : {0}{1}" -f $s.RunStatus, $durTeks) -ForegroundColor (Warna-Status $s.RunStatus)
        Write-Host ""

        if ($s.Tasks) {
            foreach ($nama in $s.Tasks.Keys) {
                $t = $s.Tasks[$nama]
                Write-Host ("      {0} {1,-16} {2}" -f (Ikon $t.Status), $nama, $t.Durasi) -ForegroundColor (Warna-Status $t.Status)
            }
        }
    }

    # ---------- 4. DEPLOY ----------
    Tulis-Judul "4. YANG JALAN DI KUBERNETES"

    if (-not $s.Deploy) {
        Write-Host "    tidak ada deployment di namespace $NS_APP" -ForegroundColor DarkGray
    } else {
        foreach ($d in $s.Deploy) {
            $tagJalan = ($d.Image -split ":")[-1]
            $sama = ($tagJalan -eq $s.Head)
            $w = if ($sama) { "Green" } else { "Yellow" }
            $tandai = if ($sama) { "" } else { "   (commit Anda: $($s.Head))" }
            Write-Host ("    {0,-20} {1,-34} {2}{3}" -f $d.Nama, $d.Image, $d.Siap, $tandai) -ForegroundColor $w
        }
    }

    # ---------- 5. APLIKASI ----------
    Tulis-Judul "5. APLIKASI"

    $wRoot = if ($s.HttpRoot -eq "200") { "Green" } else { "Red" }
    $wApi  = if ($s.HttpApi  -eq "200") { "Green" } else { "Red" }
    Write-Host ("    {0,-34} HTTP {1}" -f "$APP_URL/", $s.HttpRoot) -ForegroundColor $wRoot
    Write-Host ("    {0,-34} HTTP {1}" -f "$APP_URL/api/health", $s.HttpApi) -ForegroundColor $wApi

    # ---------- KESIMPULAN ----------
    Tulis-Judul "KESIMPULAN"

    $tagJalan = ""
    if ($s.Deploy -and $s.Deploy.Count -gt 0) { $tagJalan = ($s.Deploy[0].Image -split ":")[-1] }

    $semuaSiap = $true
    if ($s.Deploy) {
        foreach ($d in $s.Deploy) {
            $bagian = $d.Siap -split "/"
            if ($bagian[0] -ne $bagian[1] -or $bagian[0] -eq "0") { $semuaSiap = $false }
        }
    } else { $semuaSiap = $false }

    # Pertanyaan utamanya: APAKAH COMMIT TERAKHIR SUDAH MENDARAT.
    # Perubahan yang belum di-commit adalah pekerjaan BARU, bukan tanda deploy
    # gagal -- itu dilaporkan terpisah di bawah supaya tidak rancu.

    if ($s.BelumPush -gt 0) {
        Write-Host "    BELUM SELESAI - commit belum di-push, pipeline membaca dari GitHub." -ForegroundColor Yellow
        Write-Host "      git push origin main" -ForegroundColor DarkGray
    }
    elseif ($s.RunStatus -eq "Running") {
        $tahap = "?"
        if ($s.Tasks) {
            foreach ($n in $s.Tasks.Keys) { if ($s.Tasks[$n].Status -eq "Running") { $tahap = $n } }
        }
        Write-Host ("    SEDANG BERJALAN - tahap '{0}', sudah {1}s dari perkiraan ~180s." -f $tahap, $s.RunDurasi) -ForegroundColor Yellow
        Write-Host "      Tunggu sampai selesai sebelum menilai. Pakai -Watch untuk memantau." -ForegroundColor DarkGray
    }
    elseif ($s.RunStatus -eq "Failed" -or $s.RunStatus -eq "PipelineValidationFailed") {
        $gagal = @()
        if ($s.Tasks) {
            foreach ($n in $s.Tasks.Keys) { if ($s.Tasks[$n].Status -eq "Failed") { $gagal += $s.Tasks[$n].Nama } }
        }
        Write-Host ("    GAGAL - {0}" -f $s.RunStatus) -ForegroundColor Red
        foreach ($g in $gagal) {
            Write-Host ("      tkn taskrun logs -n cicd {0}" -f $g) -ForegroundColor DarkGray
        }
        if ($gagal.Count -eq 0) {
            Write-Host ("      kubectl describe pipelinerun -n cicd {0}" -f $s.RunNama) -ForegroundColor DarkGray
        }
    }
    elseif ($tagJalan -ne $s.Head) {
        Write-Host ("    BELUM MENDARAT - yang jalan tag '{0}', commit Anda '{1}'." -f $tagJalan, $s.Head) -ForegroundColor Yellow
        Write-Host "      Pipeline untuk commit ini mungkin belum pernah dijalankan." -ForegroundColor DarkGray
        Write-Host "      kubectl create -f tekton\pipelinerun.yaml" -ForegroundColor DarkGray
    }
    elseif (-not $semuaSiap) {
        Write-Host "    HAMPIR - image sudah benar, tapi pod belum semuanya siap." -ForegroundColor Yellow
        Write-Host "      kubectl get pods -n dev" -ForegroundColor DarkGray
    }
    elseif ($s.HttpRoot -ne "200") {
        Write-Host "    MASALAH AKSES - pod siap tapi $APP_URL tidak menjawab." -ForegroundColor Red
        Write-Host "      kubectl get svc -n dev; netstat -ano | Select-String ':8090'" -ForegroundColor DarkGray
    }
    else {
        Write-Host ("    BERHASIL - commit {0} sudah jalan dan aplikasi menjawab." -f $s.Head) -ForegroundColor Green
        Write-Host "      Kalau browser masih menampilkan versi lama: Ctrl+Shift+R" -ForegroundColor DarkGray
    }

    # Dilaporkan terpisah: ini soal pekerjaan berikutnya, bukan status deploy.
    if ($s.BelumCommit -gt 0) {
        Write-Host ""
        Write-Host ("    Catatan: ada {0} file berubah yang belum di-commit." -f $s.BelumCommit) -ForegroundColor Yellow
        Write-Host "      Perubahan itu belum ikut ter-deploy. Untuk mengirimnya:" -ForegroundColor DarkGray
        Write-Host "      git add -A; git commit -m 'pesan'; git push origin main" -ForegroundColor DarkGray
    }

    Write-Host ""
}

# --------------------------------------------------------------------------
if ($Watch) {
    while ($true) {
        $s = Ambil-Status
        Tampilkan $s
        Write-Host "  (mode -Watch, perbarui tiap 5 detik. Ctrl+C untuk berhenti)" -ForegroundColor DarkGray

        $selesai = ($s.RunStatus -ne "Running" -and $s.RunStatus -ne "Pending" -and $null -ne $s.RunStatus)
        $tagJalan = ""
        if ($s.Deploy -and $s.Deploy.Count -gt 0) { $tagJalan = ($s.Deploy[0].Image -split ":")[-1] }

        if ($selesai -and ($tagJalan -eq $s.Head -or $s.RunStatus -eq "Failed")) {
            Write-Host "  Selesai memantau." -ForegroundColor DarkGray
            break
        }

        Start-Sleep -Seconds 5
    }
} else {
    Tampilkan (Ambil-Status)
}
