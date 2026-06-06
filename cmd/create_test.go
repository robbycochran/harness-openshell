package cmd

import (
	"strings"
	"testing"

	"github.com/robbycochran/harness-openshell/internal/gateway"
	"github.com/robbycochran/harness-openshell/internal/preflight"
	"github.com/robbycochran/harness-openshell/internal/profile"
)

func TestActiveGatewayInfo_ListError(t *testing.T) {
	gw := &mockGW{}

	_, err := activeGatewayInfo(gw)
	if err == nil {
		t.Fatal("expected error when no active gateway")
	}
	if !strings.Contains(err.Error(), "no active gateway") {
		t.Errorf("error = %q, want 'no active gateway'", err)
	}
}

func TestActiveGatewayInfo_RemoteGateway(t *testing.T) {
	gw := &mockGW{
		gatewayListResult: []gateway.GatewayInfo{
			{Name: "openshell-remote-ocp", Endpoint: "https://gateway.apps.ocp.example.com:443", Active: true},
		},
	}

	info, err := activeGatewayInfo(gw)
	if err != nil {
		t.Fatalf("activeGatewayInfo: %v", err)
	}
	if info.Name != "openshell-remote-ocp" {
		t.Errorf("Name = %q, want openshell-remote-ocp", info.Name)
	}
}

func TestCreateDirect_NoProviders(t *testing.T) {
	dir := setupTestProfile(t)
	gw := &mockGW{
		providers: map[string]bool{},
	}

	cfg, err := profile.Parse(dir, "default")
	if err != nil {
		t.Fatalf("parse profile: %v", err)
	}

	err = createDirect(dir, gw, "default", cfg, nil)
	if err != nil {
		t.Fatalf("createDirect: %v", err)
	}
	if gw.createCalls != 1 {
		t.Errorf("createCalls = %d, want 1", gw.createCalls)
	}
	opts := gw.createOpts[0]
	if len(opts.Providers) != 0 {
		t.Errorf("Providers = %v, want empty", opts.Providers)
	}
}

func TestCreateDirect_WithProviders(t *testing.T) {
	dir := setupTestProfile(t)
	gw := &mockGW{
		providers: map[string]bool{"github": true},
	}

	cfg, err := profile.Parse(dir, "default")
	if err != nil {
		t.Fatalf("parse profile: %v", err)
	}

	err = createDirect(dir, gw, "default", cfg, []string{"github"})
	if err != nil {
		t.Fatalf("createDirect: %v", err)
	}
	opts := gw.createOpts[0]
	if len(opts.Providers) != 1 || opts.Providers[0] != "github" {
		t.Errorf("Providers = %v, want [github]", opts.Providers)
	}
	if opts.TTY {
		t.Error("TTY should be false for create (non-interactive)")
	}
}

func TestCreateDirect_SandboxName(t *testing.T) {
	dir := setupTestProfile(t)
	gw := &mockGW{
		providers: map[string]bool{},
	}

	cfg, err := profile.Parse(dir, "default")
	if err != nil {
		t.Fatalf("parse profile: %v", err)
	}
	cfg.Name = "custom-sandbox"

	err = createDirect(dir, gw, "default", cfg, nil)
	if err != nil {
		t.Fatalf("createDirect: %v", err)
	}
	opts := gw.createOpts[0]
	if opts.Name != "custom-sandbox" {
		t.Errorf("Name = %q, want custom-sandbox", opts.Name)
	}
}

func TestProfileHasCustomProviders_NoCustom(t *testing.T) {
	allProviders := []preflight.Provider{
		{Name: "github", Type: "openshell"},
		{Name: "vertex-local", Type: "openshell"},
	}
	if profileHasCustomProviders([]string{"github", "vertex-local"}, allProviders) {
		t.Error("no custom providers, should return false")
	}
}

func TestProfileHasCustomProviders_WithCustom(t *testing.T) {
	allProviders := []preflight.Provider{
		{Name: "github", Type: "openshell"},
		{Name: "gws", Type: "custom"},
	}
	if !profileHasCustomProviders([]string{"github", "gws"}, allProviders) {
		t.Error("gws is custom, should return true")
	}
}

func TestProviderInList(t *testing.T) {
	if !providerInList("github", []string{"github", "vertex-local"}) {
		t.Error("github should be in list")
	}
	if providerInList("atlassian", []string{"github", "vertex-local"}) {
		t.Error("atlassian should not be in list")
	}
	if providerInList("github", nil) {
		t.Error("nil list should return false")
	}
}
