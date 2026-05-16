package main

import (
	"os"

	"github.com/this-is-tobi/homelab/utils/cmd"
)

func main() {
	if err := cmd.Execute(); err != nil {
		os.Exit(1)
	}
}
