// Exec-form HEALTHCHECK probe for the scratch-based auth image: a static
// stdlib-only GET that exits 0 on a 2xx response. The image has no shell and
// no busybox, and gotrue has no health subcommand, so Docker needs this
// dedicated binary to report real readiness (the CLI omits --health-cmd and
// relies on the image HEALTHCHECK).
package main

import (
	"fmt"
	"net/http"
	"os"
	"time"
)

func probeURL() string {
	// Exec form cannot expand env vars, so the probe resolves the port
	// itself with the same GOTRUE_API_PORT → PORT precedence gotrue's
	// envconfig uses. The final fallback matches the image's baked
	// ENV PORT=9999 (gotrue's own built-in default is 8081) and only
	// fires if that env is stripped. An explicit URL argument overrides
	// everything.
	if len(os.Args) > 1 {
		return os.Args[1]
	}
	port := os.Getenv("GOTRUE_API_PORT")
	if port == "" {
		port = os.Getenv("PORT")
	}
	if port == "" {
		port = "9999"
	}
	return "http://127.0.0.1:" + port + "/health"
}

func main() {
	url := probeURL()
	client := &http.Client{Timeout: 4 * time.Second}
	resp, err := client.Get(url)
	if err != nil {
		fmt.Fprintf(os.Stderr, "unhealthy: %s: %v\n", url, err)
		os.Exit(1)
	}
	defer resp.Body.Close()
	if resp.StatusCode < 200 || resp.StatusCode > 299 {
		fmt.Fprintf(os.Stderr, "unhealthy: %s: HTTP %d\n", url, resp.StatusCode)
		os.Exit(1)
	}
}
