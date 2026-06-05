package preflight

import (
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"

	"github.com/robbycochran/harness-openshell/internal/gateway"
)

var stripANSI = regexp.MustCompile(`\x1b\[[0-9;]*m`)

func RunCheck(harnessDir string, gw gateway.Gateway, strict bool) error {
	providersPath := os.Getenv("PROVIDERS_TOML")
	if providersPath == "" {
		providersPath = filepath.Join(harnessDir, "providers.toml")
	}
	configPath := os.Getenv("CONFIG_TOML")
	if configPath == "" {
		configPath = filepath.Join(harnessDir, "openshell.toml")
	}

	allProviders, err := LoadProviders(providersPath)
	if err != nil {
		return err
	}
	config, err := LoadConfig(configPath)
	if err != nil {
		return err
	}
	providers := EnabledProviders(allProviders, config)

	hasFailures := false
	cli := os.Getenv("OPENSHELL_CLI")
	if cli == "" {
		cli = "openshell"
	}

	// CLI detection
	fmt.Println("=== OpenShell CLI ===")
	cliPath, cliErr := exec.LookPath(cli)
	if cliErr != nil {
		fmt.Println("  ✗ not found on PATH")
		hasFailures = true
	} else {
		ver := cliVersion(cli)
		if ver != "" {
			fmt.Printf("  ✓ %s\n", ver)
		} else {
			fmt.Printf("  ✓ %s\n", cli)
		}
		fmt.Printf("    %s\n", cliPath)
	}

	// Detect active gateway
	activeGW := ""
	if cliErr == nil {
		activeGW = detectActiveGateway(cli)
	}
	isK8s := strings.Contains(activeGW, "-remote-")

	// Gateway check
	gwOK := false
	if isK8s {
		fmt.Println()
		fmt.Println("=== K8s gateway ===")
		kubectlPath, _ := exec.LookPath("kubectl")
		if kubectlPath == "" {
			fmt.Println("  ✗ kubectl not found")
			hasFailures = true
		} else {
			ctx := runOutput("kubectl", "config", "current-context")
			if ctx != "" {
				fmt.Printf("  ✓ Cluster: %s\n", ctx)

				if cliErr == nil {
					if gw.InferenceGet() == nil {
						gwOK = true
						model := inferenceModel(cli)
						if model != "" {
							fmt.Printf("  ✓ Gateway reachable (model: %s)\n", model)
						} else {
							fmt.Println("  ✓ Gateway reachable")
						}
					} else {
						fmt.Println("  ✗ Gateway unreachable")
					}
				}
			} else {
				fmt.Println("  ✗ No cluster (kubectl not configured)")
				hasFailures = true
			}
		}
	} else {
		fmt.Println()
		fmt.Println("=== Podman gateway ===")
		if cliErr == nil {
			if gw.InferenceGet() == nil {
				gwOK = true
				model := inferenceModel(cli)
				if model != "" {
					fmt.Printf("  ✓ Reachable (model: %s)\n", model)
				} else {
					fmt.Println("  ✓ Reachable")
				}
			} else {
				fmt.Println("  - Not running")
			}

			podmanPath, _ := exec.LookPath("podman")
			if podmanPath != "" {
				ver := runOutput("podman", "--version")
				fmt.Printf("  ✓ Podman: %s\n", ver)
			} else {
				fmt.Println("  ✗ Podman not found")
				hasFailures = true
			}
		} else {
			fmt.Println("  - CLI not available")
		}
	}

	// Registered providers
	if cliErr == nil && gwOK {
		fmt.Println()
		gwLabel := "podman"
		if isK8s {
			gwLabel = "k8s"
		}
		fmt.Printf("=== Registered providers (%s) ===\n", gwLabel)
		for _, p := range providers {
			if p.Type != "openshell" {
				continue
			}
			if gw.ProviderGet(p.Name) == nil {
				fmt.Printf("  ✓ %s\n", p.Name)
			} else {
				fmt.Printf("  ✗ %s: not registered — run ./setup-providers.sh\n", p.Name)
				hasFailures = true
			}
		}
	}

	// Provider inputs
	fmt.Println()
	fmt.Println("=== Provider inputs ===")
	for _, p := range providers {
		ok, details := CheckProvider(p)
		if ok {
			fmt.Printf("  ✓ %s\n", p.Name)
		} else {
			fmt.Printf("  ✗ %s\n", p.Name)
			if p.Required {
				hasFailures = true
			}
		}
		fmt.Printf("    %s\n", p.Description)

		for _, d := range details {
			fmt.Printf("      %s\n", d)
		}

		if p.Upstream != "" && !ok {
			fmt.Printf("      upstream: %s\n", p.Upstream)
		}
		fmt.Println()
	}

	// Summary
	if hasFailures {
		fmt.Println("✗ Not ready — fix issues above")
		if strict {
			os.Exit(1)
		}
	} else {
		fmt.Println("✓ Ready to launch")
	}
	return nil
}

