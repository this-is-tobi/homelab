package cmd

import (
	"encoding/json"
	"fmt"
	"log/slog"
	"os"
	"time"

	"github.com/spf13/cobra"
	"github.com/this-is-tobi/homelab/utils/internal/vault"
)

var vaultIdentityCmd = &cobra.Command{
	Use:   "identity",
	Short: "Configure Vault identity groups and aliases from JSON config",
	Long: `Configure Vault identity groups and group-aliases using a declarative JSON configuration.

Creates identity groups with attached policies and group-aliases that map external
identity claims (e.g., OIDC group claims from Keycloak) to internal Vault groups.
This enables OIDC users with specific group memberships to receive policy-based access.

Config format (JSON):
  {
    "groups": [
      {
        "name": "homelab-admins",
        "policies": ["admin", "reader"]
      }
    ],
    "groupAliases": [
      {
        "name": "/admin",
        "group": "homelab-admins",
        "mountAccessor": "oidc_xxxxx"
      }
    ]
  }

The "name" in groupAliases should match the external claim value (e.g., Keycloak group path).
The "group" field references the group name defined in the groups section.
The "mountAccessor" is the Vault auth mount accessor. If empty, it will be auto-discovered
by searching for the first auth mount of type 'oidc' (retrieve manually via: vault auth list -format=json).`,
	RunE: runVaultIdentity,
}

var (
	identityConfigFile string
	identityDryRun     bool
)

func init() {
	vaultCmd.AddCommand(vaultIdentityCmd)

	f := vaultIdentityCmd.Flags()
	f.StringVar(&vaultAddr, "vault-addr", envOrDefault("VAULT_ADDR", ""), "Vault server address")
	f.StringVar(&vaultCACert, "ca-cert", envOrDefault("VAULT_CACERT", ""), "path to Vault CA certificate")
	f.BoolVar(&vaultSkipTLS, "skip-tls-verify", os.Getenv("VAULT_SKIP_VERIFY") == "true", "skip TLS verification")
	f.StringVar(&vaultAuthMethod, "auth-method", envOrDefault("VAULT_AUTH_METHOD", "kubernetes"), "auth method: kubernetes, jwt, approle, token")
	f.StringVar(&vaultAuthMount, "auth-mount", envOrDefault("VAULT_AUTH_MOUNT", ""), "auth mount path (defaults to method name)")
	f.StringVar(&vaultRole, "role", envOrDefault("VAULT_ROLE", "vault-post-config"), "Vault auth role name")
	f.StringVar(&vaultToken, "token", "", "Vault token (for token auth, or use VAULT_TOKEN env)")
	f.StringVar(&vaultRoleID, "role-id", envOrDefault("VAULT_ROLE_ID", ""), "AppRole role ID")
	f.StringVar(&vaultSecretID, "secret-id", envOrDefault("VAULT_SECRET_ID", ""), "AppRole secret ID")
	f.StringVar(&identityConfigFile, "config", envOrDefault("IDENTITY_FILE", ""), "path to identity config JSON file")
	f.BoolVar(&identityDryRun, "dry-run", false, "print what would be done without writing to Vault")

	_ = vaultIdentityCmd.MarkFlagRequired("config")
}

func runVaultIdentity(cmd *cobra.Command, args []string) error {
	// Validate Vault address
	if vaultAddr == "" {
		return fmt.Errorf("--vault-addr is required or set VAULT_ADDR env var")
	}

	// Read config file
	configData, err := os.ReadFile(identityConfigFile)
	if err != nil {
		return fmt.Errorf("read identity config file %s: %w", identityConfigFile, err)
	}

	var config struct {
		Groups       []Group       `json:"groups"`
		GroupAliases []GroupAlias  `json:"groupAliases"`
	}
	if err := json.Unmarshal(configData, &config); err != nil {
		return fmt.Errorf("parse identity config: %w", err)
	}

	if len(config.Groups) == 0 && len(config.GroupAliases) == 0 {
		slog.Info("identity config is empty, nothing to do")
		return nil
	}

	if identityDryRun {
		slog.Info("DRY RUN: would create", "groups", len(config.Groups), "aliases", len(config.GroupAliases))
		for _, g := range config.Groups {
			fmt.Printf("[DRY RUN] Create group: %s with policies: %v\n", g.Name, g.Policies)
		}
		for _, a := range config.GroupAliases {
			fmt.Printf("[DRY RUN] Create group-alias: %s -> %s (mount: %s)\n", a.Name, a.Group, a.MountAccessor)
		}
		return nil
	}

	// Create Vault client
	client, err := vault.NewClient(vault.ClientConfig{
		Address:       vaultAddr,
		CACertPath:    vaultCACert,
		SkipTLSVerify: vaultSkipTLS,
		Timeout:       30 * time.Second,
	})
	if err != nil {
		return fmt.Errorf("create vault client: %w", err)
	}

	// Check Vault health
	if err := client.Health(); err != nil {
		return fmt.Errorf("vault health check: %w", err)
	}

	// Authenticate
	authParams := map[string]string{
		"role":       vaultRole,
		"token":      vaultToken,
		"role_id":    vaultRoleID,
		"secret_id":  vaultSecretID,
	}
	if err := client.Authenticate(vault.AuthMethod(vaultAuthMethod), vaultAuthMount, authParams); err != nil {
		return fmt.Errorf("authenticate to vault: %w", err)
	}

	// Track group IDs for aliases
	groupIDs := make(map[string]string)

	// Create groups
	for _, group := range config.Groups {
		groupID, err := client.IdentityCreateGroup(group.Name, group.Policies)
		if err != nil {
			return fmt.Errorf("create group %s: %w", group.Name, err)
		}
		groupIDs[group.Name] = groupID
	}

	// Create group-aliases
	for _, alias := range config.GroupAliases {
		groupID, ok := groupIDs[alias.Group]
		if !ok {
			return fmt.Errorf("group %s referenced by alias %s not found in config", alias.Group, alias.Name)
		}

		// Auto-discover mount accessor if not provided
		mountAccessor := alias.MountAccessor
		if mountAccessor == "" {
			slog.Info("auto-discovering auth mount accessor", "alias_name", alias.Name)
			// Try to detect auth type from alias name (e.g., "/admin" suggests OIDC group claim)
			// Default to "oidc" if no explicit mount accessor provided
			discovered, err := client.GetAuthMountAccessor("oidc", "")
			if err != nil {
				return fmt.Errorf("auto-discover mount accessor for alias %s: %w", alias.Name, err)
			}
			mountAccessor = discovered
		}

		if err := client.IdentityCreateGroupAlias(alias.Name, groupID, mountAccessor); err != nil {
			return fmt.Errorf("create group-alias %s: %w", alias.Name, err)
		}
	}

	slog.Info("identity configuration applied successfully", "groups", len(config.Groups), "aliases", len(config.GroupAliases))
	return nil
}

// Group represents an identity group configuration.
type Group struct {
	Name     string   `json:"name"`
	Policies []string `json:"policies"`
}

// GroupAlias represents a group-alias configuration that maps external identities
// (e.g., OIDC group claims) to internal Vault groups.
type GroupAlias struct {
	Name           string `json:"name"`
	Group          string `json:"group"`
	MountAccessor  string `json:"mountAccessor"`
}
