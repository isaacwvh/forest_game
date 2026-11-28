package server

import (
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/golang-jwt/jwt/v5"
)

func TestRemoteVerifierWithLocalJWKS(t *testing.T) {
	const keyID = "local-test-signing-key"
	const audience = "authenticated"
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	jwks := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/auth/v1/.well-known/jwks.json" {
			http.NotFound(w, r)
			return
		}
		keys := map[string]any{"keys": []map[string]string{{
			"kid": keyID, "alg": "ES256", "use": "sig", "kty": "EC", "crv": "P-256",
			"x": base64.RawURLEncoding.EncodeToString(key.X.FillBytes(make([]byte, 32))),
			"y": base64.RawURLEncoding.EncodeToString(key.Y.FillBytes(make([]byte, 32))),
		}}}
		_ = json.NewEncoder(w).Encode(keys)
	}))
	t.Cleanup(jwks.Close)
	issuer := jwks.URL + "/auth/v1"
	verifier, err := RemoteVerifier("ES256", issuer, audience, issuer+"/.well-known/jwks.json")
	if err != nil {
		t.Fatal(err)
	}
	verifier.client = jwks.Client()
	issue := func(issuer, subject, audience, kid string, expires time.Time) string {
		t.Helper()
		token := jwt.NewWithClaims(jwt.SigningMethodES256, jwt.RegisteredClaims{
			Issuer: issuer, Subject: subject, Audience: jwt.ClaimStrings{audience}, ExpiresAt: jwt.NewNumericDate(expires),
		})
		token.Header["kid"] = kid
		signed, err := token.SignedString(key)
		if err != nil {
			t.Fatal(err)
		}
		return signed
	}
	now := time.Now()
	for _, tc := range []struct {
		name, issuer, subject, audience, kid string
		expires                              time.Time
		valid                                bool
	}{
		{"valid", issuer, "account-one", audience, keyID, now.Add(time.Minute), true},
		{"refreshed", issuer, "account-one", audience, keyID, now.Add(2 * time.Minute), true},
		{"different account", issuer, "account-two", audience, keyID, now.Add(time.Minute), true},
		{"wrong issuer", issuer + "/different", "account-one", audience, keyID, now.Add(time.Minute), false},
		{"wrong audience", issuer, "account-one", "other", keyID, now.Add(time.Minute), false},
		{"unknown key", issuer, "account-one", audience, "unknown", now.Add(time.Minute), false},
		{"expired", issuer, "account-one", audience, keyID, now.Add(-time.Minute), false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			identity, err := verifier.Verify(context.Background(), issue(tc.issuer, tc.subject, tc.audience, tc.kid, tc.expires))
			if tc.valid {
				if err != nil || identity != (Identity{Issuer: tc.issuer, Subject: tc.subject}) {
					t.Fatal(identity, err)
				}
			} else if !errors.Is(err, invalidToken) {
				t.Fatal(identity, err)
			}
		})
	}
}
