package main

import (
	"encoding/json"
	"fmt"
	"os"
	"sort"
	"strings"
	"sync"
)

type Mode string

const (
	ModeOff     Mode = "off"
	ModeTimed   Mode = "timed"
	ModeBlocked Mode = "blocked"
)

type Rule struct {
	ID                string `json:"id"`
	Domain            string `json:"domain"`
	MatchSubdomains   bool   `json:"matchSubdomains"`
	Mode              Mode   `json:"mode"`
	DailyLimitSeconds int    `json:"dailyLimitSeconds,omitempty"`
}

type Config struct {
	Version          int    `json:"version"`
	Enabled          bool   `json:"enabled"`
	ResetHour        int    `json:"resetHour"`
	PasswordRequired bool   `json:"passwordRequired"`
	Rules            []Rule `json:"rules"`
}

// domainGroups expands a primary domain into the set of related domains a
// service actually serves traffic from (CDNs, video, image hosts). Without
// these, time tracking and blocking miss the bulk of the traffic.
var domainGroups = map[string][]string{
	"youtube.com": {"youtube.com", "googlevideo.com", "ytimg.com", "youtu.be"},
	"x.com":       {"x.com", "twitter.com", "twimg.com", "t.co"},
	"reddit.com":  {"reddit.com", "redd.it", "redditmedia.com", "redditstatic.com"},
}

// matchEntry is one row in the host → rule-key lookup table.
// suffix is the lowercase domain to match (e.g. "youtube.com").
// exact = true means only the exact host matches; false means any subdomain.
type matchEntry struct {
	suffix  string
	exact   bool
	ruleKey string // canonical key under which the rule is stored (rule.Domain, lowercased)
}

// Ruleset is an immutable, query-optimised view over a Config.
// Build a new one whenever the config changes.
type Ruleset struct {
	enabled bool
	byKey   map[string]Rule // canonical rule domain → rule
	entries []matchEntry    // sorted by suffix length desc for longest-suffix match
}

func BuildRuleset(cfg Config) *Ruleset {
	rs := &Ruleset{
		enabled: cfg.Enabled,
		byKey:   make(map[string]Rule, len(cfg.Rules)),
	}
	for _, r := range cfg.Rules {
		key := strings.ToLower(strings.TrimSpace(r.Domain))
		if key == "" || r.Mode == ModeOff {
			continue
		}
		r.Domain = key
		rs.byKey[key] = r

		// Primary domain entry. matchSubdomains controls whether we
		// treat it as suffix or exact.
		rs.entries = append(rs.entries, matchEntry{suffix: key, exact: !r.MatchSubdomains, ruleKey: key})

		// Group members are always suffix-matched: services rotate CDN
		// hosts (e.g. r3---sn-h0jeenez.googlevideo.com) and an exact
		// match would never hit. Skip the primary if it's also listed.
		for _, g := range domainGroups[key] {
			g = strings.ToLower(g)
			if g == key {
				continue
			}
			rs.entries = append(rs.entries, matchEntry{suffix: g, exact: false, ruleKey: key})
		}
	}

	// Longest-suffix match: sort so the most specific entry wins when
	// multiple rules cover the same host.
	sort.SliceStable(rs.entries, func(i, j int) bool {
		return len(rs.entries[i].suffix) > len(rs.entries[j].suffix)
	})

	return rs
}

// Match returns the rule that applies to host (lowercase, no port), or
// nil if no rule matches.
func (rs *Ruleset) Match(host string) *Rule {
	if rs == nil || !rs.enabled {
		return nil
	}
	host = strings.ToLower(host)
	for _, e := range rs.entries {
		if e.exact {
			if host == e.suffix {
				r := rs.byKey[e.ruleKey]
				return &r
			}
			continue
		}
		if host == e.suffix || strings.HasSuffix(host, "."+e.suffix) {
			r := rs.byKey[e.ruleKey]
			return &r
		}
	}
	return nil
}

// LoadConfig reads config.json. If the file doesn't exist, returns a
// default empty config (enabled, no rules).
func LoadConfig(path string) (Config, error) {
	data, err := os.ReadFile(path)
	if os.IsNotExist(err) {
		return Config{Version: 1, Enabled: true, ResetHour: 0}, nil
	}
	if err != nil {
		return Config{}, fmt.Errorf("read %s: %w", path, err)
	}
	var c Config
	if err := json.Unmarshal(data, &c); err != nil {
		return Config{}, fmt.Errorf("parse %s: %w", path, err)
	}
	if c.Version == 0 {
		c.Version = 1
	}
	return c, nil
}

// SaveConfig writes config atomically.
func SaveConfig(path string, c Config) error {
	data, err := json.MarshalIndent(c, "", "  ")
	if err != nil {
		return err
	}
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, data, 0o644); err != nil {
		return err
	}
	return os.Rename(tmp, path)
}

// RulesetHolder is a thread-safe, swappable handle to the active ruleset.
type RulesetHolder struct {
	mu sync.RWMutex
	rs *Ruleset
}

func NewRulesetHolder(rs *Ruleset) *RulesetHolder {
	return &RulesetHolder{rs: rs}
}

func (h *RulesetHolder) Get() *Ruleset {
	h.mu.RLock()
	defer h.mu.RUnlock()
	return h.rs
}

func (h *RulesetHolder) Set(rs *Ruleset) {
	h.mu.Lock()
	h.rs = rs
	h.mu.Unlock()
}
