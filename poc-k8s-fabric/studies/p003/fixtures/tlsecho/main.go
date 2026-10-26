// SPDX-License-Identifier: Apache-2.0
// Minimal TLS echo backend for P003-S009 (BackendTLSPolicy + SAN verification).
// Uses Go standard library only (zero external dependencies).
package main

import (
	"crypto/tls"
	"fmt"
	"log"
	"net/http"
	"os"
	"time"
)

func main() {
	certFile := getenv("TLS_CERT_FILE", "/certs/tls.crt")
	keyFile := getenv("TLS_KEY_FILE", "/certs/tls.key")
	addr := getenv("LISTEN_ADDR", ":8443")

	srv := &http.Server{
		Addr:              addr,
		Handler:           newEchoMux(),
		ReadHeaderTimeout: 5 * time.Second,
		TLSConfig: &tls.Config{
			MinVersion: tls.VersionTLS12,
		},
	}

	log.Printf("starting p003-tlsecho on %s (cert=%s key=%s)", addr, certFile, keyFile)
	if err := srv.ListenAndServeTLS(certFile, keyFile); err != nil {
		log.Fatalf("server error: %v", err)
	}
}

func newEchoMux() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		sni := ""
		if r.TLS != nil {
			sni = r.TLS.ServerName
		}
		w.Header().Set("Content-Type", "text/plain; charset=utf-8")
		_, _ = fmt.Fprintf(w, "p003-tlsecho ok path=%s host=%s sni=%s\n", r.URL.Path, r.Host, sni)
	})
	return mux
}

func getenv(k, def string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return def
}
