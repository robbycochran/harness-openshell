package cmd

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/robbycochran/harness-openshell/internal/gateway"
)

func setupProvidersTest(t *testing.T) string {
	t.Helper()
	dir := t.TempDir()
	os.MkdirAll(filepath.Join(dir, "sandbox", "profiles"), 0o755)
	return dir
}

func TestRegisterProviders_GitHubWhenTokenSet(t *testing.T) {
	dir := setupProvidersTest(t)
	t.Setenv("GITHUB_TOKEN", "ghp_test123")
	t.Setenv("JIRA_API_TOKEN", "")

	gw := &mockGW{
		providers: map[string]bool{},
	}

	err := registerProviders(dir, gw, false, nil)
	if err != nil {
		t.Fatalf("registerProviders: %v", err)
	}
}

func TestRegisterProviders_SkipsWhenTokenMissing(t *testing.T) {
	dir := setupProvidersTest(t)
	t.Setenv("GITHUB_TOKEN", "")
	t.Setenv("JIRA_API_TOKEN", "")

	gw := &mockGW{
		providers: map[string]bool{},
	}

	err := registerProviders(dir, gw, false, nil)
	if err != nil {
		t.Fatalf("registerProviders: %v", err)
	}
}

func TestRegisterProviders_SkipsExistingProvider(t *testing.T) {
	dir := setupProvidersTest(t)
	t.Setenv("GITHUB_TOKEN", "ghp_test123")
	t.Setenv("JIRA_API_TOKEN", "")

	gw := &mockGW{
		providers: map[string]bool{"github": true},
	}

	err := registerProviders(dir, gw, false, nil)
	if err != nil {
		t.Fatalf("registerProviders: %v", err)
	}
}

func TestRegisterProviders_ForceWithRunningSandboxes(t *testing.T) {
	dir := setupProvidersTest(t)

	gw := &mockGWWithSandboxes{
		mockGW: &mockGW{
			providers: map[string]bool{"github": true},
		},
		sandboxes: []string{"test-sandbox"},
	}

	err := registerProviders(dir, gw, true, nil)
	if err == nil {
		t.Fatal("expected error with --force and running sandboxes")
	}
	if !strings.Contains(err.Error(), "cannot --force") {
		t.Errorf("error = %q, want 'cannot --force'", err)
	}
}

func TestRegisterProviders_ForceDeletesAndRecreates(t *testing.T) {
	dir := setupProvidersTest(t)
	t.Setenv("GITHUB_TOKEN", "ghp_test123")
	t.Setenv("JIRA_API_TOKEN", "")

	gw := &mockGW{
		providers: map[string]bool{},
	}

	err := registerProviders(dir, gw, true, nil)
	if err != nil {
		t.Fatalf("registerProviders: %v", err)
	}
}

func TestRegisterProviders_RespectsGatewayConfig(t *testing.T) {
	dir := setupProvidersTest(t)
	t.Setenv("GITHUB_TOKEN", "ghp_test123")
	t.Setenv("JIRA_API_TOKEN", "token")

	gw := &mockGW{
		providers: map[string]bool{},
	}

	gwCfg := &gateway.GatewayConfig{}
	gwCfg.Providers.Enabled = []string{"github"}

	err := registerProviders(dir, gw, false, gwCfg)
	if err != nil {
		t.Fatalf("registerProviders: %v", err)
	}
}

func TestRegisterProviders_ListError(t *testing.T) {
	dir := setupProvidersTest(t)

	gw := &mockGW{
		providers:   map[string]bool{},
		providerErr: fmt.Errorf("gateway unreachable"),
	}

	err := registerProviders(dir, gw, false, nil)
	if err == nil {
		t.Fatal("expected error when provider list fails")
	}
	if !strings.Contains(err.Error(), "listing providers") {
		t.Errorf("error = %q, want 'listing providers'", err)
	}
}

// mockGWWithSandboxes wraps mockGW to return a non-empty sandbox list.
type mockGWWithSandboxes struct {
	*mockGW
	sandboxes []string
}

func (m *mockGWWithSandboxes) SandboxList() ([]string, error) {
	return m.sandboxes, nil
}
