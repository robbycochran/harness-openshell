package cmd

import (
	"fmt"
	"os"
	"path/filepath"

	"github.com/robbycochran/harness-openshell/internal/agent"
	"github.com/robbycochran/harness-openshell/internal/gateway"
)

func resolveSandboxName(gw gateway.Gateway, args []string) (string, error) {
	if len(args) > 0 {
		return args[0], nil
	}
	names, err := gw.SandboxList()
	if err != nil {
		return "", fmt.Errorf("listing sandboxes: %w", err)
	}
	if len(names) == 0 {
		return "", fmt.Errorf("no sandboxes running")
	}
	if len(names) > 1 {
		return "", fmt.Errorf("multiple sandboxes running, specify one: %v", names)
	}
	return names[0], nil
}

func resolveAgentPath(harnessDir, agentName, agentFile string) string {
	if agentFile != "" {
		return agentFile
	}
	return filepath.Join(harnessDir, "agents", agentName+".yaml")
}

func resolveAgentConfig(harnessDir, agentName, agentFile string) (*agent.AgentConfig, error) {
	path := resolveAgentPath(harnessDir, agentName, agentFile)
	cfg, err := agent.ParseFile(path)
	if err == nil {
		return cfg, nil
	}
	if agentFile != "" || agentName != "default" || len(DefaultAgentConfig) == 0 {
		return nil, err
	}
	if _, statErr := os.Stat(path); !os.IsNotExist(statErr) {
		return nil, err
	}
	return agent.Parse(DefaultAgentConfig)
}

func versionedImage(name string) string {
	base := "ghcr.io/robbycochran/harness-openshell"
	if Version == "" || Version == "dev" {
		return base + ":" + name
	}
	return base + ":" + name + "-" + Version
}
