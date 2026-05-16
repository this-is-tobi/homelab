package vault

import (
	"crypto/rand"
	"encoding/json"
	"fmt"
	"math/big"
	"regexp"
	"strings"

	"filippo.io/age"
	"github.com/google/uuid"
)

const alphanumeric = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"

var (
	reRandom = regexp.MustCompile(`<random:(\d+)>`)
	reUUID   = regexp.MustCompile(`<uuid>`)
	reAge    = regexp.MustCompile(`<age:(secret|public)>`)
	reRef    = regexp.MustCompile(`<ref:([^#]+)#([^>]+)>`)
)

// TemplateEngine processes placeholder strings in secret data.
//
// Supported placeholders:
//
//	<random:N>   — cryptographically random alphanumeric string of length N
//	<uuid>       — random UUID v4
//	<age:secret> — age X25519 secret key (generated once per Process call)
//	<age:public> — age X25519 public key (paired with the secret key)
//	<ref:path#key.path> — reference a value from another Vault secret
type TemplateEngine struct {
	vaultClient *Client // for resolving <ref:...> placeholders
	ageIdentity *age.X25519Identity
}

// NewTemplateEngine creates a template engine with an optional Vault client
// for resolving cross-references.
func NewTemplateEngine(vaultClient *Client) *TemplateEngine {
	return &TemplateEngine{
		vaultClient: vaultClient,
	}
}

// Process walks a data map and replaces all placeholder strings with generated values.
// Each call resets the age keypair so that <age:secret> and <age:public> are paired.
func (e *TemplateEngine) Process(data map[string]any) (map[string]any, error) {
	e.ageIdentity = nil // reset per-secret age keypair
	return e.processMap(data)
}

func (e *TemplateEngine) processMap(data map[string]any) (map[string]any, error) {
	result := make(map[string]any, len(data))
	for k, v := range data {
		processed, err := e.processValue(v)
		if err != nil {
			return nil, fmt.Errorf("key %q: %w", k, err)
		}
		result[k] = processed
	}
	return result, nil
}

func (e *TemplateEngine) processValue(v any) (any, error) {
	switch val := v.(type) {
	case string:
		return e.processString(val)
	case map[string]any:
		return e.processMap(val)
	case []any:
		result := make([]any, len(val))
		for i, item := range val {
			processed, err := e.processValue(item)
			if err != nil {
				return nil, fmt.Errorf("index %d: %w", i, err)
			}
			result[i] = processed
		}
		return result, nil
	default:
		return v, nil
	}
}

func (e *TemplateEngine) processString(s string) (string, error) {
	var err error

	// Replace all <random:N> (each gets a unique value)
	s = reRandom.ReplaceAllStringFunc(s, func(match string) string {
		if err != nil {
			return match
		}
		sub := reRandom.FindStringSubmatch(match)
		var n int
		if _, e := fmt.Sscanf(sub[1], "%d", &n); e != nil {
			err = fmt.Errorf("invalid random length %q: %w", sub[1], e)
			return match
		}
		val, e := generateRandom(n)
		if e != nil {
			err = fmt.Errorf("generate random(%d): %w", n, e)
			return match
		}
		return val
	})
	if err != nil {
		return "", err
	}

	// Replace all <uuid> (each gets a unique value)
	s = reUUID.ReplaceAllStringFunc(s, func(_ string) string {
		return uuid.New().String()
	})

	// Replace <age:secret> and <age:public>
	if reAge.MatchString(s) {
		if e.ageIdentity == nil {
			identity, genErr := age.GenerateX25519Identity()
			if genErr != nil {
				return "", fmt.Errorf("generate age keypair: %w", genErr)
			}
			e.ageIdentity = identity
		}
		s = strings.ReplaceAll(s, "<age:secret>", e.ageIdentity.String())
		s = strings.ReplaceAll(s, "<age:public>", e.ageIdentity.Recipient().String())
	}

	// Replace <ref:path#key.path>
	if reRef.MatchString(s) {
		s, err = e.resolveRefs(s)
		if err != nil {
			return "", err
		}
	}

	return s, nil
}

// resolveRefs resolves all <ref:vaultPath#dotPath> placeholders by reading from Vault.
func (e *TemplateEngine) resolveRefs(s string) (string, error) {
	if e.vaultClient == nil {
		return "", fmt.Errorf("cannot resolve <ref:...>: no Vault client configured")
	}

	var refErr error
	result := reRef.ReplaceAllStringFunc(s, func(match string) string {
		if refErr != nil {
			return match
		}

		sub := reRef.FindStringSubmatch(match)
		vaultPath := sub[1]
		keyPath := sub[2]

		// Split vaultPath into mount and secret path.
		// Convention: first path segment is the mount, rest is the path.
		parts := strings.SplitN(vaultPath, "/", 2)
		if len(parts) < 2 {
			refErr = fmt.Errorf("invalid ref vault path %q in %s", vaultPath, match)
			return match
		}
		mount := parts[0]
		secretPath := parts[1]

		data, err := e.vaultClient.KVGet(mount, secretPath)
		if err != nil {
			refErr = fmt.Errorf("failed to read ref %s from Vault: %w", match, err)
			return match
		}
		if data == nil {
			refErr = fmt.Errorf("ref secret not found in Vault: %s (path %s)", match, vaultPath)
			return match
		}

		val := navigateJSON(data, keyPath)
		if val == "" {
			refErr = fmt.Errorf("ref key path %q not found or empty in %s", keyPath, match)
			return match
		}
		return val
	})

	if refErr != nil {
		return "", refErr
	}
	return result, nil
}

// navigateJSON traverses a nested map using a dot-separated key path.
func navigateJSON(data map[string]any, dotPath string) string {
	keys := strings.Split(dotPath, ".")
	var current any = data

	for _, key := range keys {
		m, ok := current.(map[string]any)
		if !ok {
			return ""
		}
		current, ok = m[key]
		if !ok {
			return ""
		}
	}

	switch v := current.(type) {
	case string:
		return v
	case json.Number:
		return v.String()
	case float64:
		return fmt.Sprintf("%v", v)
	case bool:
		return fmt.Sprintf("%v", v)
	default:
		// For complex types, marshal to JSON string
		b, err := json.Marshal(v)
		if err != nil {
			return ""
		}
		return string(b)
	}
}

// generateRandom produces a cryptographically random alphanumeric string.
func generateRandom(length int) (string, error) {
	if length <= 0 {
		return "", fmt.Errorf("length must be positive, got %d", length)
	}

	result := make([]byte, length)
	max := big.NewInt(int64(len(alphanumeric)))

	for i := range result {
		n, err := rand.Int(rand.Reader, max)
		if err != nil {
			return "", fmt.Errorf("crypto/rand: %w", err)
		}
		result[i] = alphanumeric[n.Int64()]
	}

	return string(result), nil
}
