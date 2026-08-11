// Optional FCM transport for the event feed.
//
// The relay's contract with a companion device is "there is something new in
// your event feed" — never the notification itself. Arc renders every alert
// locally, in its own voice, on its own channels, with its own icon and accent,
// so a moment that arrived by push and a moment that arrived by poll are
// indistinguishable on screen and the copy lives in exactly one place (Dart).
// That makes this file a *wake signal*, and its absence merely slower delivery:
// with no credentials configured the pusher is a no-op and companions still
// receive every event on their next poll.
//
// Enable by pointing ARC_FCM_CREDENTIALS at a Firebase service-account JSON
// (Project settings → Service accounts → Generate new private key). Everything
// below is stdlib — no Google SDK, no new module dependency.

package main

import (
	"bytes"
	"context"
	"crypto"
	"crypto/rand"
	"crypto/rsa"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	"net/url"
	"os"
	"strings"
	"sync"
	"time"
)

const (
	fcmScope    = "https://www.googleapis.com/auth/firebase.messaging"
	fcmSendFmt  = "https://fcm.googleapis.com/v1/projects/%s/messages:send"
	fcmTimeout  = 15 * time.Second
	tokenExpiry = time.Hour
)

// Pusher nudges devices to pull their event feed now rather than at their next
// poll. Wake never blocks the caller and never reports failure: a push that
// doesn't land costs latency, not delivery.
type Pusher interface {
	Wake(users []string)
}

// noopPusher is the shipped default — polling handles delivery on its own.
type noopPusher struct{}

func (noopPusher) Wake([]string) {}

// NewPusher returns an FCM pusher when a service-account file is configured and
// readable, and a no-op otherwise. A misconfigured path is logged once and then
// behaves exactly like an unconfigured one: push is an accelerator, and a typo
// in a deployment variable must not take the relay down with it.
func NewPusher(store *Store) Pusher {
	path := os.Getenv("ARC_FCM_CREDENTIALS")
	if path == "" {
		path = os.Getenv("GOOGLE_APPLICATION_CREDENTIALS")
	}
	if path == "" {
		log.Printf("push: no FCM credentials configured — companions poll for events")
		return noopPusher{}
	}
	raw, err := os.ReadFile(path)
	if err != nil {
		log.Printf("push: cannot read %s (%v) — falling back to polling", path, err)
		return noopPusher{}
	}
	var sa serviceAccount
	if err := json.Unmarshal(raw, &sa); err != nil {
		log.Printf("push: %s is not a service-account JSON (%v) — falling back to polling", path, err)
		return noopPusher{}
	}
	key, err := parsePrivateKey(sa.PrivateKey)
	if err != nil {
		log.Printf("push: %s has an unusable private_key (%v) — falling back to polling", path, err)
		return noopPusher{}
	}
	if sa.ProjectID == "" || sa.ClientEmail == "" {
		log.Printf("push: %s is missing project_id or client_email — falling back to polling", path)
		return noopPusher{}
	}
	if sa.TokenURI == "" {
		sa.TokenURI = "https://oauth2.googleapis.com/token"
	}
	log.Printf("push: FCM enabled for project %s", sa.ProjectID)
	return &fcmPusher{
		store:  store,
		sa:     sa,
		key:    key,
		client: &http.Client{Timeout: fcmTimeout},
	}
}

type serviceAccount struct {
	ProjectID   string `json:"project_id"`
	ClientEmail string `json:"client_email"`
	PrivateKey  string `json:"private_key"`
	TokenURI    string `json:"token_uri"`
}

type fcmPusher struct {
	store  *Store
	sa     serviceAccount
	key    *rsa.PrivateKey
	client *http.Client

	mu          sync.Mutex
	accessToken string
	tokenGoodTo time.Time
}

// Wake fans a data-only high-priority message out to every device registered to
// [users]. Runs detached: publishing an event must not wait on Google.
func (p *fcmPusher) Wake(users []string) {
	if len(users) == 0 {
		return
	}
	go func() {
		ctx, cancel := context.WithTimeout(context.Background(), fcmTimeout*2)
		defer cancel()

		tokens, err := p.store.DeviceTokens(ctx, users)
		if err != nil || len(tokens) == 0 {
			return
		}
		access, err := p.accessTokenFor(ctx)
		if err != nil {
			log.Printf("push: token exchange failed: %v", err)
			return
		}
		for _, t := range tokens {
			if err := p.send(ctx, access, t); err != nil {
				log.Printf("push: send failed: %v", err)
			}
		}
	}()
}