func RunAvailable(harnessDir string) error {
	providersPath := os.Getenv("PROVIDERS_TOML")
	if providersPath == "" {
		providersPath = filepath.Join(harnessDir, "providers.toml")
	}
	configPath := os.Getenv("CONFIG_TOML")
	if configPath == "" {
		configPath = filepath.Join(harnessDir, "openshell.toml")
	}

	all, err := LoadProviders(providersPath)
	if err != nil {
		return err
	}
	config, _ := LoadConfig(configPath)
	providers := EnabledProviders(all, config)

	var available []string
	for _, p := range providers {
		if p.Type != "openshell" {
			continue
		}
		ok, _ := CheckProvider(p)
		if ok {
			available = append(available, p.Name)
		}
	}
	fmt.Println(strings.Join(available, " "))
	return nil
}

func RunNames(harnessDir string) error {
	providersPath := os.Getenv("PROVIDERS_TOML")
	if providersPath == "" {
		providersPath = filepath.Join(harnessDir, "providers.toml")
	}
	configPath := os.Getenv("CONFIG_TOML")
	if configPath == "" {
		configPath = filepath.Join(harnessDir, "openshell.toml")
	}

	all, err := LoadProviders(providersPath)
	if err != nil {
		return err
	}
	config, _ := LoadConfig(configPath)
	providers := EnabledProviders(all, config)

	var names []string
	for _, p := range providers {
		if p.Type == "openshell" {
			names = append(names, p.Name)
		}
	}
	fmt.Println(strings.Join(names, " "))
	return nil
}

func cliVersion(cli string) string {
	cmd := exec.Command(cli, "--version")
	cmd.Stderr = io.Discard
	out, err := cmd.Output()
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(out))
}

func detectActiveGateway(cli string) string {
	cmd := exec.Command(cli, "gateway", "list")
	cmd.Stderr = io.Discard
	out, err := cmd.Output()
	if err != nil {
		return ""
	}
	for _, line := range strings.Split(string(out), "\n") {
		cleaned := stripANSI.ReplaceAllString(line, "")
		if strings.HasPrefix(cleaned, "*") {
			fields := strings.Fields(cleaned)
			if len(fields) > 1 {
				return fields[1]
			}
		}
	}
	return ""
}

func inferenceModel(cli string) string {
	cmd := exec.Command(cli, "inference", "get")
	cmd.Stderr = io.Discard
	out, err := cmd.Output()
	if err != nil {
		return ""
	}
	for _, line := range strings.Split(string(out), "\n") {
		cleaned := stripANSI.ReplaceAllString(line, "")
		if strings.Contains(cleaned, "Model:") {
			return strings.TrimSpace(strings.SplitN(cleaned, "Model:", 2)[1])
		}
	}
	return ""
}

func runOutput(name string, args ...string) string {
	cmd := exec.Command(name, args...)
	cmd.Stderr = io.Discard
	out, err := cmd.Output()
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(out))
}
