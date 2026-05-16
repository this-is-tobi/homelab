package cmd

import (
	"fmt"
	"log/slog"
	"os"
	"time"

	"github.com/spf13/cobra"
	"github.com/this-is-tobi/homelab/utils/internal/harbor"
	"github.com/this-is-tobi/homelab/utils/internal/k8s"
)

var harborCmd = &cobra.Command{
	Use:   "harbor",
	Short: "Harbor post-install configuration",
	Long: `Configure Harbor with Keycloak OIDC authentication and Trivy scanning.

Loads credentials from Kubernetes secrets (when in-cluster) or environment variables.

Environment variables:
  HARBOR_DOMAIN, HARBOR_USERNAME, HARBOR_PASSWORD
  HARBOR_CLIENT_ID, HARBOR_CLIENT_SECRET
  KEYCLOAK_DOMAIN, KEYCLOAK_REALM
  HARBOR_NAMESPACE, HARBOR_SECRET_NAME
  KEYCLOAK_NAMESPACE, KEYCLOAK_SECRET_NAME`,
	RunE: runHarborConfig,
}

var (
	harborDomain       string
	harborUsername     string
	harborPassword     string
	harborClientID     string
	harborClientSecret string
	keycloakDomain     string
	keycloakRealm      string
	harborNamespace    string
	harborSecretName   string
	keycloakNamespace  string
	keycloakSecretName string
)

func init() {
	rootCmd.AddCommand(harborCmd)

	f := harborCmd.Flags()
	f.StringVar(&harborDomain, "domain", os.Getenv("HARBOR_DOMAIN"), "Harbor domain")
	f.StringVar(&harborUsername, "username", os.Getenv("HARBOR_USERNAME"), "Harbor admin username")
	f.StringVar(&harborPassword, "password", "", "Harbor admin password (use env HARBOR_PASSWORD)")
	f.StringVar(&harborClientID, "client-id", os.Getenv("HARBOR_CLIENT_ID"), "OIDC client ID")
	f.StringVar(&harborClientSecret, "client-secret", "", "OIDC client secret (use env HARBOR_CLIENT_SECRET)")
	f.StringVar(&keycloakDomain, "keycloak-domain", os.Getenv("KEYCLOAK_DOMAIN"), "Keycloak domain")
	f.StringVar(&keycloakRealm, "keycloak-realm", os.Getenv("KEYCLOAK_REALM"), "Keycloak realm")
	f.StringVar(&harborNamespace, "harbor-namespace", envOrDefault("HARBOR_NAMESPACE", "harbor"), "Harbor K8s namespace")
	f.StringVar(&harborSecretName, "harbor-secret", envOrDefault("HARBOR_SECRET_NAME", "harbor-secret"), "Harbor K8s secret name")
	f.StringVar(&keycloakNamespace, "keycloak-namespace", envOrDefault("KEYCLOAK_NAMESPACE", "keycloak-system"), "Keycloak K8s namespace")
	f.StringVar(&keycloakSecretName, "keycloak-secret", envOrDefault("KEYCLOAK_SECRET_NAME", "keycloak-secret"), "Keycloak K8s secret name")
}

func runHarborConfig(cmd *cobra.Command, args []string) error {
	// Try loading missing config from K8s secrets
	if err := loadHarborFromK8s(); err != nil {
		slog.Debug("could not load from K8s secrets (may be running locally)", "error", err)
	}

	// Fall back to env vars for secrets (never passed as CLI flags)
	if harborPassword == "" {
		harborPassword = os.Getenv("HARBOR_PASSWORD")
	}
	if harborClientSecret == "" {
		harborClientSecret = os.Getenv("HARBOR_CLIENT_SECRET")
	}

	cfg := harbor.Config{
		Domain:         harborDomain,
		Username:       harborUsername,
		Password:       harborPassword,
		ClientID:       harborClientID,
		ClientSecret:   harborClientSecret,
		KeycloakDomain: keycloakDomain,
		KeycloakRealm:  keycloakRealm,
		MaxRetries:     5,
		RetryDelay:     10 * time.Second,
		HTTPTimeout:    30 * time.Second,
	}

	if err := harbor.Configure(cfg); err != nil {
		return fmt.Errorf("harbor configuration failed: %w", err)
	}

	return nil
}

func loadHarborFromK8s() error {
	client, err := k8s.NewInClusterClient()
	if err != nil {
		return err
	}

	// Load harbor secret
	if harborDomain == "" || harborUsername == "" {
		secret, err := client.GetSecret(harborNamespace, harborSecretName)
		if err != nil {
			return fmt.Errorf("load harbor secret: %w", err)
		}
		if harborDomain == "" {
			harborDomain = secret["domain"]
		}
		if harborUsername == "" {
			harborUsername = secret["admin.username"]
		}
		if harborPassword == "" {
			harborPassword = secret["admin.password"]
		}
		if harborClientID == "" {
			harborClientID = secret["keycloak.clientId"]
		}
		if harborClientSecret == "" {
			harborClientSecret = secret["keycloak.clientSecret"]
		}
	}

	// Load keycloak secret
	if keycloakDomain == "" || keycloakRealm == "" {
		secret, err := client.GetSecret(keycloakNamespace, keycloakSecretName)
		if err != nil {
			return fmt.Errorf("load keycloak secret: %w", err)
		}
		if keycloakDomain == "" {
			keycloakDomain = secret["domain"]
		}
		if keycloakRealm == "" {
			keycloakRealm = secret["realm"]
		}
	}

	return nil
}
