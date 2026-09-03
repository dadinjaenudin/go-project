<template>
  <div class="app">
    <header class="header">
      <div>
        <h1>Data Master Karyawan PROD 1</h1>
        <p>Data karyawan dari Web Service Golang</p>
      </div>

      <button class="refresh-button" @click="loadData" :disabled="loading">
        {{ loading ? 'Loading...' : 'Refresh Data' }}
      </button>
    </header>

    <main class="container">

      <!-- Statistik -->
      <div class="stats">
        <div class="stat-card">
          <span class="stat-title">Total Karyawan</span>
          <strong>{{ filteredData.length }}</strong>
        </div>

        <div class="stat-card">
          <span class="stat-title">Laki-laki</span>
          <strong>{{ totalMale }}</strong>
        </div>

        <div class="stat-card">
          <span class="stat-title">Perempuan</span>
          <strong>{{ totalFemale }}</strong>
        </div>
      </div>

      <!-- Error -->
      <div v-if="error" class="error">
        {{ error }}
      </div>

      <!-- Search -->
      <div class="toolbar">
        <input
          v-model="search"
          type="text"
          placeholder="Cari nama, NP, unit kerja, jabatan..."
          class="search-input"
        />

        <select v-model="genderFilter" class="filter">
          <option value="">Semua Jenis Kelamin</option>
          <option value="Laki-laki">Laki-laki</option>
          <option value="Perempuan">Perempuan</option>
        </select>
      </div>

      <!-- Loading -->
      <div v-if="loading" class="loading">
        Mengambil data dari web service...
      </div>

      <!-- Table -->
      <div v-else class="table-wrapper">

        <table>
          <thead>
            <tr>
              <th>No</th>
              <th>NP</th>
              <th>Nama</th>
              <th>Unit Kerja</th>
              <th>Jabatan</th>
              <th>Gaji</th>
              <th>Umur</th>
              <th>Jenis Kelamin</th>
            </tr>
          </thead>

          <tbody>
            <tr
              v-for="(employee, index) in filteredData"
              :key="employee.NP"
            >
              <td>{{ index + 1 }}</td>
              <td>{{ employee.NP }}</td>
              <td class="name">{{ employee.Nama }}</td>
              <td>{{ employee["Unit Kerja"] }}</td>
              <td>{{ employee.Jabatan }}</td>
              <td>{{ formatRupiah(employee.Gaji) }}</td>
              <td>{{ employee.Umur }}</td>

              <td>
                <span
                  class="gender"
                  :class="employee['Jenis Kelamin'] === 'Laki-laki'
                    ? 'male'
                    : 'female'"
                >
                  {{ employee["Jenis Kelamin"] }}
                </span>
              </td>
            </tr>

            <tr v-if="filteredData.length === 0">
              <td colspan="8" class="empty">
                Data tidak ditemukan
              </td>
            </tr>
          </tbody>
        </table>

      </div>

      <div class="footer">
        Menampilkan {{ filteredData.length }} dari {{ data.length }} data
      </div>

    </main>
  </div>
</template>

<script>
import axios from "axios";
import { computed, onMounted, ref } from "vue";

export default {
  setup() {
    const data = ref([]);
    const search = ref("");
    const genderFilter = ref("");
    const loading = ref(false);
    const error = ref("");

    const loadData = async () => {
      loading.value = true;
      error.value = "";

      try {
        const response = await axios.get("/api/data");

        data.value = response.data.data || [];

      } catch (err) {
        console.error(err);

        error.value =
          "Gagal mengambil data dari web service Golang.";
      } finally {
        loading.value = false;
      }
    };

    const filteredData = computed(() => {
      const keyword = search.value.toLowerCase().trim();

      return data.value.filter((employee) => {
        const matchesSearch =
          !keyword ||
          Object.values(employee).some((value) =>
            String(value)
              .toLowerCase()
              .includes(keyword)
          );

        const matchesGender =
          !genderFilter.value ||
          employee["Jenis Kelamin"] === genderFilter.value;

        return matchesSearch && matchesGender;
      });
    });

    const totalMale = computed(() => {
      return data.value.filter(
        (employee) => employee["Jenis Kelamin"] === "Laki-laki"
      ).length;
    });

    const totalFemale = computed(() => {
      return data.value.filter(
        (employee) => employee["Jenis Kelamin"] === "Perempuan"
      ).length;
    });

    const formatRupiah = (value) => {
      const number = Number(value);

      if (isNaN(number)) {
        return value;
      }

      return new Intl.NumberFormat("id-ID", {
        style: "currency",
        currency: "IDR",
        maximumFractionDigits: 0,
      }).format(number);
    };

    onMounted(() => {
      loadData();
    });

    return {
      data,
      search,
      genderFilter,
      loading,
      error,
      filteredData,
      totalMale,
      totalFemale,
      loadData,
      formatRupiah,
    };
  },
};
</script>

