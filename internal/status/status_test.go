package status

import (
	"bytes"
	"os"
	"strings"
	"testing"
)

func captureCmd(name string, args ...string) string {
	old := os.Stderr
	r, w, _ := os.Pipe()
	os.Stderr = w
	Verbose = true
	Cmd(name, args...)
	w.Close()
	os.Stderr = old
	var buf bytes.Buffer
	buf.ReadFrom(r)
	return buf.String()
}

func TestCmdRedactsCredential(t *testing.T) {
	out := captureCmd("openshell", "provider", "create", "github", "--credential", "GITHUB_TOKEN=ghp_secret123")
	if got := out; got == "" {
		t.Fatal("expected output")
	}
	if contains(out, "ghp_secret123") {
		t.Errorf("credential value leaked: %s", out)
	}
	if !contains(out, "GITHUB_TOKEN=***") {
		t.Errorf("expected redacted credential, got: %s", out)
	}
}

func TestCmdRedactsMultipleCredentials(t *testing.T) {
	out := captureCmd("openshell", "provider", "create", "atlassian",
		"--credential", "JIRA_API_TOKEN=secret1",
		"--credential", "JIRA_URL=https://example.com")
	if contains(out, "secret1") {
		t.Errorf("first credential leaked: %s", out)
	}
	if contains(out, "https://example.com") {
		t.Errorf("second credential leaked: %s", out)
	}
	if !contains(out, "JIRA_API_TOKEN=***") {
		t.Errorf("expected redacted JIRA_API_TOKEN, got: %s", out)
	}
	if !contains(out, "JIRA_URL=***") {
		t.Errorf("expected redacted JIRA_URL, got: %s", out)
	}
}

func TestCmdRedactsFromLiteral(t *testing.T) {
	out := captureCmd("kubectl", "create", "secret", "generic", "openshell-atlassian",
		"--from-literal=JIRA_API_TOKEN=mytoken",
		"--from-literal=JIRA_URL=https://example.com")
	if contains(out, "mytoken") {
		t.Errorf("token leaked: %s", out)
	}
	if !contains(out, "--from-literal=JIRA_API_TOKEN=***") {
		t.Errorf("expected redacted token, got: %s", out)
	}
	// JIRA_URL doesn't match sensitive keywords, should pass through
	if !contains(out, "--from-literal=JIRA_URL=https://example.com") {
		t.Errorf("non-sensitive literal should not be redacted, got: %s", out)
	}
}

func TestCmdDoesNotRedactNonSensitiveLiteral(t *testing.T) {
	out := captureCmd("kubectl", "create", "configmap", "test",
		"--from-literal=JIRA_URL=https://example.com",
		"--from-literal=NAMESPACE=openshell")
	if !contains(out, "JIRA_URL=https://example.com") {
		t.Errorf("non-sensitive literal was redacted: %s", out)
	}
	if !contains(out, "NAMESPACE=openshell") {
		t.Errorf("non-sensitive literal was redacted: %s", out)
	}
}

func TestCmdCredentialKeyOnly(t *testing.T) {
	// --credential KEY (no =VALUE) should pass through as-is
	out := captureCmd("openshell", "provider", "create", "github", "--credential", "GITHUB_TOKEN")
	if !contains(out, "GITHUB_TOKEN") {
		t.Errorf("credential key should be preserved: %s", out)
	}
}

func TestCmdNotVerbose(t *testing.T) {
	old := os.Stderr
	r, w, _ := os.Pipe()
	os.Stderr = w
	Verbose = false
	Cmd("openshell", "--credential", "TOKEN=secret")
	w.Close()
	os.Stderr = old
	var buf bytes.Buffer
	buf.ReadFrom(r)
	if buf.Len() > 0 {
		t.Errorf("expected no output when not verbose, got: %s", buf.String())
	}
}

func TestCmdNormalArgs(t *testing.T) {
	out := captureCmd("openshell", "sandbox", "create", "--from", "image:latest", "--provider", "github")
	expected := "  $ openshell sandbox create --from image:latest --provider github\n"
	if out != expected {
		t.Errorf("expected %q, got %q", expected, out)
	}
}

func contains(s, substr string) bool {
	return strings.Contains(s, substr)
}
