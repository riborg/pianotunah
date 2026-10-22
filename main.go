// Piano Tunah: serves the web app and stores saved tunings as JSON files in
// DATA_DIR. No dependencies beyond the standard library.
package main

import (
	"bytes"
	"context"
	"embed"
	"encoding/json"
	"errors"
	"fmt"
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
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"
)

//go:embed web
var webFS embed.FS

const maxBody = 2 << 20

// Set at build time: -ldflags "-X main.version=v1.2.3".
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
		http.Error(w, "invalid id", http.StatusBadRequest)
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
		http.Error(w, "invalid id", http.StatusBadRequest)
		return
	}
	body, err := io.ReadAll(http.MaxBytesReader(w, r.Body, maxBody))
	if err != nil {
		http.Error(w, "request too large or malformed", http.StatusRequestEntityTooLarge)
		return
	}
	var doc map[string]any
	if err := json.Unmarshal(body, &doc); err != nil {
		http.Error(w, "invalid JSON", http.StatusBadRequest)
		return
	}
	if docID, _ := doc["id"].(string); docID != id {
		http.Error(w, "document id does not match the URL", http.StatusBadRequest)
		return
	}

	s.mu.Lock()
	defer s.mu.Unlock()

	// Optimistic locking: the client sends the revision it started from. If
	// someone else has saved since, answer 409 instead of overwriting.
	base, _ := doc["rev"].(float64)
	cur, old, err := s.load(id)
	if err != nil {
		httpError(w, err, http.StatusInternalServerError)
		return
	}
	if int64(base) != cur {
		log.Printf("save %q refused: started from rev %d, rev %d is saved", doc["name"], int64(base), cur)
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
	log.Printf("save %q rev %d: %s", doc["name"], cur+1, changes(old, body))
	writeJSON(w, map[string]int64{"rev": cur + 1})
}

// Saved revision and document for id; 0 and nil if the tuning does not exist.
func (s *store) load(id string) (int64, []byte, error) {
	b, err := os.ReadFile(s.path(id))
	if errors.Is(err, fs.ErrNotExist) {
		return 0, nil, nil
	} else if err != nil {
		return 0, nil, err
	}
	var d struct {
		Rev int64 `json:"rev"`
	}
	if err := json.Unmarshal(b, &d); err != nil {
		return 0, nil, err
	}
	return d.Rev, b, nil
}

// The parts of a tuning that the log reports on.
type keyRec struct {
	Hz float64 `json:"hz"`
	N  int     `json:"n"`
}

type tuningDoc struct {
	Name          string             `json:"name"`
	Settings      json.RawMessage    `json:"settings"`
	Notes         string             `json:"notes"`
	Keys          map[string]keyRec  `json:"keys"`
	Inharmonicity map[string]float64 `json:"inharmonicity"`
	History       []json.RawMessage  `json:"history"`
}

var noteNames = []string{"C", "C♯", "D", "E♭", "E", "F", "F♯", "G", "A♭", "A", "B♭", "B"}

// Key 1 = A0, as in theory.js.
func noteName(key string) string {
	k, err := strconv.Atoi(key)
	if err != nil {
		return key
	}
	return noteNames[(k+8)%12] + strconv.Itoa((k+8)/12)
}

func sortedKeys[V any](m map[string]V) []string {
	ks := make([]string, 0, len(m))
	for k := range m {
		ks = append(ks, k)
	}
	sort.Slice(ks, func(i, j int) bool {
		a, _ := strconv.Atoi(ks[i])
		b, _ := strconv.Atoi(ks[j])
		return a < b
	})
	return ks
}

