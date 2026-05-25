package main

import (
	"context"
	"flag"
	"fmt"
	"log"
	"net/http"
	"os"
	"os/signal"
	"path/filepath"
	"syscall"
	"time"
)

const defaultAddr = "127.0.0.1:8888"

func main() {
	addr := flag.String("addr", defaultAddr, "listen address")
	dataDir := flag.String("data-dir", defaultDataDir(), "data directory (CA, config, usage)")
	verbose := flag.Bool("v", false, "verbose proxy logging")
	genCAOnly := flag.Bool("gen-ca", false, "generate the root CA if missing then exit (used by the onboarding flow)")
	flag.Parse()

	if err := os.MkdirAll(*dataDir, 0o755); err != nil {
		log.Fatalf("data dir: %v", err)
	}

	ca, err := loadOrCreateCA(*dataDir)
	if err != nil {
		log.Fatalf("load/create CA: %v", err)
	}
	if *genCAOnly {
		// Print the path so the caller can chain into `security`.
		fmt.Println(filepath.Join(*dataDir, "ca.pem"))
		return
	}
	installCA(ca)

	cfgPath := filepath.Join(*dataDir, "config.json")
	cfg, err := LoadConfig(cfgPath)
	if err != nil {
		log.Fatalf("load config: %v", err)
	}
	log.Printf("loaded config: enabled=%v, %d rule(s)", cfg.Enabled, len(cfg.Rules))

	rules := NewRulesetHolder(BuildRuleset(cfg))

	tracker := NewTracker()
	tracker.SetUsagePath(filepath.Join(*dataDir, "usage.json"))
	if err := tracker.LoadFromDisk(); err != nil {
		log.Printf("warn: could not load usage.json: %v", err)
	}
	tracker.Run()
	// tracker.Close() is called explicitly in the shutdown sequence so
	// the final SaveToDisk happens before the process exits.

	bypass := NewBypasser()
	passthrough := NewPassthroughList(DefaultPassthroughDomains)

	auth, err := NewAuth(filepath.Join(*dataDir, "secrets.json"))
	if err != nil {
		log.Fatalf("auth: %v", err)
	}

	ctx, cancel := context.WithCancel(context.Background())

	go runMidnightReset(ctx, tracker)

	sockPath := filepath.Join(*dataDir, "proxy.sock")
	ipc := NewIPCServer(sockPath, cfgPath, cfg, rules, tracker, auth, bypass)
	if err := ipc.Start(ctx); err != nil {
		log.Fatalf("ipc: %v", err)
	}

	// Graceful shutdown: flush tracker, clean up socket, then exit.
	// Using a separate goroutine that calls os.Exit would skip our
	// deferred cleanup, so this runs the shutdown sequence inline.
	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, syscall.SIGINT, syscall.SIGTERM)

	log.Printf("focus-shield-proxy listening on %s (data dir: %s)", *addr, *dataDir)
	log.Printf("CA at %s — trust it via: sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain %s",
		*dataDir, filepath.Join(*dataDir, "ca.pem"))

	srv := newProxy(rules, tracker, bypass, ipc, passthrough, *verbose)
	httpServer := &http.Server{Addr: *addr, Handler: srv}

	errCh := make(chan error, 1)
	go func() {
		if err := httpServer.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			errCh <- err
		}
	}()

	select {
	case <-sigCh:
		log.Print("shutting down")
	case err := <-errCh:
		log.Printf("proxy server error: %v", err)
	}

	// Order matters: stop accepting traffic first, then flush tracker,
	// then cancel ctx so IPC server cleans up its socket.
	_ = httpServer.Close()
	tracker.Close()
	cancel()
	time.Sleep(50 * time.Millisecond) // let goroutines unwind
}

func defaultDataDir() string {
	home, err := os.UserHomeDir()
	if err != nil {
		return "./focus-shield-data"
	}
	return filepath.Join(home, "Library", "Application Support", "FocusShield")
}
