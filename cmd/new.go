package cmd

import (
	"fmt"
	"os"
	"time"

	"github.com/robbycochran/harness-openshell/internal/gateway"
	"github.com/robbycochran/harness-openshell/internal/profile"
	"github.com/robbycochran/harness-openshell/internal/runner"
	"github.com/spf13/cobra"
)

func NewNewCmd(harnessDir, cli string) *cobra.Command {
	var (
		local       bool
		remote      bool
		profileName string
		sandboxName string
		noTTY       bool
	)

	cmd := &cobra.Command{
		Use:   "new [flags]",
		Short: "Create a new sandbox",
		Long:  "Deploy gateway and providers if needed, then create a sandbox from a profile.",
		RunE: func(cmd *cobra.Command, args []string) error {
			if len(args) > 0 && sandboxName == "" {
				sandboxName = args[0]
			}

			if remote {
				return newRemote(harnessDir, profileName, sandboxName, noTTY)
			}

			gw := gateway.NewCLI(cli)
			return newLocal(harnessDir, gw, local, profileName, sandboxName, noTTY)
		},
	}

	cmd.Flags().BoolVar(&local, "local", false, "Ensure local podman gateway")
	cmd.Flags().BoolVar(&remote, "remote", false, "Ensure OCP gateway")
	cmd.Flags().StringVar(&profileName, "profile", "default", "Profile name (from profiles/)")
	cmd.Flags().StringVar(&sandboxName, "name", "", "Sandbox name (overrides profile)")
	cmd.Flags().BoolVar(&noTTY, "no-tty", false, "Non-interactive mode (for testing)")

	return cmd
}

func newRemote(harnessDir, profileName, sandboxName string, noTTY bool) error {
	args := []string{"--remote", "--profile", profileName}
	if sandboxName != "" {
		args = append(args, "--name", sandboxName)
	}
	if noTTY {
		args = append(args, "--no-tty")
	}
	return runner.RunScript(harnessDir, "new.sh", args...)
}

func newLocal(harnessDir string, gw gateway.Gateway, ensureLocal bool, profileName, sandboxName string, noTTY bool) error {
	// 1. Ensure gateway
	if ensureLocal {
		fmt.Println("=== Ensuring local gateway ===")
		if err := runner.RunScript(harnessDir, "deploy.sh", "--local"); err != nil {
			return fmt.Errorf("deploy failed: %w", err)
		}
	} else {
		if err := gw.InferenceGet(); err != nil {
			return fmt.Errorf("no active gateway — use --local or --remote")
		}
	}

	// 2. Ensure providers
	providers, _ := gw.ProviderList()
	if len(providers) == 0 {
		fmt.Println("\n=== Registering providers ===")
		if err := runner.RunScript(harnessDir, "providers.sh"); err != nil {
			return fmt.Errorf("provider registration failed: %w", err)
		}
	}

	// 3. Parse profile
	cfg, err := profile.Parse(harnessDir, profileName)
	if err != nil {
		return err
	}
	if sandboxName != "" {
		cfg.Name = sandboxName
	}

	fmt.Println()
	fmt.Println("=== Sandbox ===")
	fmt.Printf("  Profile: %s\n", profileName)
	fmt.Printf("  Image:   %s\n", cfg.Image)

	// 4. Validate providers against profile
	fmt.Println()
	fmt.Println("=== Providers ===")
	registered, missing := profile.ValidateProviders(cfg.Providers, gw)
	for _, name := range registered {
		fmt.Printf("  ✓ %s: attached\n", name)
	}
	for _, name := range missing {
		fmt.Printf("  ✗ %s: not registered (skipping)\n", name)
	}
	if len(missing) > 0 && len(registered) == 0 {
		fmt.Println()
		fmt.Println("WARNING: no providers available. Run: harness providers")
	}

	// 5. Stage files
	harnessUploadDir := "/tmp/openshell"
	os.RemoveAll(harnessUploadDir)
	if err := profile.StageHarnessDir(cfg, harnessUploadDir); err != nil {
		return fmt.Errorf("staging files: %w", err)
	}

	// 6. Build command
	var sandboxCmd []string
	if noTTY {
		sandboxCmd = []string{"bash", "/sandbox/startup.sh"}
	} else {
		sandboxCmd = []string{"bash", "-c", fmt.Sprintf(". /sandbox/startup.sh && exec %s", cfg.Command)}
	}

	// 7. Create sandbox with retry
	fmt.Println()
	fmt.Println("=== Creating sandbox ===")
	for attempt := 1; attempt <= 5; attempt++ {
		err := gw.SandboxCreate(gateway.SandboxCreateOpts{
			Name:      cfg.Name,
			Image:     cfg.Image,
			Providers: registered,
			TTY:       !noTTY,
			Keep:      cfg.KeepSandbox(),
			UploadSrc: harnessUploadDir,
			UploadDst: "/sandbox/.config",
			Command:   sandboxCmd,
		})
		if err == nil {
			return nil
		}

		fmt.Printf("  Attempt %d failed (supervisor race), retrying in 5s...\n", attempt)
		gw.SandboxDelete(cfg.Name)

		if attempt == 5 {
			return fmt.Errorf("failed after 5 attempts")
		}
		time.Sleep(5 * time.Second)
	}
	return nil
}
