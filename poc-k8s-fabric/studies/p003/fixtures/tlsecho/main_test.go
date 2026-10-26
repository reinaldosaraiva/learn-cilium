// SPDX-License-Identifier: Apache-2.0
package main

import (
	"crypto/tls"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestEchoMux(t *testing.T) {
	h := newEchoMux()
	req := httptest.NewRequest(http.MethodGet, "/hello", nil)
	req.Host = "tlsecho.gateway-study.svc:8443"
	req.TLS = &tls.ConnectionState{ServerName: "tlsecho.gateway-study.svc"}
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("got status %d, want 200", rec.Code)
	}
	body := rec.Body.String()
	if !strings.Contains(body, "sni=tlsecho.gateway-study.svc") {
		t.Fatalf("unexpected body: %q", body)
	}
}
