// Command alice-test-alex-file verifies that Alice cannot decrypt Alex's TDF.
//
// What it does:
//   Authenticates as Alice (aaa@secret.usa, S/USA) and attempts to decrypt
//   alex_test.tdf — the TDF created by toy-sdk as Alex (TS/USA).
//
//   Alice is NOT entitled to decrypt Alex's file because:
//     - classification/topsecret: Alice only holds Secret (S) clearance, not Top Secret (TS)
//
//   The EXPECTED outcome is that KAS DENIES the key unwrap request.
//   This test reports SUCCESS when access is correctly denied,
//   and FAILURE if Alice is unexpectedly able to decrypt the file.
//
//   The original alex_test.tdf is not modified.
//
// Prerequisites:
//   - DSP stack running:       docker compose up --build
//   - alex_test.tdf exists:    run go run ./cmd/toy-sdk first
//   - Go installed:            brew install go  (macOS)  or  see ubuntu_prereqs.sh
//   - Dependencies fetched:    go mod download
//
// Run:
//   go run ./cmd/alice-test-alex-file
//
// Expected output:
//   SUCCESS: Access correctly denied — Alice cannot decrypt a Top Secret file

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

	// Authenticate as Alice (S/USA) via Resource Owner Password Credentials flow
	oauthCfg := &oauth2.Config{
		ClientID: "opentdf-public",
		Endpoint: oauth2.Endpoint{
			TokenURL: "https://local-dsp.virtru.com:18443/auth/realms/opentdf/protocol/openid-connect/token",
		},
	}
	token, err := oauthCfg.PasswordCredentialsToken(ctx, "aaa@secret.usa", "testuser123")
	if err != nil {
		fmt.Printf("FAILURE: Alice could not authenticate: %v\n", err)
		os.Exit(1)
	}
	tokenSource := oauthCfg.TokenSource(ctx, token)

	// Create SDK client
	client, err := otdf.New(
		"https://local-dsp.virtru.com:8080",
		otdf.WithInsecureSkipVerifyConn(),
		otdf.WithOAuthAccessTokenSource(tokenSource),
	)
	if err != nil {
		fmt.Printf("FAILURE: Could not create SDK client: %v\n", err)
		os.Exit(1)
	}

	// Open alex_test.tdf (created by toy-sdk) — do not modify it
	tdfPath := "alex_test.tdf"
	tdfFile, err := os.Open(tdfPath)
	if err != nil {
		fmt.Printf("FAILURE: Could not open %s: %v\n", tdfPath, err)
		fmt.Println("Make sure go run ./cmd/toy-sdk has been run first to generate alex_test.tdf")
		os.Exit(1)
	}
	defer func() {
		if err := tdfFile.Close(); err != nil {
			fmt.Printf("WARNING: Could not close %s: %v\n", tdfPath, err)
		}
	}()

	// Attempt to decrypt — Alice should be denied at the KAS key unwrap step
	tdfReader, err := client.LoadTDF(tdfFile)
	if err != nil {
		fmt.Printf("FAILURE: Unexpected error loading TDF: %v\n", err)
		os.Exit(1)
	}
	if err := tdfReader.Init(ctx); err != nil {
		fmt.Println("========================================")
		fmt.Println("ACCESS DENIED (expected):")
		fmt.Println("========================================")
		fmt.Printf("KAS rejected Alice's key unwrap request: %v\n", err)
		fmt.Println("\nSUCCESS: Access correctly denied — Alice cannot decrypt a Top Secret file")
		return
	}

	// If we reach here Alice decrypted the file — this is a policy failure
	decrypted := &bytes.Buffer{}
	tdfReader.WriteTo(decrypted) //nolint:errcheck
	fmt.Println("========================================")
	fmt.Println("DECRYPTED CONTENT (should NOT have happened):")
	fmt.Println("========================================")
	fmt.Println(decrypted.String())
	fmt.Println("\nFAILURE: Alice was able to decrypt a Top Secret file — check subject mappings and policy")
	os.Exit(1)
}
