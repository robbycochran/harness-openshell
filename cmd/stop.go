package cmd

import (
	"fmt"

	"github.com/robbycochran/harness-openshell/internal/gateway"
	"github.com/robbycochran/harness-openshell/internal/status"
	"github.com/spf13/cobra"
)

func NewStopCmd(harnessDir, cli string) *cobra.Command {
	return &cobra.Command{
		Use:   "stop [SANDBOX_NAME]",
		Short: "Stop a running sandbox",
		Args:  cobra.MaximumNArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			gw := gateway.New(cli)
			name, err := resolveSandboxName(gw, args)
			if err != nil {
				return err
			}
			if err := gw.SandboxStop(name); err != nil {
				return fmt.Errorf("stopping %s: %w", name, err)
			}
			status.OKf("Stopped %s", name)
			return nil
		},
	}
}
