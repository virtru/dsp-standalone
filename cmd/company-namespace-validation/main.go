// Command company-namespace-validation tests the optional company namespace.
//
// What it does:
//   Authenticates as engineering-company-user, creates a TDF tagged with the
//   sample company namespace attributes, verifies the engineering user can
//   decrypt it, then verifies hr-company-user is denied.
//
// Expected output:
//   SUCCESS: Company namespace policy enforced as expected

package main

import (
	"bytes"
	"context"
	"crypto/tls"
	"fmt"
	"net/http"
	"os"
	"strings"

	otdf "github.com/opentdf/platform/sdk"
	"golang.org/x/oauth2"
)

const (
	tokenURL        = "https://local-dsp.virtru.com:18443/auth/realms/opentdf/protocol/openid-connect/token"
	platformURL     = "https://local-dsp.virtru.com:8080"
	kasURL          = "https://local-dsp.virtru.com:8080/kas"
	companyTDFPath  = "company_engineering_test.tdf"
	engineeringUser = "engineering-company-user"
	hrUser          = "hr-company-user"
	defaultPassword = "testuser123"
	publicClientID  = "opentdf-public"
	engineeringDept = "https://company.com/attr/department/value/engineering"
	confidentialFQN = "https://company.com/attr/sensitivity/value/confidential"
	mnpiFQN         = "https://company.com/attr/classification/value/mnpi"
)

func newClient(ctx context.Context, username, password string) (*otdf.SDK, error) {
	insecureHTTP := &http.Client{
		Transport: &http.Transport{
			TLSClientConfig: &tls.Config{InsecureSkipVerify: true}, //nolint:gosec // local dev only
		},
	}
	ctx = context.WithValue(ctx, oauth2.HTTPClient, insecureHTTP)

	oauthCfg := &oauth2.Config{
		ClientID: publicClientID,
		Endpoint: oauth2.Endpoint{
			TokenURL: tokenURL,
		},
	}

	token, err := oauthCfg.PasswordCredentialsToken(ctx, username, password)
	if err != nil {
		return nil, err
	}

	return otdf.New(
		platformURL,
		otdf.WithInsecureSkipVerifyConn(),
		otdf.WithOAuthAccessTokenSource(oauthCfg.TokenSource(ctx, token)),
	)
}

func main() {
	ctx := context.Background()

	engineeringClient, err := newClient(ctx, engineeringUser, defaultPassword)
	if err != nil {
		fmt.Printf("FAILURE: Engineering user could not authenticate: %v\n", err)
		os.Exit(1)
	}

	plaintext := "Engineering-only MNPI document for company namespace validation."
	encrypted := &bytes.Buffer{}

	_, err = engineeringClient.CreateTDF(
		encrypted,
		strings.NewReader(plaintext),
		otdf.WithKasInformation(otdf.KASInfo{URL: kasURL}),
		otdf.WithDataAttributes(engineeringDept, confidentialFQN, mnpiFQN),
	)
	if err != nil {
		fmt.Printf("FAILURE: Engineering user could not create company TDF: %v\n", err)
		os.Exit(1)
	}

	if err := os.WriteFile(companyTDFPath, encrypted.Bytes(), 0644); err != nil {
		fmt.Printf("FAILURE: Could not write %s: %v\n", companyTDFPath, err)
		os.Exit(1)
	}

	engineerReader, err := engineeringClient.LoadTDF(bytes.NewReader(encrypted.Bytes()))
	if err != nil {
		fmt.Printf("FAILURE: Engineering user could not load company TDF: %v\n", err)
		os.Exit(1)
	}
	if err := engineerReader.Init(ctx); err != nil {
		fmt.Printf("FAILURE: Engineering user was denied access to engineering TDF: %v\n", err)
		os.Exit(1)
	}

	engineerPlaintext := &bytes.Buffer{}
	if _, err := engineerReader.WriteTo(engineerPlaintext); err != nil {
		fmt.Printf("FAILURE: Engineering user could not decrypt company TDF: %v\n", err)
		os.Exit(1)
	}
	if engineerPlaintext.String() != plaintext {
		fmt.Println("FAILURE: Engineering user decrypted unexpected content")
		os.Exit(1)
	}

	hrClient, err := newClient(ctx, hrUser, defaultPassword)
	if err != nil {
		fmt.Printf("FAILURE: HR user could not authenticate: %v\n", err)
		os.Exit(1)
	}

	hrReader, err := hrClient.LoadTDF(bytes.NewReader(encrypted.Bytes()))
	if err != nil {
		fmt.Printf("FAILURE: HR user could not load company TDF: %v\n", err)
		os.Exit(1)
	}
	if err := hrReader.Init(ctx); err != nil {
		fmt.Println("SUCCESS: Company namespace policy enforced as expected")
		fmt.Printf("Engineering user decrypted %s; HR user was denied: %v\n", companyTDFPath, err)
		return
	}

	hrPlaintext := &bytes.Buffer{}
	hrReader.WriteTo(hrPlaintext) //nolint:errcheck
	fmt.Println("FAILURE: HR user unexpectedly decrypted engineering-only company data")
	fmt.Println(hrPlaintext.String())
	os.Exit(1)
}
