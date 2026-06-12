// dex-login.go — Get a JWT from Dex for CLI/SDK testing.
//
// Implements the OAuth2 authorization code + PKCE flow locally.
// Opens a browser tab for Dex login, listens on localhost:7788 for the callback,
// exchanges the code for tokens, and prints the access_token.
//
// Usage:
//   go run scripts/dex-login.go [--issuer http://host.docker.internal:30556/dex]
//
// Then export the token for use with temporal CLI:
//   export TEMPORAL_TOKEN=$(go run scripts/dex-login.go)
//   temporal --address localhost:7233 --auth-token "$TEMPORAL_TOKEN" operator namespace list

package main

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"log"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"runtime"
	"strings"
	"time"
)

var (
	issuer      = flag.String("issuer", "http://host.docker.internal:30556/dex", "Dex issuer URL")
	clientID    = flag.String("client-id", "temporal-cli", "OAuth2 client ID")
	callbackAddr = flag.String("callback-addr", "localhost:7788", "Local callback address")
)

func main() {
	flag.Parse()

	callbackURL := "http://" + *callbackAddr + "/callback"
	authURL := *issuer + "/auth"
	tokenURL := *issuer + "/token"

	// PKCE: generate code_verifier and code_challenge
	verifier := randomBase64(32)
	h := sha256.Sum256([]byte(verifier))
	challenge := base64.RawURLEncoding.EncodeToString(h[:])
	state := randomBase64(16)

	// Build the authorization URL
	params := url.Values{
		"client_id":             {*clientID},
		"redirect_uri":          {callbackURL},
		"response_type":         {"code"},
		"scope":                 {"openid profile email offline_access"},
		"state":                 {state},
		"code_challenge":        {challenge},
		"code_challenge_method": {"S256"},
	}
	loginURL := authURL + "?" + params.Encode()

	// Channel to receive the auth code
	codeCh := make(chan string, 1)
	errCh := make(chan error, 1)

	// Local HTTP server to catch the callback
	mux := http.NewServeMux()
	srv := &http.Server{Addr: *callbackAddr, Handler: mux}
	mux.HandleFunc("/callback", func(w http.ResponseWriter, r *http.Request) {
		got := r.URL.Query().Get("state")
		if got != state {
			errCh <- fmt.Errorf("state mismatch: got %s want %s", got, state)
			http.Error(w, "state mismatch", http.StatusBadRequest)
			return
		}
		code := r.URL.Query().Get("code")
		if code == "" {
			errCh <- fmt.Errorf("no code in callback: %s", r.URL.RawQuery)
			http.Error(w, "no code", http.StatusBadRequest)
			return
		}
		fmt.Fprintln(w, "<html><body><h2>Login successful!</h2><p>You can close this tab.</p></body></html>")
		codeCh <- code
		go func() { time.Sleep(100 * time.Millisecond); srv.Shutdown(context.Background()) }()
	})

	go func() {
		if err := srv.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			errCh <- err
		}
	}()

	// Open browser
	fmt.Fprintf(os.Stderr, "Opening browser for Dex login...\n%s\n\n", loginURL)
	openBrowser(loginURL)

	// Wait for code or error
	var code string
	select {
	case code = <-codeCh:
	case err := <-errCh:
		log.Fatalf("Login failed: %v", err)
	case <-time.After(5 * time.Minute):
		log.Fatal("Login timed out after 5 minutes")
	}

	// Exchange code for token
	resp, err := http.PostForm(tokenURL, url.Values{
		"grant_type":    {"authorization_code"},
		"client_id":     {*clientID},
		"redirect_uri":  {callbackURL},
		"code":          {code},
		"code_verifier": {verifier},
	})
	if err != nil {
		log.Fatalf("Token exchange failed: %v", err)
	}
	defer resp.Body.Close()

	body, _ := io.ReadAll(resp.Body)
	if resp.StatusCode != http.StatusOK {
		log.Fatalf("Token endpoint returned %d: %s", resp.StatusCode, body)
	}

	var tokenResp struct {
		AccessToken  string `json:"access_token"`
		IDToken      string `json:"id_token"`
		RefreshToken string `json:"refresh_token"`
		Error        string `json:"error"`
		ErrorDesc    string `json:"error_description"`
	}
	if err := json.Unmarshal(body, &tokenResp); err != nil {
		log.Fatalf("Failed to parse token response: %v\n%s", err, body)
	}
	if tokenResp.Error != "" {
		log.Fatalf("Token error: %s — %s", tokenResp.Error, tokenResp.ErrorDesc)
	}
	if tokenResp.AccessToken == "" {
		log.Fatalf("No access_token in response: %s", body)
	}

	// Print only the access_token to stdout so callers can do:
	//   export TEMPORAL_TOKEN=$(go run scripts/dex-login.go)
	// All other tokens go to stderr for visibility but don't pollute $() capture.
	fmt.Println(strings.TrimSpace(tokenResp.AccessToken))

	// Print id_token and refresh_token to stderr — needed for SDK workers that
	// auto-refresh. The id_token carries the email/permissions claims that
	// Temporal's claim mapper reads; the refresh_token lets workers get new
	// id_tokens without re-running the browser flow.
	if tokenResp.IDToken != "" {
		fmt.Fprintf(os.Stderr, "\nid_token (use this as Bearer token for SDK workers):\n%s\n", strings.TrimSpace(tokenResp.IDToken))
	}
	if tokenResp.RefreshToken != "" {
		fmt.Fprintf(os.Stderr, "\nrefresh_token (keep this to auto-refresh before expiry):\n%s\n", strings.TrimSpace(tokenResp.RefreshToken))
	}
}

func randomBase64(n int) string {
	b := make([]byte, n)
	rand.Read(b)
	return base64.RawURLEncoding.EncodeToString(b)
}

func openBrowser(url string) {
	var cmd string
	var args []string
	switch runtime.GOOS {
	case "darwin":
		cmd = "open"
		args = []string{url}
	case "linux":
		cmd = "xdg-open"
		args = []string{url}
	default:
		fmt.Fprintf(os.Stderr, "Please open manually: %s\n", url)
		return
	}
	exec.Command(cmd, args...).Start()
}
