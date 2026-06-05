package preflight

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"

	"github.com/robbycochran/harness-openshell/internal/gateway"
	"github.com/robbycochran/harness-openshell/internal/status"
)

func loadEnabledProviders(harnessDir string) ([]Provider, error) {
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
		return nil, err
	}
	config, _ := LoadConfig(configPath)
	return EnabledProviders(all, config), nil
}

func RunCheck(harnessDir string, gw gateway.Gateway, strict bool) error {
	providers, err := loadEnabledProviders(harnessDir)
	if err != nil {
		return err
	}

	hasFailures := false

	// CLI detection
	fmt.Println("=== OpenShell CLI ===")
	cliPath := gw.CLIPath()
	cliFound := cliPath != ""
	if !cliFound {
		status.Fail("not found on PATH")
		hasFailures = true
	} else {
		ver := gw.CLIVersion()
		if ver != "" {
			status.OK(ver)
		} else {
			status.OK("openshell")
		}
		status.Detail(cliPath)
	}

	// Detect active gateway
	activeGW := ""
	if cliFound {
		activeGW = gw.ActiveGateway()
	}
	isK8s := strings.Contains(activeGW, "-remote-")

	// Gateway check
	gwOK := false
	if isK8s {
		status.Section("K8s gateway")
		kubectlPath, _ := exec.LookPath("kubectl")
		if kubectlPath == "" {
			status.Fail("kubectl not found")
			hasFailures = true
		} else {
			ctx := runOutput("kubectl", "config", "current-context")
			if ctx != "" {
				status.OKf("Cluster: %s", ctx)
				if cliFound {
					if gw.InferenceGet() == nil {
						gwOK = true
						model := gw.InferenceModel()
						if model != "" {
							status.OKf("Gateway reachable (model: %s)", model)
						} else {
							status.OK("Gateway reachable")
						}
					} else {
						status.Fail("Gateway unreachable")
					}
				}
			} else {
				status.Fail("No cluster (kubectl not configured)")
				hasFailures = true
			}
		}
	} else {
		status.Section("Podman gateway")
		if cliFound {
			if gw.InferenceGet() == nil {
				gwOK = true
				model := gw.InferenceModel()
				if model != "" {
					status.OKf("Reachable (model: %s)", model)
				} else {
					status.OK("Reachable")
				}
			} else {
				status.Info("Not running")
			}

			podmanPath, _ := exec.LookPath("podman")
			if podmanPath != "" {
				ver := runOutput("podman", "--version")
				status.OKf("Podman: %s", ver)
			} else {
				status.Fail("Podman not found")
				hasFailures = true
			}
		} else {
			status.Info("CLI not available")
		}
	}

	// Registered providers
	if cliFound && gwOK {
		gwLabel := "podman"
		if isK8s {
			gwLabel = "k8s"
		}
		status.Section(fmt.Sprintf("Registered providers (%s)", gwLabel))
		for _, p := range providers {
			if p.Type != "openshell" {
				continue
			}
			if gw.ProviderGet(p.Name) == nil {
				status.OK(p.Name)
			} else {
				status.Failf("%s: not registered — run ./setup-providers.sh", p.Name)
				hasFailures = true
			}
		}
	}

	// Provider inputs
	status.Section("Provider inputs")
	for _, p := range providers {
		ok, details := CheckProvider(p)
		if ok {
			status.OK(p.Name)
		} else {
			status.Fail(p.Name)
			if p.Required {
				hasFailures = true
			}
		}
		status.Detail(p.Description)

		for _, d := range details {
			status.Sub(d)
		}

		if p.Upstream != "" && !ok {
			status.Sub(fmt.Sprintf("upstream: %s", p.Upstream))
		}
		fmt.Println()
	}

	// Summary
	status.Summary(!hasFailures)
	if hasFailures && strict {
		return fmt.Errorf("preflight: required checks failed")
	}
	return nil
}

func RunAvailable(harnessDir string) error {
	providers, err := loadEnabledProviders(harnessDir)
	if err != nil {
		return err
	}

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
	providers, err := loadEnabledProviders(harnessDir)
	if err != nil {
		return err
	}

	var names []string
	for _, p := range providers {
		if p.Type == "openshell" {
			names = append(names, p.Name)
		}
	}
	fmt.Println(strings.Join(names, " "))
	return nil
}

func runOutput(name string, args ...string) string {
	cmd := exec.Command(name, args...)
	cmd.Stderr = nil
	out, err := cmd.Output()
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(out))
}
