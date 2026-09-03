package main

import (
	"encoding/csv"
	// "encoding/json"
	"fmt"
	"net/http"
	"os"
	"strings"

	"github.com/labstack/echo/v4"
	"github.com/labstack/echo/v4/middleware"
)

type CSVData struct {
	Data []map[string]string `json:"data"`
}

func readCSV(filename string) ([]map[string]string, error) {
	file, err := os.Open(filename)
	if err != nil {
		return nil, err
	}
	defer file.Close()

	reader := csv.NewReader(file)

	// Membaca header
	headers, err := reader.Read()
	if err != nil {
		return nil, err
	}

	// File CSV yang ditulis Excel/Notepad diawali UTF-8 BOM. encoding/csv tidak
	// membuangnya, sehingga tanpa baris ini kunci kolom pertama menjadi "\ufeffNP"
	// dan frontend yang membaca employee.NP mendapat undefined.
	if len(headers) > 0 {
		headers[0] = strings.TrimPrefix(headers[0], "\ufeff")
	}

	var result []map[string]string

	for {
		record, err := reader.Read()

		if err != nil {
			if err.Error() == "EOF" {
				break
			}
			return nil, err
		}

		row := make(map[string]string)

		for i, value := range record {
			if i < len(headers) {
				row[headers[i]] = value
			}
		}

		result = append(result, row)
	}

	return result, nil
}

func main() {
	e := echo.New()

	// Middleware
	e.Use(middleware.Logger())
	e.Use(middleware.Recover())
	e.Use(middleware.CORS())

	// Fallback static bila binary dijalankan sendirian setelah "npm run build".
	// Di Kubernetes frontend disajikan image nginx terpisah, jadi folder ini
	// memang tidak ada di dalam image backend dan route-nya cukup 404.
	// Harus "ui/dist", bukan "ui" — "ui" akan mengekspos source dan node_modules.
	e.Static("/", "ui/dist")

	// API membaca CSV
	e.GET("/api/data", func(c echo.Context) error {

		data, err := readCSV("data/data_master_karyawan.csv")
		if err != nil {
			return c.JSON(http.StatusInternalServerError, map[string]interface{}{
				"success": false,
				"error":   err.Error(),
			})
		}

		return c.JSON(http.StatusOK, CSVData{
			Data: data,
		})
	})

	// API health check
	e.GET("/api/health", func(c echo.Context) error {
		return c.JSON(http.StatusOK, map[string]string{
			"status": "OK",
		})
	})

	fmt.Println("Server running at http://localhost:8888")

	e.Logger.Fatal(e.Start(":8888"))
}