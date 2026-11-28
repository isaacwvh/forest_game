package server

import (
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rsa"
	"encoding/base64"
	"encoding/json"
	"errors"
	"io"
	"math/big"
	"net/http"
	"net/url"
	"strings"
	"sync"
	"time"
	"unicode/utf8"

	"github.com/golang-jwt/jwt/v5"
)

const DevIssuer = "urn:movement-forest:development"
const DevAudience = "movement-forest-development"

type Identity struct{ Issuer, Subject string }

type Verifier struct {
	algorithm, issuer, audience, keysURL string
	secret                               []byte
	client                               *http.Client
	mu                                   sync.Mutex
	keys                                 []webKey
	expires                              time.Time
}

type webKey struct {
	ID    string `json:"kid"`
	Alg   string `json:"alg"`
	KTY   string `json:"kty"`
	Use   string `json:"use"`
	N     string `json:"n"`
	E     string `json:"e"`
	Curve string `json:"crv"`
	X     string `json:"x"`
	Y     string `json:"y"`
}

var invalidToken = &apiError{401, "invalid_token", "Invalid or expired bearer token"}
var authUnavailable = &apiError{503, "auth_unavailable", "Authentication provider unavailable"}

func DevelopmentVerifier(environment, key string) (*Verifier, error) {
	if (environment != "local" && environment != "test") || len(key) < 32 {
		return nil, errors.New("development authentication requires local/test and a signing secret of at least 32 bytes")
	}
	return &Verifier{algorithm: "HS256", issuer: DevIssuer, audience: DevAudience, secret: []byte(key)}, nil
}

func RemoteVerifier(algorithm, issuer, audience, keysURL string) (*Verifier, error) {
	if algorithm != "RS256" && algorithm != "ES256" || strings.TrimSpace(audience) == "" {
		return nil, errors.New("invalid JWKS algorithm or audience")
	}
	for _, value := range []string{issuer, keysURL} {
		parsed, err := url.Parse(value)
		if err != nil || parsed.Scheme != "https" || parsed.Hostname() == "" || parsed.User != nil ||
			parsed.RawQuery != "" || parsed.Fragment != "" || parsed.ForceQuery {
			return nil, errors.New("issuer and JWKS URL must be trusted HTTPS URLs")
		}
	}
	return &Verifier{algorithm: algorithm, issuer: issuer, audience: audience, keysURL: keysURL,
		client: &http.Client{Timeout: 5 * time.Second, CheckRedirect: func(*http.Request, []*http.Request) error {
			return http.ErrUseLastResponse
		}}}, nil
}

func (v *Verifier) IssueDevelopmentToken(subject string) (string, error) {
	if len(v.secret) == 0 || !validSubject(subject) {
		return "", errors.New("valid development subject required")
	}
	now := time.Now()
	token := jwt.NewWithClaims(jwt.SigningMethodHS256, jwt.RegisteredClaims{
		Issuer: v.issuer, Subject: subject, Audience: jwt.ClaimStrings{v.audience},
		IssuedAt: jwt.NewNumericDate(now), ExpiresAt: jwt.NewNumericDate(now.Add(30 * time.Minute)),
	})
	return token.SignedString(v.secret)
}

func validSubject(subject string) bool {
	return strings.TrimSpace(subject) != "" && utf8.RuneCountInString(subject) <= 255
}

func (v *Verifier) Verify(ctx context.Context, token string) (Identity, error) {
	if len(token) > 16384 {
		return Identity{}, invalidToken
	}
	claims := new(jwt.RegisteredClaims)
	_, err := jwt.ParseWithClaims(token, claims, func(t *jwt.Token) (any, error) {
		if v.secret != nil {
			return v.secret, nil
		}
		kid, ok := t.Header["kid"].(string)
		if !ok || kid == "" {
			return nil, invalidToken
		}
		return v.publicKey(ctx, kid)
	}, jwt.WithValidMethods([]string{v.algorithm}), jwt.WithIssuer(v.issuer),
		jwt.WithAudience(v.audience), jwt.WithExpirationRequired(), jwt.WithIssuedAt())
	if errors.Is(err, authUnavailable) {
		return Identity{}, authUnavailable
	}
	if err != nil || !validSubject(claims.Subject) {
		return Identity{}, invalidToken
	}
	return Identity{claims.Issuer, claims.Subject}, nil
}

func (v *Verifier) publicKey(ctx context.Context, kid string) (any, error) {
	v.mu.Lock()
	defer v.mu.Unlock()
	if time.Now().Before(v.expires) {
		key, err := v.findKey(kid)
		if err == nil || time.Until(v.expires) > 4*time.Minute+55*time.Second {
			return key, err
		}
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, v.keysURL, nil)
	if err != nil {
		return nil, authUnavailable
	}
	res, err := v.client.Do(req)
	if err != nil {
		return nil, authUnavailable
	}
	defer res.Body.Close()
	if res.StatusCode != http.StatusOK {
		return nil, authUnavailable
	}
	var keySet struct {
		Keys []webKey `json:"keys"`
	}
	if err := json.NewDecoder(io.LimitReader(res.Body, 256*1024)).Decode(&keySet); err != nil {
		return nil, authUnavailable
	}
	v.keys = keySet.Keys
	v.expires = time.Now().Add(5 * time.Minute)
	return v.findKey(kid)
}

func (v *Verifier) findKey(kid string) (any, error) {
	for _, key := range v.keys {
		if key.ID != kid || key.Use != "" && key.Use != "sig" || key.Alg != "" && key.Alg != v.algorithm {
			continue
		}
		switch {
		case v.algorithm == "RS256" && key.KTY == "RSA":
			n, e := decodeInteger(key.N), decodeInteger(key.E)
			if n != nil && e != nil && n.BitLen() >= 2048 && e.IsInt64() && e.Int64() >= 3 && e.Int64() <= 2147483647 {
				return &rsa.PublicKey{N: n, E: int(e.Int64())}, nil
			}
		case v.algorithm == "ES256" && key.KTY == "EC" && key.Curve == "P-256":
			x, y := decodeInteger(key.X), decodeInteger(key.Y)
			curve := elliptic.P256()
			if x != nil && y != nil && curve.IsOnCurve(x, y) {
				return &ecdsa.PublicKey{Curve: curve, X: x, Y: y}, nil
			}
		}
	}
	return nil, invalidToken
}

func decodeInteger(s string) *big.Int {
	bytes, err := base64.RawURLEncoding.DecodeString(s)
	if err != nil || len(bytes) == 0 {
		return nil
	}
	return new(big.Int).SetBytes(bytes)
}
