// bobTestAlexFile.go — OpenTDF SDK decrypt test (Bob reads Alex's file)
//
// What it does:
//   Authenticates as Bob (bbb@topsecret.gbr, TS/GBR) and attempts to decrypt
//   alex_test.tdf — the TDF created by toySDK.go as Alex (TS/USA).
//
//   Bob is entitled to decrypt Alex's file because:
//     - classification/topsecret: Bob holds TS clearance
//     - relto/fvey:               GBR is a Five Eyes member
//
//   The original alex_test.tdf is not modified.
//
// Prerequisites:
//   - DSP stack running:       docker compose up --build
//   - alex_test.tdf exists:    run toySDK.go first
//   - Go installed:            brew install go  (macOS)  or  see ubuntu_prereqs.sh
//   - Dependencies fetched:    go mod tidy
//
// Run:
//   go run bobTestAlexFile.go
//
// Expected output:
//   SUCCESS: Bob successfully decrypted Alex's file

package main

import (
	"bytes"
	"context"
	"crypto/tls"
	"fmt"
	"net/http"
	"os"

	otdf "github.com/opentdf/platform/sdk"
	"golang.org/x/oauth2"
)

func main() {
	ctx := context.Background()

	// Use an insecure HTTP client for the local dev TLS certificate
	insecureHTTP := &http.Client{
		Transport: &http.Transport{
			TLSClientConfig: &tls.Config{InsecureSkipVerify: true}, //nolint:gosec // local dev only
		},
	}
	ctx = context.WithValue(ctx, oauth2.HTTPClient, insecureHTTP)

	// Authenticate as Bob (TS/GBR) via Resource Owner Password Credentials flow
	oauthCfg := &oauth2.Config{
		ClientID: "opentdf-public",
		Endpoint: oauth2.Endpoint{
			TokenURL: "https://local-dsp.virtru.com:18443/auth/realms/opentdf/protocol/openid-connect/token",
		},
	}
	token, err := oauthCfg.PasswordCredentialsToken(ctx, "bbb@topsecret.gbr", "testuser123")
	if err != nil {
		fmt.Printf("FAILURE: Bob could not authenticate: %v\n", err)
		os.Exit(1)
	}
	tokenSource := oauthCfg.TokenSource(ctx, token)

	// Create SDK client
	client, err := otdf.New(
		"https://local-dsp.virtru.com:8080",
		otdf.WithInsecureSkipVerifyConn(),
		otdf.WithTokenEndpoint("https://local-dsp.virtru.com:18443/auth/realms/opentdf/protocol/openid-connect/token"),
		otdf.WithOAuthAccessTokenSource(tokenSource),
	)
	if err != nil {
		fmt.Printf("FAILURE: Could not create SDK client: %v\n", err)
		os.Exit(1)
	}

	// Open alex_test.tdf (created by toySDK.go) — do not modify it
	tdfPath := "alex_test.tdf"
	tdfFile, err := os.Open(tdfPath)
	if err != nil {
		fmt.Printf("FAILURE: Could not open %s: %v\n", tdfPath, err)
		fmt.Println("Make sure toySDK.go has been run first to generate alex_test.tdf")
		os.Exit(1)
	}
	defer tdfFile.Close()

	// Decrypt
	tdfReader, err := client.LoadTDF(tdfFile)
	if err != nil {
		fmt.Printf("FAILURE: Bob could not load TDF: %v\n", err)
		os.Exit(1)
	}
	if err := tdfReader.Init(ctx); err != nil {
		fmt.Printf("FAILURE: Bob was denied access (KAS rejected key unwrap): %v\n", err)
		os.Exit(1)
	}
	decrypted := &bytes.Buffer{}
	if _, err := tdfReader.WriteTo(decrypted); err != nil {
		fmt.Printf("FAILURE: Bob could not decrypt TDF content: %v\n", err)
		os.Exit(1)
	}

	fmt.Println("========================================")
	fmt.Println("DECRYPTED CONTENT:")
	fmt.Println("========================================")
	fmt.Println(decrypted.String())
	fmt.Println("\nSUCCESS: Bob successfully decrypted Alex's file")
}
