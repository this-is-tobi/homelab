package cmd

import (
	"github.com/this-is-tobi/homelab/utils/cmd/vault"
)

func init() {
	rootCmd.AddCommand(vault.Cmd)
}
