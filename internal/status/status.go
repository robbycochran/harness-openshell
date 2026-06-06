package status

import (
	"fmt"
	"os"
	"strings"
)

var Verbose bool

func Cmd(name string, args ...string) {
	if !Verbose {
		return
	}
	fmt.Fprintf(os.Stderr, "  $ %s", name)
	redactNext := false
	for _, a := range args {
		if redactNext {
			fmt.Fprintf(os.Stderr, " %s", redactValue(a))
			redactNext = false
			continue
		}
		if a == "--credential" {
			redactNext = true
			fmt.Fprintf(os.Stderr, " %s", a)
			continue
		}
		if strings.HasPrefix(a, "--from-literal=") && isSensitiveLiteral(a) {
			fmt.Fprintf(os.Stderr, " %s", redactFromLiteral(a))
			continue
		}
		fmt.Fprintf(os.Stderr, " %s", a)
	}
	fmt.Fprintln(os.Stderr)
}

// redactValue replaces the value portion of KEY=VALUE with ***.
func redactValue(s string) string {
	if i := strings.IndexByte(s, '='); i >= 0 {
		return s[:i+1] + "***"
	}
	return s
}

// isSensitiveLiteral checks if a --from-literal=KEY=VALUE arg contains a secret key.
func isSensitiveLiteral(s string) bool {
	upper := strings.ToUpper(s)
	for _, keyword := range []string{"TOKEN", "SECRET", "PASSWORD", "KEY", "CREDENTIAL"} {
		if strings.Contains(upper, keyword) {
			return true
		}
	}
	return false
}

// redactFromLiteral redacts the value in --from-literal=KEY=VALUE.
func redactFromLiteral(s string) string {
	// s is "--from-literal=KEY=VALUE", find the second '='
	prefix := "--from-literal="
	rest := s[len(prefix):]
	if i := strings.IndexByte(rest, '='); i >= 0 {
		return prefix + rest[:i+1] + "***"
	}
	return s
}

func OK(msg string)                  { fmt.Println("  ✓ " + msg) }
func OKf(format string, a ...any)    { fmt.Printf("  ✓ "+format+"\n", a...) }
func Fail(msg string)                { fmt.Println("  ✗ " + msg) }
func Failf(format string, a ...any)  { fmt.Printf("  ✗ "+format+"\n", a...) }
func Warn(msg string)                { fmt.Println("  ! " + msg) }
func Info(msg string)                { fmt.Println("  - " + msg) }
func Infof(format string, a ...any)  { fmt.Printf("  - "+format+"\n", a...) }
func Detail(msg string)              { fmt.Println("    " + msg) }
func Detailf(format string, a ...any){ fmt.Printf("    "+format+"\n", a...) }
func Sub(msg string)                 { fmt.Println("      " + msg) }
func Step(n int, msg string)         { fmt.Printf("\n=== Step %d: %s ===\n", n, msg) }
func Section(title string)           { fmt.Printf("\n=== %s ===\n", title) }
func Summary(ok bool) {
	if ok {
		fmt.Println("✓ Ready to launch")
	} else {
		fmt.Println("✗ Not ready — fix issues above")
	}
}
func Done(msg string) {
	fmt.Println()
	fmt.Println(msg)
}