// What a save changed: measured keys, B, settings, name, notes, passes.
func changes(oldRaw, newRaw []byte) string {
	if oldRaw == nil {
		return "new tuning"
	}
	var a, b tuningDoc
	if json.Unmarshal(oldRaw, &a) != nil || json.Unmarshal(newRaw, &b) != nil {
		return "unreadable"
	}
	var out []string
	for _, k := range sortedKeys(b.Keys) {
		if r, ok := a.Keys[k]; ok && r == b.Keys[k] {
			continue
		}
		s := fmt.Sprintf("%s %.2f Hz", noteName(k), b.Keys[k].Hz)
		if b.Keys[k].N > 1 {
			s += fmt.Sprintf(" (partial %d)", b.Keys[k].N)
		}
		out = append(out, s)
	}
	for _, k := range sortedKeys(b.Inharmonicity) {
		if a.Inharmonicity[k] != b.Inharmonicity[k] {
			out = append(out, fmt.Sprintf("%s B=%.3g", noteName(k), b.Inharmonicity[k]))
		}
	}
	if len(b.Keys) < len(a.Keys) {
		out = append(out, fmt.Sprintf("%d keys cleared", len(a.Keys)-len(b.Keys)))
	}
	if !bytes.Equal(a.Settings, b.Settings) {
		out = append(out, "settings")
	}
	if a.Name != b.Name {
		out = append(out, fmt.Sprintf("renamed from %q", a.Name))
	}
	if a.Notes != b.Notes {
		out = append(out, "notes")
	}
	if len(b.History) > len(a.History) {
		out = append(out, "new pass")
	}
	if len(out) == 0 {
		return "no changes"
	}
	if len(out) > 8 {
		out = append(out[:8], fmt.Sprintf("and %d more", len(out)-8))
	}
	return strings.Join(out, ", ")
}

func (s *store) del(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	if !idPattern.MatchString(id) {
		http.Error(w, "invalid id", http.StatusBadRequest)
		return
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if err := os.Remove(s.path(id)); err != nil && !errors.Is(err, fs.ErrNotExist) {
		httpError(w, err, http.StatusInternalServerError)
		return
	}
	log.Printf("delete %s", id)
	w.WriteHeader(http.StatusNoContent)
}

// Lines from the page's diagnostics (diag.js), only with DEBUG set. id
// tells apart pages open at the same time.
func clientLog(w http.ResponseWriter, r *http.Request) {
	var msg struct {
		ID    string   `json:"id"`
		Lines []string `json:"lines"`
	}
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 64<<10)).Decode(&msg); err != nil || !idPattern.MatchString(msg.ID) {
		http.Error(w, "invalid log", http.StatusBadRequest)
		return
	}
	clean := func(s string) string {
		s = strings.Map(func(c rune) rune {
			if c < 32 || c == 127 {
				return ' '
			}
			return c
		}, s)
		if r := []rune(s); len(r) > 400 {
			s = string(r[:400]) + "…"
		}
		return s
	}
	for i, line := range msg.Lines {
		if i == 100 {
			break
		}
		log.Printf("page %s: %s", clean(msg.ID), clean(line))
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

// Security headers. The microphone is only allowed for the page itself.
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
	debug := env("DEBUG", "") != ""

	// `pianotunah healthcheck` is used by Docker (the scratch image has no curl).
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
	mux.HandleFunc("GET /api/version", func(w http.ResponseWriter, _ *http.Request) {
		writeJSON(w, map[string]any{"version": version, "debug": debug})
	})
	if debug {
		mux.HandleFunc("POST /api/log", clientLog)
	}
	mux.HandleFunc("GET /api/tunings", s.list)
	mux.HandleFunc("GET /api/tunings/{id}", s.get)
	mux.HandleFunc("PUT /api/tunings/{id}", s.put)
	mux.HandleFunc("POST /api/tunings/{id}", s.put) // sendBeacon when the page closes
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
		log.Printf("Piano Tunah %s listening on %s, data in %s", version, addr, s.dir)
		if debug {
			log.Print("DEBUG is set: pages log what they do")
		}
		if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			log.Fatal(err)
		}
	}()
	<-ctx.Done()
	shutdown, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	srv.Shutdown(shutdown)
}
