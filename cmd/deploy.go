package cmd

import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"

	"github.com/robbycochran/harness-openshell/internal/gateway"
	"github.com/robbycochran/harness-openshell/internal/k8s"
	"github.com/robbycochran/harness-openshell/internal/preflight"
	"github.com/robbycochran/harness-openshell/internal/status"
	"github.com/spf13/cobra"
)

func NewDeployCmd(harnessDir, cli string) *cobra.Command {
	var (
		local      bool
		remote     bool
		kubeconfig string
	)

	cmd := &cobra.Command{
		Use:   "deploy [gateway]",
		Short: "Deploy or verify the gateway",
		Long:  "Deploy a gateway by name (e.g., local, ocp, kind). Reads configuration from gateways/<name>/gateway.toml.",
		Args:  cobra.MaximumNArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			gatewayName, err := resolveGatewayName(args, local, remote)
			if err != nil {
				return err
			}

			gwDir := filepath.Join(harnessDir, "gateways", gatewayName)
			gwCfg, err := gateway.LoadConfig(gwDir)
			if err != nil {
				return fmt.Errorf("loading gateway config %q: %w", gatewayName, err)
			}

			gw := gateway.New(cli)

			if gwCfg.IsLocal() {
				return deployLocal(gw)
			}

			kc := k8s.New(kubeconfig, k8s.DefaultNamespace())
			clusterRunner := k8s.New(kubeconfig, "")
			return deployFromConfig(harnessDir, gwCfg, gw, kc, clusterRunner)
		},
	}

	cmd.Flags().BoolVar(&local, "local", false, "Alias for 'harness deploy local'")
	cmd.Flags().BoolVar(&remote, "remote", false, "Alias for 'harness deploy ocp'")
	cmd.Flags().StringVar(&kubeconfig, "kubeconfig", "", "Path to kubeconfig (remote only)")
	cmd.Flags().MarkHidden("local")
	cmd.Flags().MarkHidden("remote")

	return cmd
}

func resolveGatewayName(args []string, local, remote bool) (string, error) {
	if len(args) > 0 {
		return args[0], nil
	}
	if local {
		return "local", nil
	}
	if remote {
		return "ocp", nil
	}
	return "", fmt.Errorf("specify a gateway: harness deploy <local|ocp|kind>")
}

func deployLocal(gw gateway.Gateway) error {
	cliPath := gw.CLIPath()
	if cliPath == "" {
		return fmt.Errorf("openshell CLI not found. Install it first:\n  curl -LsSf https://raw.githubusercontent.com/NVIDIA/OpenShell/main/install.sh | sh")
	}

	status.Section("Container Runtime")
	if _, err := exec.LookPath("podman"); err != nil {
		status.Fail("Podman not found")
		return fmt.Errorf("podman is required")
	}
	out, _ := exec.Command("podman", "--version").Output()
	status.OKf("Podman: %s", strings.TrimSpace(string(out)))

	status.Section("Gateway")
	gateways, err := gw.GatewayList()
	if err != nil {
		return fmt.Errorf("listing gateways: %w", err)
	}

	var localGW string
	for _, g := range gateways {
		if strings.Contains(g.Endpoint, "127.0.0.1") {
			localGW = g.Name
			break
		}
	}

	if localGW == "" {
		status.Fail("No local gateway found")
		fmt.Println()
		fmt.Println("  Install OpenShell (auto-registers the gateway):")
		fmt.Println("    curl -LsSf https://raw.githubusercontent.com/NVIDIA/OpenShell/main/install.sh | sh")
		return fmt.Errorf("no local gateway")
	}

	if err := gw.GatewaySelect(localGW); err != nil {
		return fmt.Errorf("selecting gateway %s: %w", localGW, err)
	}

	if gw.InferenceGet() == nil {
		status.OKf("%s (active, reachable)", localGW)
	} else {
		status.Failf("%s (not responding)", localGW)
		fmt.Println()
		fmt.Println("  Start the gateway:")
		fmt.Println("    macOS:  brew services start openshell")
		fmt.Println("    Linux:  systemctl --user start openshell")
		return fmt.Errorf("gateway not responding")
	}

	fmt.Println()
	status.Done("Done.")
	return nil
}

