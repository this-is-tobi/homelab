package vault

import (
	"bytes"
	"crypto/tls"
	"crypto/x509"
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"os"
	"strings"
	"time"
)

// AuthMethod defines supported Vault authentication methods.
//
// For multi-cluster deployments:
//   - JWT is recommended: uses K8s SA tokens validated via JWKS (no cross-cluster
//     API calls, automatic token rotation, one auth mount per cluster).
//   - AppRole works but requires distributing secret_id credentials to each
//     namespace and managing their rotation — more operational burden.
//   - Kubernetes auth only works same-cluster (Vault calls the K8s API directly).
type AuthMethod string

const (
	AuthKubernetes AuthMethod = "kubernetes"
	AuthJWT        AuthMethod = "jwt"
	AuthAppRole    AuthMethod = "approle"
	AuthToken      AuthMethod = "token"
)

// Client wraps the Vault HTTP API for KV-v2 operations.
type Client struct {
	addr   string
	token  string
	client *http.Client
}

// ClientConfig holds configuration for creating a Vault client.
type ClientConfig struct {
	Address       string
	CACertPath    string
	SkipTLSVerify bool
	Timeout       time.Duration
}

// NewClient creates a Vault client with the given TLS configuration.
func NewClient(cfg ClientConfig) (*Client, error) {
	tlsCfg := &tls.Config{
		InsecureSkipVerify: cfg.SkipTLSVerify, //nolint:gosec // user-controlled flag for internal clusters
	}

	if cfg.CACertPath != "" && !cfg.SkipTLSVerify {
		caCert, err := os.ReadFile(cfg.CACertPath)
		if err != nil {
			return nil, fmt.Errorf("read CA cert %s: %w", cfg.CACertPath, err)
		}
		pool := x509.NewCertPool()
		if !pool.AppendCertsFromPEM(caCert) {
			return nil, fmt.Errorf("failed to parse CA cert from %s", cfg.CACertPath)
		}
		tlsCfg.RootCAs = pool
	}

	timeout := cfg.Timeout
	if timeout == 0 {
		timeout = 30 * time.Second
	}

	return &Client{
		addr: strings.TrimRight(cfg.Address, "/"),
		client: &http.Client{
			Timeout: timeout,
			Transport: &http.Transport{
				TLSClientConfig: tlsCfg,
			},
		},
	}, nil
}

// Authenticate obtains a Vault token using the specified auth method.
func (c *Client) Authenticate(method AuthMethod, mount string, params map[string]string) error {
	switch method {
	case AuthKubernetes:
		return c.authKubernetes(mount, params)
	case AuthJWT:
		return c.authJWT(mount, params)
	case AuthAppRole:
		return c.authAppRole(mount, params)
	case AuthToken:
		return c.authToken(params)
	default:
		return fmt.Errorf("unsupported auth method: %s", method)
	}
}

// authKubernetes authenticates using a Kubernetes service account token.
// The SA token is read from the standard projected volume path.
func (c *Client) authKubernetes(mount string, params map[string]string) error {
	role := params["role"]
	if role == "" {
		return fmt.Errorf("kubernetes auth requires 'role' parameter")
	}

	tokenPath := params["token_path"]
	if tokenPath == "" {
		tokenPath = "/var/run/secrets/kubernetes.io/serviceaccount/token"
	}

	jwt, err := os.ReadFile(tokenPath)
	if err != nil {
		return fmt.Errorf("read SA token from %s: %w", tokenPath, err)
	}

	if mount == "" {
		mount = "kubernetes"
	}

	body := map[string]string{
		"role": role,
		"jwt":  string(jwt),
	}

	return c.doAuthLogin(mount, body)
}

// authJWT authenticates using a JWT token (recommended for multi-cluster).
// Uses the same SA token as kubernetes auth, but Vault validates it via JWKS
// instead of calling the K8s API — no cross-cluster network dependency.
func (c *Client) authJWT(mount string, params map[string]string) error {
	role := params["role"]
	if role == "" {
		return fmt.Errorf("jwt auth requires 'role' parameter")
	}

	tokenPath := params["token_path"]
	if tokenPath == "" {
		tokenPath = "/var/run/secrets/kubernetes.io/serviceaccount/token"
	}

	jwt, err := os.ReadFile(tokenPath)
	if err != nil {
		return fmt.Errorf("read JWT from %s: %w", tokenPath, err)
	}

	if mount == "" {
		mount = "jwt"
	}

	body := map[string]string{
		"role": role,
		"jwt":  string(jwt),
	}

	return c.doAuthLogin(mount, body)
}

// authAppRole authenticates using AppRole credentials.
// Requires role_id (static) and secret_id (dynamic, must be distributed to pods).
// Less recommended than JWT for multi-cluster: requires secret_id lifecycle
// management (distribution, rotation, TTL) whereas JWT uses existing SA tokens.
func (c *Client) authAppRole(mount string, params map[string]string) error {
	roleID := params["role_id"]
	secretID := params["secret_id"]
	if roleID == "" || secretID == "" {
		return fmt.Errorf("approle auth requires 'role_id' and 'secret_id' parameters")
	}

	if mount == "" {
		mount = "approle"
	}

	body := map[string]string{
		"role_id":   roleID,
		"secret_id": secretID,
	}

	return c.doAuthLogin(mount, body)
}

