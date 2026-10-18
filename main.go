// Piano Tunah: serverar webbappen och lagrar sparade stämningar som
// JSON-filer i DATA_DIR. Inga beroenden utöver standardbiblioteket.
package main

import (
	"context"
	"embed"
	"encoding/json"
	"errors"
	"io"
	"io/fs"
	"log"
	"net"
	"net/http"
	"os"
	"os/signal"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"sync"
	"syscall"
	"time"
)

//go:embed web
var webFS embed.FS

const maxBody = 2 << 20

// Sätts vid bygget: -ldflags "-X main.version=v1.2.3".
var version = "dev"

var idPattern = regexp.MustCompile(`^[A-Za-z0-9-]{1,64}$`)

type store struct {
	dir string
	mu  sync.Mutex
}

type summary struct {
	ID        string `json:"id"`
	Name      string `json:"name"`
	UpdatedAt string `json:"updatedAt"`
}

func (s *store) path(id string) string { return filepath.Join(s.dir, id+".json") }

func (s *store) list(w http.ResponseWriter, _ *http.Request) {
	entries, err := os.ReadDir(s.dir)
	if err != nil {
		httpError(w, err, http.StatusInternalServerError)
		return
	}
	out := []summary{}
	for _, e := range entries {
		id, ok := strings.CutSuffix(e.Name(), ".json")
		if !ok || !idPattern.MatchString(id) {
			continue
		}
		b, err := os.ReadFile(s.path(id))
		if err != nil {
			continue
		}
		var t summary
		if json.Unmarshal(b, &t) != nil {
			continue
		}
		t.ID = id
		out = append(out, t)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].UpdatedAt > out[j].UpdatedAt })
	writeJSON(w, out)
}

func (s *store) get(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	if !idPattern.MatchString(id) {
		http.Error(w, "ogiltigt id", http.StatusBadRequest)
		return
	}
	b, err := os.ReadFile(s.path(id))
	if errors.Is(err, fs.ErrNotExist) {
		http.NotFound(w, r)
		return
	} else if err != nil {
		httpError(w, err, http.StatusInternalServerError)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	w.Write(b)
}

func (s *store) put(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	if !idPattern.MatchString(id) {
		http.Error(w, "ogiltigt id", http.StatusBadRequest)
		return
	}
	body, err := io.ReadAll(http.MaxBytesReader(w, r.Body, maxBody))
	if err != nil {
		http.Error(w, "för stor eller trasig förfrågan", http.StatusRequestEntityTooLarge)
		return
	}
	var doc map[string]any
	if err := json.Unmarshal(body, &doc); err != nil {
		http.Error(w, "ogiltig JSON", http.StatusBadRequest)
		return
	}
	if docID, _ := doc["id"].(string); docID != id {
		http.Error(w, "id i dokumentet stämmer inte med adressen", http.StatusBadRequest)
		return
	}

	s.mu.Lock()
	defer s.mu.Unlock()

	// Optimistisk låsning: klienten skickar revisionen den utgick från. Har
	// någon annan sparat under tiden svarar vi 409 i stället för att skriva över.
	base, _ := doc["rev"].(float64)
	cur, err := s.rev(id)
	if err != nil {
		httpError(w, err, http.StatusInternalServerError)
		return
	}
	if int64(base) != cur {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusConflict)
		json.NewEncoder(w).Encode(map[string]int64{"rev": cur})
		return
	}
	doc["rev"] = cur + 1
	if body, err = json.Marshal(doc); err != nil {
		httpError(w, err, http.StatusInternalServerError)
		return
	}

	tmp, err := os.CreateTemp(s.dir, ".tmp-*")
	if err != nil {
		httpError(w, err, http.StatusInternalServerError)
		return
	}
	defer os.Remove(tmp.Name())
	if _, err := tmp.Write(body); err != nil {
		tmp.Close()
		httpError(w, err, http.StatusInternalServerError)
		return
	}
	if err := tmp.Close(); err != nil {
		httpError(w, err, http.StatusInternalServerError)
		return
	}
	if err := os.Rename(tmp.Name(), s.path(id)); err != nil {
		httpError(w, err, http.StatusInternalServerError)
		return
	}
	writeJSON(w, map[string]int64{"rev": cur + 1})
}

