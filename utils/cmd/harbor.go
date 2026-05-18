package cmd

import (
	"github.com/this-is-tobi/homelab/utils/cmd/harbor"
)

func init() {
	rootCmd.AddCommand(harbor.Cmd)
}
