// toySDK.go — OpenTDF SDK smoke test
//
// What it does:
//   Authenticates as Alex (aaa@topsecret.usa, TS/USA) against the local DSP stack,
//   encrypts a random plaintext string into a TDF with the following attributes:
//     - classification/topsecret
//     - relto/usa
//     - relto/fvey
//   Prints plaintext, saves TDF to disk, prints encrypted binary + entropy,
//   then decrypts and prints the recovered plaintext to verify the round-trip.
//
// Prerequisites:
//   - DSP stack running:  docker compose up --build
//   - Go installed:       brew install go  (macOS)  or  see ubuntu_prereqs.sh
//   - Dependencies fetched:
//       go env -w GOPRIVATE=github.com/virtru-corp/*
//       go mod tidy
//
// Build:
//   go build -o toySDK toySDK.go
//
// Run (built binary):
//   ./toySDK
//
// Run (without building):
//   go run toySDK.go
//
// Output file:
//   alex_test.tdf  (written to current directory)

package main

import (
	"bytes"
	"context"
	"crypto/rand"
	"crypto/tls"
	"encoding/base64"
	"encoding/hex"
	"fmt"
	"math"
	"net/http"
	"os"
	"strings"

	otdf "github.com/opentdf/platform/sdk"
	"golang.org/x/oauth2"
)

// randomString returns a cryptographically random URL-safe string of exactly n characters.
func randomString(n int) string {
	b := make([]byte, n)
	rand.Read(b)
	return base64.RawURLEncoding.EncodeToString(b)[:n]
}

// shannonEntropy calculates the Shannon entropy (bits per byte) of the input.
// High entropy (~8.0) indicates encrypted/compressed data; low entropy indicates plaintext.
func shannonEntropy(data []byte) float64 {
	if len(data) == 0 {
		return 0
	}
	freq := make(map[byte]int)
	for _, b := range data {
		freq[b]++
	}
	n := float64(len(data))
	var entropy float64
	for _, count := range freq {
		p := float64(count) / n
		entropy -= p * math.Log2(p)
	}
	return entropy
}

func main() {
	ctx := context.Background()

	// Use an insecure HTTP client for the local dev TLS certificate
	insecureHTTP := &http.Client{
		Transport: &http.Transport{
			TLSClientConfig: &tls.Config{InsecureSkipVerify: true}, //nolint:gosec // local dev only
		},
	}
	ctx = context.WithValue(ctx, oauth2.HTTPClient, insecureHTTP)

	// Authenticate as Alex (TS/USA) via Resource Owner Password Credentials flow
	oauthCfg := &oauth2.Config{
		ClientID: "opentdf-public",
		Endpoint: oauth2.Endpoint{
			TokenURL: "https://local-dsp.virtru.com:18443/auth/realms/opentdf/protocol/openid-connect/token",
		},
	}
	token, err := oauthCfg.PasswordCredentialsToken(ctx, "aaa@topsecret.usa", "testuser123")
	if err != nil {
		panic(err)
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
		panic(err)
	}

	// --- Step 1: Plaintext ---
	plaintextStr := fmt.Sprintf("TOP SECRET\n%s\nTOP SECRET", randomString(140))
	fmt.Println("========================================")
	fmt.Println("PLAINTEXT CONTENT:")
	fmt.Println("========================================")
	fmt.Println(plaintextStr)
	fmt.Printf("\nPlaintext entropy: %.4f bits/byte\n", shannonEntropy([]byte(plaintextStr)))

	// --- Step 2: Encrypt ---
	encrypted := &bytes.Buffer{}
	_, err = client.CreateTDF(encrypted, strings.NewReader(plaintextStr),
		otdf.WithKasInformation(otdf.KASInfo{
			URL: "https://local-dsp.virtru.com:8080/kas",
		}),
		otdf.WithDataAttributes(
			"https://demo.com/attr/classification/value/topsecret",
			"https://demo.com/attr/relto/value/usa",
			"https://demo.com/attr/relto/value/fvey",
		),
	)
	if err != nil {
		panic(err)
	}

	encryptedBytes := encrypted.Bytes()

	// --- Step 3: Save TDF to disk ---
	outFile := "alex_test.tdf"
	if err := os.WriteFile(outFile, encryptedBytes, 0644); err != nil {
		panic(err)
	}
	fmt.Printf("\nTDF written to: %s (%d bytes)\n", outFile, len(encryptedBytes))

	// --- Step 4: Print encrypted binary (hex dump, first 256 bytes) ---
	fmt.Println("\n========================================")
	fmt.Println("ENCRYPTED CONTENT (hex dump, first 256 bytes):")
	fmt.Println("========================================")
	preview := encryptedBytes
	if len(preview) > 256 {
		preview = preview[:256]
	}
	fmt.Println(hex.Dump(preview))

	// --- Step 5: Entropy of encrypted content ---
	fmt.Printf("Encrypted entropy: %.4f bits/byte (close to 8.0 = well encrypted)\n", shannonEntropy(encryptedBytes))

	// --- Step 6: Decrypt and print ---
	tdfReader, err := client.LoadTDF(bytes.NewReader(encryptedBytes))
	if err != nil {
		panic(err)
	}
	if err := tdfReader.Init(ctx); err != nil {
		panic(err)
	}
	decrypted := &bytes.Buffer{}
	if _, err := tdfReader.WriteTo(decrypted); err != nil {
		panic(err)
	}

	fmt.Println("\n========================================")
	fmt.Println("DECRYPTED CONTENT:")
	fmt.Println("========================================")
	fmt.Println(decrypted.String())
	fmt.Println("\nSUCCESS: TDF created, saved, and decrypted successfully")
}
