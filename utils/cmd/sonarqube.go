package cmd

import (
	"github.com/this-is-tobi/homelab/utils/cmd/sonarqube"
)

func init() {
	rootCmd.AddCommand(sonarqube.Cmd)
}
