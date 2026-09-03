package main

import (
	"os"
	"path/filepath"
	"testing"
)

// tulisCSV membuat file CSV sementara dan mengembalikan path-nya.
func tulisCSV(t *testing.T, isi string) string {
	t.Helper()

	path := filepath.Join(t.TempDir(), "data.csv")

	if err := os.WriteFile(path, []byte(isi), 0o600); err != nil {
		t.Fatalf("gagal menulis CSV sementara: %v", err)
	}

	return path
}

func TestReadCSVMemetakanHeaderKeKolom(t *testing.T) {
	path := tulisCSV(t, "NP,Nama,Unit Kerja,Gaji\n"+
		"P2016001,Bambang Wijaya,Pemasaran & Penjualan,11900000\n"+
		"P2023002,Agus Nugroho,Teknologi Informasi,25700000\n")

	rows, err := readCSV(path)
	if err != nil {
		t.Fatalf("readCSV mengembalikan error: %v", err)
	}

	if len(rows) != 2 {
		t.Fatalf("jumlah baris = %d, harusnya 2", len(rows))
	}

	// Header dengan spasi harus dipakai apa adanya sebagai kunci, karena
	// template Vue mengaksesnya lewat employee["Unit Kerja"].
	want := map[string]string{
		"NP":         "P2016001",
		"Nama":       "Bambang Wijaya",
		"Unit Kerja": "Pemasaran & Penjualan",
		"Gaji":       "11900000",
	}

	for kolom, nilai := range want {
		if got := rows[0][kolom]; got != nilai {
			t.Errorf("rows[0][%q] = %q, harusnya %q", kolom, got, nilai)
		}
	}
}

// Regresi: data/data_master_karyawan.csv diawali UTF-8 BOM. Tanpa penanganan,
// kunci kolom pertama menjadi "\ufeffNP" sehingga employee.NP di frontend
// bernilai undefined dan kolom NP tampil kosong.
func TestReadCSVMembuangBOMDariHeaderPertama(t *testing.T) {
	path := tulisCSV(t, "\ufeffNP,Nama\nP2016001,Bambang Wijaya\n")

	rows, err := readCSV(path)
	if err != nil {
		t.Fatalf("readCSV mengembalikan error: %v", err)
	}

	if got, ok := rows[0]["NP"]; !ok || got != "P2016001" {
		t.Errorf(`rows[0]["NP"] = %q (ada: %v), harusnya "P2016001"`, got, ok)
	}

	if _, ok := rows[0]["\ufeffNP"]; ok {
		t.Error(`kunci \ufeffNP masih ada — BOM tidak dibuang`)
	}
}

func TestReadCSVFileTidakAda(t *testing.T) {
	if _, err := readCSV(filepath.Join(t.TempDir(), "tidak-ada.csv")); err == nil {
		t.Error("readCSV harusnya error untuk file yang tidak ada")
	}
}

func TestReadCSVFileKosong(t *testing.T) {
	if _, err := readCSV(tulisCSV(t, "")); err == nil {
		t.Error("readCSV harusnya error untuk file kosong (header tidak terbaca)")
	}
}

// File CSV asli harus tetap terbaca dan kolom yang dipakai frontend harus ada.
func TestReadCSVDataAsli(t *testing.T) {
	rows, err := readCSV("data/data_master_karyawan.csv")
	if err != nil {
		t.Fatalf("readCSV pada data asli error: %v", err)
	}

	if len(rows) == 0 {
		t.Fatal("data asli terbaca 0 baris")
	}

	for _, kolom := range []string{"NP", "Nama", "Unit Kerja", "Jabatan", "Gaji", "Umur", "Jenis Kelamin"} {
		if _, ok := rows[0][kolom]; !ok {
			t.Errorf("kolom %q tidak ada di data asli — template Vue akan menampilkan kosong", kolom)
		}
	}
}