func deployFromConfig(harnessDir string, gwCfg *gateway.GatewayConfig, gw gateway.Gateway, kc, clusterRunner k8s.Runner) (retErr error) {
	defer func() {
		if retErr != nil {
			fmt.Fprintf(os.Stderr, "\nDeploy failed. Clean up with: harness teardown --k8s\n")
		}
	}()
	ctx := context.Background()
	namespace := k8s.DefaultNamespace()

	chartVersion := os.Getenv("OPENSHELL_CHART_VERSION")
	if chartVersion == "" {
		cfg, _ := preflight.LoadConfig(filepath.Join(harnessDir, "openshell.toml"))
		if cfg != nil && cfg.Upstream.ChartVersion != "" {
			chartVersion = cfg.Upstream.ChartVersion
		}
	}
	if chartVersion == "" {
		chartVersion = gwCfg.Chart.Version
	}

	fmt.Printf("OpenShell chart: %s\n", chartVersion)
	if kbcfg := os.Getenv("KUBECONFIG"); kbcfg != "" {
		fmt.Printf("KUBECONFIG: %s\n", kbcfg)
	}
	fmt.Println()

	// Step 1: Namespace
	status.Step(1, "Creating namespace")
	clusterRunner.RunKubectl(ctx, "create", "ns", namespace)
	if _, err := clusterRunner.RunKubectl(ctx, "label", "ns", namespace,
		"pod-security.kubernetes.io/enforce=privileged",
		"pod-security.kubernetes.io/warn=privileged",
		"--overwrite"); err != nil {
		return fmt.Errorf("labeling namespace: %w", err)
	}

	// Step 2: Sandbox CRD
	status.Step(2, "Installing Sandbox CRD")
	if err := clusterRunner.RunKubectlPassthrough(ctx, "apply", "-f", gwCfg.Chart.CRD.URL); err != nil {
		return fmt.Errorf("installing sandbox CRD: %w", err)
	}

	// Step 3: Platform-specific setup
	if gwCfg.IsOCP() {
		status.Step(3, "Granting OpenShift SCCs")
		for _, sa := range gwCfg.OCP.SCCPrivileged {
			kc.RunOC(ctx, "adm", "policy", "add-scc-to-user", "privileged", "-z", sa, "-n", namespace)
		}
		for _, sa := range gwCfg.OCP.SCCAnyuid {
			kc.RunOC(ctx, "adm", "policy", "add-scc-to-user", "anyuid", "-z", sa, "-n", namespace)
		}
		clusterRunner.RunKubectl(ctx, "create", "clusterrolebinding", "agent-sandbox-admin",
			"--clusterrole=cluster-admin",
			"--serviceaccount=agent-sandbox-system:agent-sandbox-controller")
	}

	// Addon manifests (RBAC, etc.)
	for _, manifestPath := range gwCfg.ManifestPaths() {
		if err := kc.RunKubectlPassthrough(ctx, "apply", "-f", manifestPath); err != nil {
			return fmt.Errorf("applying %s: %w", filepath.Base(manifestPath), err)
		}
	}

	// Step 4: Helm install
	status.Step(4, "Deploying gateway via Helm")

	var gatewayURL string
	var routeHost string

	switch gwCfg.Gateway.Service {
	case "route":
		appsDomain, err := clusterRunner.GetJSONPath(ctx, "ingresses.config.openshift.io/cluster", "{.spec.domain}")
		if err != nil || appsDomain == "" {
			return fmt.Errorf("could not determine OpenShift apps domain — is this an OpenShift cluster? (kubectl get ingresses.config.openshift.io cluster)")
		}
		routeHost = fmt.Sprintf("gateway-openshell.%s", appsDomain)
		gatewayURL = fmt.Sprintf("https://%s:443", routeHost)
	case "nodeport":
		gatewayURL = ""
	case "loadbalancer":
		gatewayURL = ""
	}

	helmArgs := []string{
		"upgrade", "--install", "openshell", gwCfg.Chart.OCI,
		"--version", chartVersion,
	}
	if valuesPath := gwCfg.HelmValuesPath(); valuesPath != "" {
		helmArgs = append(helmArgs, "--values", valuesPath)
	}
	helmArgs = append(helmArgs, "--set", "server.sandboxImage="+gwCfg.Images.Sandbox)
	if routeHost != "" {
		helmArgs = append(helmArgs, "--set", "pkiInitJob.serverDnsNames[0]="+routeHost)
	}
	if ps := os.Getenv("PULL_SECRET"); ps != "" {
		helmArgs = append(helmArgs, "--set", "imagePullSecrets[0].name="+ps)
	}
	if sps := os.Getenv("SANDBOX_PULL_SECRET"); sps != "" {
		helmArgs = append(helmArgs, "--set", "server.sandboxImagePullSecrets[0].name="+sps)
	}
	if err := kc.RunHelm(ctx, helmArgs...); err != nil {
		return fmt.Errorf("helm install failed: %w", err)
	}

	status.Section("Waiting for gateway")
	if err := kc.RunKubectlPassthrough(ctx, "rollout", "status", "statefulset/openshell", "--timeout=300s"); err != nil {
		return fmt.Errorf("gateway rollout failed: %w", err)
	}

	// Step 5: CLI gateway config
	status.Step(5, "Configuring CLI gateway")
	gatewayName := gwCfg.Gateway.Name

	if gatewayURL == "" {
		return fmt.Errorf("service type %q endpoint resolution not yet implemented", gwCfg.Gateway.Service)
	}

	existing, _ := gw.GatewayList()
	for _, g := range existing {
		if routeHost != "" && strings.Contains(g.Endpoint, routeHost) {
			gw.GatewayRemove(g.Name)
		}
	}

	if err := gw.GatewayAdd(gatewayURL, gatewayName, true); err != nil {
		return fmt.Errorf("registering gateway %s: %w", gatewayName, err)
	}

	home, err := os.UserHomeDir()
	if err != nil {
		return fmt.Errorf("determining home directory: %w", err)
	}
	mtlsDir := filepath.Join(home, ".config", "openshell", "gateways", gatewayName, "mtls")
	if err := os.MkdirAll(mtlsDir, 0o700); err != nil {
		return fmt.Errorf("creating mtls directory: %w", err)
	}
	for _, field := range []string{"ca.crt", "tls.crt", "tls.key"} {
		data, err := kc.GetSecretField(ctx, gwCfg.Secrets.MTLS, field)
		if err != nil {
			return fmt.Errorf("extracting %s from %s: %w", field, gwCfg.Secrets.MTLS, err)
		}
		if err := os.WriteFile(filepath.Join(mtlsDir, field), data, 0o600); err != nil {
			return fmt.Errorf("writing %s: %w", field, err)
		}
	}

	if err := gw.GatewaySelect(gatewayName); err != nil {
		return fmt.Errorf("selecting gateway %s: %w", gatewayName, err)
	}
	status.OKf("%s registered (certs from cluster)", gatewayName)

	fmt.Print("  Waiting for gateway...")
	var gwReachable bool
	for range 30 {
		if gw.InferenceGet() == nil {
			gwReachable = true
			status.OK("reachable")
			break
		}
		time.Sleep(2 * time.Second)
		fmt.Print(".")
	}
	if !gwReachable {
		fmt.Println()
		return fmt.Errorf("gateway not reachable after 60s (try: openshell inference get)")
	}

	fmt.Println()
	status.Done("Done.")
	return nil
}