// Sparad revision för id, 0 om stämningen inte finns.
func (s *store) rev(id string) (int64, error) {
	b, err := os.ReadFile(s.path(id))
	if errors.Is(err, fs.ErrNotExist) {
		return 0, nil
	} else if err != nil {
		return 0, err
	}
	var d struct {
		Rev int64 `json:"rev"`
	}
	if err := json.Unmarshal(b, &d); err != nil {
		return 0, err
	}
	return d.Rev, nil
}

func (s *store) del(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	if !idPattern.MatchString(id) {
		http.Error(w, "ogiltigt id", http.StatusBadRequest)
		return
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if err := os.Remove(s.path(id)); err != nil && !errors.Is(err, fs.ErrNotExist) {
		httpError(w, err, http.StatusInternalServerError)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func writeJSON(w http.ResponseWriter, v any) {
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(v)
}

func httpError(w http.ResponseWriter, err error, code int) {
	log.Print(err)
	http.Error(w, http.StatusText(code), code)
}

// Säkerhetsheaders. Mikrofonen tillåts bara för den egna sidan.
func headers(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		h := w.Header()
		h.Set("Content-Security-Policy", "default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' data:; connect-src 'self'; media-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'none'")
		h.Set("Permissions-Policy", "microphone=(self), camera=(), geolocation=()")
		h.Set("X-Content-Type-Options", "nosniff")
		h.Set("Referrer-Policy", "same-origin")
		h.Set("Cache-Control", "no-cache")
		next.ServeHTTP(w, r)
	})
}

func env(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}

func main() {
	addr := env("ADDR", ":8080")

	// `pianotunah healthcheck` används av Docker (scratch-imagen saknar curl).
	if len(os.Args) > 1 && os.Args[1] == "healthcheck" {
		_, port, _ := net.SplitHostPort(addr)
		c := http.Client{Timeout: 3 * time.Second}
		res, err := c.Get("http://127.0.0.1:" + port + "/healthz")
		if err != nil || res.StatusCode != http.StatusOK {
			os.Exit(1)
		}
		os.Exit(0)
	}

	s := &store{dir: env("DATA_DIR", "/data")}
	if err := os.MkdirAll(s.dir, 0o755); err != nil {
		log.Fatal(err)
	}

	web, err := fs.Sub(webFS, "web")
	if err != nil {
		log.Fatal(err)
	}
	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, _ *http.Request) { io.WriteString(w, "ok") })
	mux.HandleFunc("GET /api/version", func(w http.ResponseWriter, _ *http.Request) { writeJSON(w, map[string]string{"version": version}) })
	mux.HandleFunc("GET /api/tunings", s.list)
	mux.HandleFunc("GET /api/tunings/{id}", s.get)
	mux.HandleFunc("PUT /api/tunings/{id}", s.put)
	mux.HandleFunc("POST /api/tunings/{id}", s.put) // sendBeacon när sidan stängs
	mux.HandleFunc("DELETE /api/tunings/{id}", s.del)
	mux.Handle("GET /", http.FileServerFS(web))

	srv := &http.Server{
		Addr:              addr,
		Handler:           headers(mux),
		ReadHeaderTimeout: 10 * time.Second,
		ReadTimeout:       30 * time.Second,
		WriteTimeout:      30 * time.Second,
		IdleTimeout:       120 * time.Second,
	}

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	go func() {
		log.Printf("Piano Tunah %s lyssnar på %s, data i %s", version, addr, s.dir)
		if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			log.Fatal(err)
		}
	}()
	<-ctx.Done()
	shutdown, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	srv.Shutdown(shutdown)
}
