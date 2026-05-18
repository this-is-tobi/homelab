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

// IdentityCreateGroup creates or updates an identity group with policies.
// Idempotent: updates existing group if it already exists.
func (c *Client) IdentityCreateGroup(name string, policies []string) (string, error) {
	path := "/v1/identity/group"
	body := map[string]any{
		"name":     name,
		"policies": policies,
	}
	payload, err := json.Marshal(body)
	if err != nil {
		return "", fmt.Errorf("marshal group data: %w", err)
	}

	resp, err := c.rawRequest("POST", path, payload)
	if err != nil {
		return "", fmt.Errorf("create group %s: %w", name, err)
	}

	var result struct {
		Data struct {
			ID string `json:"id"`
		} `json:"data"`
	}
	if err := json.Unmarshal(resp, &result); err != nil {
		return "", fmt.Errorf("decode group response: %w", err)
	}

	if result.Data.ID == "" {
		return "", fmt.Errorf("group creation returned empty ID for %s", name)
	}

	slog.Info("created/updated identity group", "name", name, "id", result.Data.ID, "policies", policies)
	return result.Data.ID, nil
}

// IdentityCreateGroupAlias creates or updates a group alias mapping an external
// identity claim (e.g., OIDC group claim) to an internal group.
// Idempotent: updates existing alias if it already exists.
func (c *Client) IdentityCreateGroupAlias(name, groupID, mountAccessor string) error {
	path := "/v1/identity/group-alias"
	body := map[string]string{
		"name":             name,
		"canonical_id":     groupID,
		"mount_accessor":   mountAccessor,
	}
	payload, err := json.Marshal(body)
	if err != nil {
		return fmt.Errorf("marshal group-alias data: %w", err)
	}

	_, err = c.rawRequest("POST", path, payload)
	if err != nil {
		return fmt.Errorf("create group-alias %s: %w", name, err)
	}

	slog.Info("created/updated group-alias", "name", name, "group_id", groupID, "mount_accessor", mountAccessor)
	return nil
}

// GetAuthMountAccessor retrieves the accessor ID for an auth mount by type and path.
// If path is empty, returns the first matching auth mount of that type.
// Returns empty string if mount not found.
func (c *Client) GetAuthMountAccessor(authType, authPath string) (string, error) {
	path := "/v1/sys/auth"
	resp, err := c.rawRequest("GET", path, nil)
	if err != nil {
		return "", fmt.Errorf("list auth mounts: %w", err)
	}

	type AuthMount struct {
		Accessor string `json:"accessor"`
		Type     string `json:"type"`
		Path     string `json:"path"`
	}

	type AuthMounts map[string]AuthMount

	var result struct {
		Data AuthMounts `json:"data"`
	}
	if err := json.Unmarshal(resp, &result); err != nil {
		return "", fmt.Errorf("decode auth mounts response: %w", err)
	}

	// If specific path provided, return its accessor
	if authPath != "" {
		// Normalize path (add trailing slash if needed)
		if !strings.HasSuffix(authPath, "/") {
			authPath += "/"
		}
		if mount, ok := result.Data[authPath]; ok && mount.Type == authType {
			return mount.Accessor, nil
		}
		return "", fmt.Errorf("auth mount not found: type=%s, path=%s", authType, authPath)
	}

	// Find first matching auth type
	for path, mount := range result.Data {
		if mount.Type == authType {
			slog.Info("found auth mount", "type", authType, "path", path, "accessor", mount.Accessor)
			return mount.Accessor, nil
		}
	}

	return "", fmt.Errorf("no auth mount found of type %s", authType)
}

// GetLeaderAddress discovers the active Vault leader node address by querying /v1/sys/leader.
// Returns the leader's address URL, or empty string if discovery fails.
// No authentication required for this endpoint.
func (c *Client) GetLeaderAddress() (string, error) {
	path := "/v1/sys/leader"
	resp, err := c.rawRequest("GET", path, nil)
	if err != nil {
		return "", fmt.Errorf("query leader endpoint: %w", err)
	}

	var result struct {
		LeaderAddress string `json:"leader_address"`
	}
	if err := json.Unmarshal(resp, &result); err != nil {
		return "", fmt.Errorf("decode leader response: %w", err)
	}

	if result.LeaderAddress == "" {
		return "", fmt.Errorf("no active leader found")
	}

	return result.LeaderAddress, nil
}

func (c *Client) rawRequest(method, path string, body []byte) ([]byte, error) {
	// Retry logic for transient errors
	const maxRetries = 3
	backoff := time.Millisecond * 100

	for attempt := 0; attempt < maxRetries; attempt++ {
		if attempt > 0 {
			slog.Debug("retrying request after backoff", "attempt", attempt, "delay", backoff)
			time.Sleep(backoff)
			backoff = time.Duration(float64(backoff) * 2) // exponential backoff
		}

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
			// 429 is retryable (transient rate-limiting)
			if resp.StatusCode == 429 && attempt < maxRetries-1 {
				slog.Debug("got 429, will retry", "attempt", attempt+1)
				continue
			}

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

	return nil, fmt.Errorf("max retries exceeded")
}
