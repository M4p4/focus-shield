package main

import (
	"sync"
	"time"
)

// Bypasser tracks short-lived "unlock anyway" grants per rule. Grants live
// in memory only — a proxy restart drops them, which is the right behavior
// for a 5-minute reprieve.
type Bypasser struct {
	mu          sync.Mutex
	expirations map[string]time.Time
	now         func() time.Time
}

func NewBypasser() *Bypasser {
	return &Bypasser{
		expirations: make(map[string]time.Time),
		now:         time.Now,
	}
}

// Grant unblocks ruleKey for the given duration. Re-granting extends to
// the new expiry rather than stacking.
func (b *Bypasser) Grant(ruleKey string, duration time.Duration) time.Time {
	b.mu.Lock()
	defer b.mu.Unlock()
	exp := b.now().Add(duration)
	b.expirations[ruleKey] = exp
	return exp
}

// IsActive returns true if ruleKey currently has a non-expired grant.
// Expired entries are lazily cleaned up.
func (b *Bypasser) IsActive(ruleKey string) bool {
	b.mu.Lock()
	defer b.mu.Unlock()
	exp, ok := b.expirations[ruleKey]
	if !ok {
		return false
	}
	if !b.now().Before(exp) {
		delete(b.expirations, ruleKey)
		return false
	}
	return true
}

// ExpiresAt returns the active grant's expiry, or zero time if none.
func (b *Bypasser) ExpiresAt(ruleKey string) time.Time {
	b.mu.Lock()
	defer b.mu.Unlock()
	exp, ok := b.expirations[ruleKey]
	if !ok || !b.now().Before(exp) {
		return time.Time{}
	}
	return exp
}

// ActiveGrant is one currently-non-expired grant. Used by the UI to show
// a live countdown when the user has hit "unlock for 5 minutes".
type ActiveGrant struct {
	Domain    string    `json:"domain"`
	ExpiresAt time.Time `json:"expiresAt"`
}

// ActiveGrants returns every grant that hasn't yet expired, sorted by
// expiry (soonest first). Also opportunistically prunes expired entries.
func (b *Bypasser) ActiveGrants() []ActiveGrant {
	b.mu.Lock()
	defer b.mu.Unlock()
	now := b.now()
	out := make([]ActiveGrant, 0, len(b.expirations))
	for domain, exp := range b.expirations {
		if !now.Before(exp) {
			delete(b.expirations, domain)
			continue
		}
		out = append(out, ActiveGrant{Domain: domain, ExpiresAt: exp})
	}
	// Stable order so the UI doesn't shuffle rows between ticks.
	sortGrantsByExpiry(out)
	return out
}

func sortGrantsByExpiry(g []ActiveGrant) {
	for i := 1; i < len(g); i++ {
		for j := i; j > 0 && g[j].ExpiresAt.Before(g[j-1].ExpiresAt); j-- {
			g[j], g[j-1] = g[j-1], g[j]
		}
	}
}