// send delivers the wake signal to one device. The message carries no title or
// body on purpose — see the file header.
func (p *fcmPusher) send(ctx context.Context, access, deviceToken string) error {
	body, err := json.Marshal(map[string]any{
		"message": map[string]any{
			"token": deviceToken,
			"data":  map[string]string{"arc": "events"},
			"android": map[string]any{
				"priority": "HIGH",
			},
		},
	})
	if err != nil {
		return err
	}
	url := fmt.Sprintf(fcmSendFmt, p.sa.ProjectID)
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, url, bytes.NewReader(body))
	if err != nil {
		return err
	}
	req.Header.Set("Authorization", "Bearer "+access)
	req.Header.Set("Content-Type", "application/json")

	resp, err := p.client.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode >= 200 && resp.StatusCode < 300 {
		return nil
	}
	msg, _ := io.ReadAll(io.LimitReader(resp.Body, 2<<10))
	// FCM reports a token that belongs to an uninstalled or reset app as 404
	// (UNREGISTERED) or 400 (INVALID_ARGUMENT). Reap it rather than retrying a
	// dead address on every future event.
	if resp.StatusCode == http.StatusNotFound ||
		(resp.StatusCode == http.StatusBadRequest && strings.Contains(string(msg), "INVALID_ARGUMENT")) {
		_ = p.store.reapDevice(ctx, deviceToken)
		return nil
	}
	return fmt.Errorf("fcm %d: %s", resp.StatusCode, strings.TrimSpace(string(msg)))
}

// accessTokenFor returns a cached OAuth2 access token, minting a new one via the
// service-account JWT grant when the current one is spent.
func (p *fcmPusher) accessTokenFor(ctx context.Context) (string, error) {
	p.mu.Lock()
	defer p.mu.Unlock()
	// A minute of headroom: a token that expires mid-flight reads as an auth
	// failure and loses the batch.
	if p.accessToken != "" && time.Now().Before(p.tokenGoodTo.Add(-time.Minute)) {
		return p.accessToken, nil
	}

	assertion, err := p.signedJWT()
	if err != nil {
		return "", err
	}
	form := url.Values{
		"grant_type": {"urn:ietf:params:oauth:grant-type:jwt-bearer"},
		"assertion":  {assertion},
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, p.sa.TokenURI,
		strings.NewReader(form.Encode()))
	if err != nil {
		return "", err
	}
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")

	resp, err := p.client.Do(req)
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()
	raw, _ := io.ReadAll(io.LimitReader(resp.Body, 8<<10))
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return "", fmt.Errorf("oauth %d: %s", resp.StatusCode, strings.TrimSpace(string(raw)))
	}
	var out struct {
		AccessToken string `json:"access_token"`
		ExpiresIn   int64  `json:"expires_in"`
	}
	if err := json.Unmarshal(raw, &out); err != nil {
		return "", err
	}
	if out.AccessToken == "" {
		return "", errors.New("oauth response carried no access_token")
	}
	ttl := time.Duration(out.ExpiresIn) * time.Second
	if ttl <= 0 {
		ttl = tokenExpiry
	}
	p.accessToken = out.AccessToken
	p.tokenGoodTo = time.Now().Add(ttl)
	return p.accessToken, nil
}

// signedJWT builds the RS256 self-signed assertion Google exchanges for an
// access token.
func (p *fcmPusher) signedJWT() (string, error) {
	now := time.Now()
	header := b64u(`{"alg":"RS256","typ":"JWT"}`)
	claims, err := json.Marshal(map[string]any{
		"iss":   p.sa.ClientEmail,
		"scope": fcmScope,
		"aud":   p.sa.TokenURI,
		"iat":   now.Unix(),
		"exp":   now.Add(tokenExpiry).Unix(),
	})
	if err != nil {
		return "", err
	}
	signing := header + "." + b64u(string(claims))
	sum := sha256.Sum256([]byte(signing))
	sig, err := rsa.SignPKCS1v15(rand.Reader, p.key, crypto.SHA256, sum[:])
	if err != nil {
		return "", err
	}
	return signing + "." + base64.RawURLEncoding.EncodeToString(sig), nil
}

func b64u(s string) string {
	return base64.RawURLEncoding.EncodeToString([]byte(s))
}

// parsePrivateKey reads the PEM block Google ships in `private_key`. Current
// keys are PKCS#8; PKCS#1 is accepted for older downloads.
func parsePrivateKey(pemStr string) (*rsa.PrivateKey, error) {
	block, _ := pem.Decode([]byte(pemStr))
	if block == nil {
		return nil, errors.New("private_key is not PEM")
	}
	if key, err := x509.ParsePKCS8PrivateKey(block.Bytes); err == nil {
		rsaKey, ok := key.(*rsa.PrivateKey)
		if !ok {
			return nil, errors.New("private_key is not RSA")
		}
		return rsaKey, nil
	}
	return x509.ParsePKCS1PrivateKey(block.Bytes)
}
