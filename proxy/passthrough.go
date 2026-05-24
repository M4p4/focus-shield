package main

import (
	"strings"
	"sync"
)

// PassthroughList holds domains that should NOT be MITM'd — typically
// services that pin their certificate chain (Apple iCloud, banking apps,
// Microsoft Authenticator, etc.). The proxy still relays their CONNECT
// requests; it just doesn't terminate TLS, so the original cert chain
// reaches the client and pinning succeeds.
//
// Match semantics: a host matches if it equals an entry exactly OR has it
// as a suffix preceded by a dot. "apple.com" therefore covers
// "id.apple.com" but not "shyapple.com".
type PassthroughList struct {
	mu       sync.RWMutex
	suffixes []string
}

func NewPassthroughList(initial []string) *PassthroughList {
	pl := &PassthroughList{}
	pl.Set(initial)
	return pl
}

func (p *PassthroughList) Set(domains []string) {
	cleaned := make([]string, 0, len(domains))
	for _, d := range domains {
		d = strings.ToLower(strings.TrimSpace(d))
		d = strings.TrimPrefix(d, "*.") // tolerate "*.apple.com" → "apple.com"
		if d != "" {
			cleaned = append(cleaned, d)
		}
	}
	p.mu.Lock()
	p.suffixes = cleaned
	p.mu.Unlock()
}

func (p *PassthroughList) Matches(host string) bool {
	h := strings.ToLower(host)
	p.mu.RLock()
	defer p.mu.RUnlock()
	for _, s := range p.suffixes {
		if h == s || strings.HasSuffix(h, "."+s) {
			return true
		}
	}
	return false
}

// DefaultPassthroughDomains is the pre-seeded list. Covers Apple's
// device-attestation stack (iCloud / device check / push) and a handful
// of major banks that are known to pin. Users can extend via config —
// not exposed in the UI yet (deferred from M10).
var DefaultPassthroughDomains = []string{
	// Apple
	"apple.com", "icloud.com", "itunes.apple.com",
	"push.apple.com", "mzstatic.com",
	// Microsoft (Authenticator, Intune)
	"login.microsoftonline.com", "microsoftauth.net",
	// Common banks that pin (sample — extend as needed)
	"chase.com", "bankofamerica.com", "wellsfargo.com",
	"hsbc.com", "santander.com", "n26.com", "revolut.com",
}