// authToken uses a pre-existing Vault token directly.
func (c *Client) authToken(params map[string]string) error {
	token := params["token"]
	if token == "" {
		token = os.Getenv("VAULT_TOKEN")
	}
	if token == "" {
		return fmt.Errorf("token auth requires 'token' parameter or VAULT_TOKEN env var")
	}
	c.token = token
	slog.Info("authenticated to Vault using token")
	return nil
}

func (c *Client) doAuthLogin(mount string, body map[string]string) error {
	path := fmt.Sprintf("/v1/auth/%s/login", mount)

	data, err := json.Marshal(body)
	if err != nil {
		return fmt.Errorf("marshal auth body: %w", err)
	}

	resp, err := c.rawRequest("POST", path, data)
	if err != nil {
		return fmt.Errorf("auth login to %s: %w", mount, err)
	}

	var result struct {
		Auth struct {
			ClientToken string `json:"client_token"`
		} `json:"auth"`
	}
	if err := json.Unmarshal(resp, &result); err != nil {
		return fmt.Errorf("decode auth response: %w", err)
	}

	if result.Auth.ClientToken == "" {
		return fmt.Errorf("auth login returned empty token (mount=%s)", mount)
	}

	c.token = result.Auth.ClientToken
	slog.Info("authenticated to Vault", "mount", mount)
	return nil
}

// KVGet reads a secret from a KV-v2 engine.
// Returns the data map (the nested .data.data from the API response).
func (c *Client) KVGet(mount, path string) (map[string]any, error) {
	apiPath := fmt.Sprintf("/v1/%s/data/%s", mount, path)

	resp, err := c.rawRequest("GET", apiPath, nil)
	if err != nil {
		// 404 means the secret doesn't exist
		if strings.Contains(err.Error(), "status 404") {
			return nil, nil
		}
		return nil, fmt.Errorf("KV get %s/%s: %w", mount, path, err)
	}

	var result struct {
		Data struct {
			Data map[string]any `json:"data"`
		} `json:"data"`
	}
	if err := json.Unmarshal(resp, &result); err != nil {
		return nil, fmt.Errorf("decode KV response for %s/%s: %w", mount, path, err)
	}

	return result.Data.Data, nil
}

// KVPut writes a secret to a KV-v2 engine.
func (c *Client) KVPut(mount, path string, data map[string]any) error {
	apiPath := fmt.Sprintf("/v1/%s/data/%s", mount, path)

	body := map[string]any{
		"data": data,
	}
	payload, err := json.Marshal(body)
	if err != nil {
		return fmt.Errorf("marshal KV data: %w", err)
	}

	_, err = c.rawRequest("POST", apiPath, payload)
	if err != nil {
		return fmt.Errorf("KV put %s/%s: %w", mount, path, err)
	}

	return nil
}

// Health checks if Vault is initialized and unsealed.
func (c *Client) Health() error {
	resp, err := c.rawRequest("GET", "/v1/sys/health", nil)
	if err != nil {
		// Health endpoint returns non-200 for sealed/standby but still valid JSON
		if resp != nil {
			var health struct {
				Initialized bool `json:"initialized"`
				Sealed      bool `json:"sealed"`
			}
			if json.Unmarshal(resp, &health) == nil {
				if !health.Initialized {
					return fmt.Errorf("vault is not initialized")
				}
				if health.Sealed {
					return fmt.Errorf("vault is sealed")
				}
			}
		}
		return fmt.Errorf("vault health check: %w", err)
	}
	return nil
}

func (c *Client) rawRequest(method, path string, body []byte) ([]byte, error) {
	url := c.addr + path

	var bodyReader io.Reader
	if body != nil {
		bodyReader = bytes.NewReader(body)
	}

	req, err := http.NewRequest(method, url, bodyReader)
	if err != nil {
		return nil, fmt.Errorf("create request: %w", err)
	}

	if c.token != "" {
		req.Header.Set("X-Vault-Token", c.token)
	}
	if body != nil {
		req.Header.Set("Content-Type", "application/json")
	}

	resp, err := c.client.Do(req)
	if err != nil {
		return nil, fmt.Errorf("HTTP %s %s: %w", method, path, err)
	}
	defer resp.Body.Close()

	respBody, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, fmt.Errorf("read response body: %w", err)
	}

	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		// Try to extract Vault error messages
		var vaultErr struct {
			Errors []string `json:"errors"`
		}
		if json.Unmarshal(respBody, &vaultErr) == nil && len(vaultErr.Errors) > 0 {
			return respBody, fmt.Errorf("status %d: %s", resp.StatusCode, strings.Join(vaultErr.Errors, "; "))
		}
		return respBody, fmt.Errorf("status %d: %s", resp.StatusCode, string(respBody))
	}

	return respBody, nil
}
