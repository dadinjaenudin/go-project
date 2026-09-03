import { describe, it, expect, vi, beforeEach } from "vitest";
import { mount, flushPromises } from "@vue/test-utils";
import axios from "axios";

import MyComponent from "../myComponent.vue";

vi.mock("axios");

const SAMPEL = [
  {
    NP: "P2016001",
    Nama: "Bambang Wijaya",
    "Unit Kerja": "Pemasaran & Penjualan",
    Jabatan: "Manager",
    Gaji: "11900000",
    Umur: "39",
    "Jenis Kelamin": "Laki-laki",
  },
  {
    NP: "P2023002",
    Nama: "Siti Rahayu",
    "Unit Kerja": "Teknologi Informasi",
    Jabatan: "Staff",
    Gaji: "7500000",
    Umur: "28",
    "Jenis Kelamin": "Perempuan",
  },
  {
    NP: "P2019003",
    Nama: "Agus Nugroho",
    "Unit Kerja": "Teknologi Informasi",
    Jabatan: "VP / Head of Department",
    Gaji: "25700000",
    Umur: "41",
    "Jenis Kelamin": "Laki-laki",
  },
];

// Baris data saja, tanpa baris "Data tidak ditemukan".
const barisData = (wrapper) =>
  wrapper.findAll("tbody tr").filter((tr) => tr.find("td.empty").exists() === false);

const pasangResponse = (rows) => {
  axios.get.mockResolvedValue({ data: { data: rows } });
};

const mountSiap = async () => {
  const wrapper = mount(MyComponent);
  await flushPromises();
  return wrapper;
};

beforeEach(() => {
  vi.clearAllMocks();
});

describe("myComponent", () => {
  it("memanggil API lewat path relatif, bukan URL absolut", async () => {
    pasangResponse(SAMPEL);
    await mountSiap();

    // URL absolut ke localhost:8888 akan gagal di Kubernetes; path relatif
    // ditangani proxy Vite saat dev dan nginx saat produksi.
    expect(axios.get).toHaveBeenCalledWith("/api/data");
  });

  it("merender satu baris tabel per karyawan", async () => {
    pasangResponse(SAMPEL);
    const wrapper = await mountSiap();

    expect(barisData(wrapper)).toHaveLength(3);
    expect(wrapper.text()).toContain("Bambang Wijaya");
  });

  it("menampilkan kolom NP — regresi BOM pada header CSV", async () => {
    pasangResponse(SAMPEL);
    const wrapper = await mountSiap();

    const kolom = barisData(wrapper)[0].findAll("td");

    // Kolom ke-2 (indeks 1) adalah NP. Saat header CSV masih membawa UTF-8 BOM,
    // kuncinya menjadi "﻿NP" dan sel ini kosong.
    expect(kolom[1].text()).toBe("P2016001");
  });

  it("memformat gaji sebagai rupiah", async () => {
    pasangResponse(SAMPEL);
    const wrapper = await mountSiap();

    const gaji = barisData(wrapper)[0].findAll("td")[5].text();

    expect(gaji.replace(/\s| /g, "")).toBe("Rp11.900.000");
  });

  it("mengembalikan nilai apa adanya bila gaji bukan angka", async () => {
    pasangResponse([{ ...SAMPEL[0], Gaji: "-" }]);
    const wrapper = await mountSiap();

    expect(barisData(wrapper)[0].findAll("td")[5].text()).toBe("-");
  });

  it("menyaring berdasarkan kata kunci di kolom mana pun", async () => {
    pasangResponse(SAMPEL);
    const wrapper = await mountSiap();

    await wrapper.find("input.search-input").setValue("teknologi informasi");

    expect(barisData(wrapper)).toHaveLength(2);
  });

  it("pencarian tidak membedakan huruf besar-kecil dan mengabaikan spasi tepi", async () => {
    pasangResponse(SAMPEL);
    const wrapper = await mountSiap();

    await wrapper.find("input.search-input").setValue("  SITI  ");

    const baris = barisData(wrapper);
    expect(baris).toHaveLength(1);
    expect(baris[0].text()).toContain("Siti Rahayu");
  });

  it("menyaring berdasarkan jenis kelamin", async () => {
    pasangResponse(SAMPEL);
    const wrapper = await mountSiap();

    await wrapper.find("select.filter").setValue("Perempuan");

    expect(barisData(wrapper)).toHaveLength(1);
  });

  it("menggabungkan filter pencarian dan jenis kelamin", async () => {
    pasangResponse(SAMPEL);
    const wrapper = await mountSiap();

    await wrapper.find("input.search-input").setValue("Teknologi Informasi");
    await wrapper.find("select.filter").setValue("Laki-laki");

    const baris = barisData(wrapper);
    expect(baris).toHaveLength(1);
    expect(baris[0].text()).toContain("Agus Nugroho");
  });

  it("menghitung total laki-laki dan perempuan dari seluruh data, bukan hasil filter", async () => {
    pasangResponse(SAMPEL);
    const wrapper = await mountSiap();

    await wrapper.find("select.filter").setValue("Perempuan");

    const angka = wrapper.findAll(".stat-card strong").map((el) => el.text());

    // [total tampil (ikut filter), laki-laki, perempuan]
    expect(angka[1]).toBe("2");
    expect(angka[2]).toBe("1");
  });

  it("menampilkan baris kosong bila tidak ada yang cocok", async () => {
    pasangResponse(SAMPEL);
    const wrapper = await mountSiap();

    await wrapper.find("input.search-input").setValue("tidak ada karyawan ini");

    expect(barisData(wrapper)).toHaveLength(0);
    expect(wrapper.find("td.empty").text()).toContain("Data tidak ditemukan");
  });

  it("menampilkan pesan error bila backend tidak bisa dihubungi", async () => {
    vi.spyOn(console, "error").mockImplementation(() => {});
    axios.get.mockRejectedValue(new Error("ECONNREFUSED"));

    const wrapper = await mountSiap();

    expect(wrapper.find(".error").text()).toContain("Gagal mengambil data");
    expect(barisData(wrapper)).toHaveLength(0);
  });

  it("menangani response tanpa properti data tanpa melempar error", async () => {
    axios.get.mockResolvedValue({ data: {} });
    const wrapper = await mountSiap();

    expect(barisData(wrapper)).toHaveLength(0);
    expect(wrapper.find(".error").exists()).toBe(false);
  });
});
