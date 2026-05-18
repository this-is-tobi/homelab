package cmd

import (
	"fmt"
	"log/slog"

	"github.com/spf13/cobra"
	"github.com/this-is-tobi/homelab/utils/internal/vault"
)

// vaultLeaderCmd discovers and returns the address of the active Vault leader node.
var vaultLeaderCmd = &cobra.Command{
	Use:   "leader",
	Short: "Discover the active Vault leader node address",
	Long: `Discover and print the address of the active Vault leader node.

This command queries /v1/sys/leader (no authentication required) to determine
which Vault node is currently the active leader in an HA cluster.

Useful for targeting requests to the leader node directly, avoiding
rate-limiting (429) responses from standby nodes.

Example:
  ohmlab vault leader --vault-addr=https://vault.default.svc.cluster.local:8200
  # Output: https://vault-0.vault.default.svc.cluster.local:8200
`,
	RunE: runVaultLeader,
}

func runVaultLeader(cmd *cobra.Command, args []string) error {
	vaultAddr := cmd.Flag("vault-addr").Value.String()
	skipTLSVerify := cmd.Flag("skip-tls-verify").Value.String() == "true"
	caCert := cmd.Flag("ca-cert").Value.String()

	if vaultAddr == "" {
		return fmt.Errorf("--vault-addr is required")
	}

	// Create client (no auth needed for leader discovery)
	client, err := vault.NewClient(vault.ClientConfig{
		Address:       vaultAddr,
		CACertPath:    caCert,
		SkipTLSVerify: skipTLSVerify,
	})
	if err != nil {
		return fmt.Errorf("create vault client: %w", err)
	}

	// Discover leader
	leaderAddr, err := client.GetLeaderAddress()
	if err != nil {
		return fmt.Errorf("discover leader: %w", err)
	}

	// Print to stdout (can be captured by shell script)
	fmt.Println(leaderAddr)

	slog.Info("discovered Vault leader", "leader_address", leaderAddr)
	return nil
}

func init() {
	vaultCmd.AddCommand(vaultLeaderCmd)

	vaultLeaderCmd.Flags().String("vault-addr", "", "Vault server address (required)")
	vaultLeaderCmd.Flags().String("ca-cert", "", "Path to CA certificate for TLS verification")
	vaultLeaderCmd.Flags().Bool("skip-tls-verify", false, "Skip TLS certificate verification (insecure, dev only)")
}