<style>
* {
  box-sizing: border-box;
}

body {
  margin: 0;
  font-family:
    Inter,
    Arial,
    Helvetica,
    sans-serif;
  background: #f4f6f9;
  color: #1f2937;
}

.app {
  min-height: 100vh;
}

.header {
  background: #1e3a8a;
  color: white;
  padding: 25px 40px;
  display: flex;
  justify-content: space-between;
  align-items: center;
}

.header h1 {
  margin: 0 0 5px;
  font-size: 28px;
  color: white
}

.header p {
  margin: 0;
  opacity: 0.85;
}

.container {
  padding: 30px 40px;
  max-width: 1600px;
  margin: auto;
}

/* Statistics */

.stats {
  display: grid;
  grid-template-columns: repeat(3, 1fr);
  gap: 20px;
  margin-bottom: 25px;
}

.stat-card {
  background: white;
  border-radius: 12px;
  padding: 22px;
  box-shadow: 0 2px 10px rgba(0, 0, 0, 0.06);
}

.stat-title {
  display: block;
  color: #6b7280;
  font-size: 14px;
  margin-bottom: 8px;
}

.stat-card strong {
  font-size: 28px;
  color: #1e3a8a;
}

/* Toolbar */

.toolbar {
  display: flex;
  gap: 15px;
  margin-bottom: 20px;
}

.search-input,
.filter {
  background: white;
  border: 1px solid #d1d5db;
  border-radius: 8px;
  padding: 12px 15px;
  font-size: 14px;
}

.search-input {
  flex: 1;
}

.filter {
  min-width: 220px;
}

.search-input:focus,
.filter:focus {
  outline: none;
  border-color: #2563eb;
}

/* Button */

.refresh-button {
  background: white;
  color: #1e3a8a;
  border: none;
  border-radius: 8px;
  padding: 11px 18px;
  cursor: pointer;
  font-weight: 600;
}

.refresh-button:hover {
  background: #eff6ff;
}

.refresh-button:disabled {
  opacity: 0.6;
  cursor: not-allowed;
}

/* Table */

.table-wrapper {
  background: white;
  border-radius: 12px;
  overflow-x: auto;
  box-shadow: 0 2px 10px rgba(0, 0, 0, 0.06);
}

table {
  width: 100%;
  border-collapse: collapse;
  min-width: 1000px;
}

thead {
  background: #f1f5f9;
}

th {
  text-align: left;
  padding: 14px 16px;
  font-size: 13px;
  color: #475569;
  border-bottom: 1px solid #e2e8f0;
}

td {
  padding: 14px 16px;
  border-bottom: 1px solid #f1f5f9;
  font-size: 14px;
}

tbody tr:hover {
  background: #f8fafc;
}

.name {
  font-weight: 600;
}

/* Gender */

.gender {
  display: inline-block;
  padding: 5px 10px;
  border-radius: 20px;
  font-size: 12px;
  font-weight: 600;
}

.male {
  background: #dbeafe;
  color: #1d4ed8;
}

.female {
  background: #fce7f3;
  color: #be185d;
}

/* Loading */

.loading {
  background: white;
  padding: 40px;
  text-align: center;
  border-radius: 12px;
  color: #64748b;
}

/* Error */

.error {
  background: #fee2e2;
  color: #b91c1c;
  padding: 15px 20px;
  border-radius: 8px;
  margin-bottom: 20px;
}

/* Empty */

.empty {
  text-align: center;
  padding: 40px;
  color: #64748b;
}

/* Footer */

.footer {
  margin-top: 15px;
  color: #64748b;
  font-size: 13px;
}

/* Responsive */

@media (max-width: 768px) {
  .header {
    padding: 20px;
    flex-direction: column;
    align-items: flex-start;
    gap: 15px;
  }

  .container {
    padding: 20px;
  }

  .stats {
    grid-template-columns: 1fr;
  }

  .toolbar {
    flex-direction: column;
  }

  .filter {
    width: 100%;
  }
}
</style>
