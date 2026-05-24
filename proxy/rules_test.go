package main

import "testing"

func TestRulesetMatch(t *testing.T) {
	cfg := Config{
		Enabled: true,
		Rules: []Rule{
			{Domain: "youtube.com", MatchSubdomains: true, Mode: ModeTimed, DailyLimitSeconds: 3600},
			{Domain: "reddit.com", MatchSubdomains: true, Mode: ModeBlocked},
			{Domain: "music.youtube.com", MatchSubdomains: true, Mode: ModeBlocked}, // longest-suffix wins
			{Domain: "example.org", MatchSubdomains: false, Mode: ModeBlocked},      // exact only
		},
	}
	rs := BuildRuleset(cfg)

	cases := []struct {
		host    string
		wantKey string // "" means no match
	}{
		{"youtube.com", "youtube.com"},
		{"www.youtube.com", "youtube.com"},
		{"m.youtube.com", "youtube.com"},
		{"music.youtube.com", "music.youtube.com"},          // longest suffix wins
		{"radio.music.youtube.com", "music.youtube.com"},    // subdomain of more specific
		{"r3---sn-h0jeenez.googlevideo.com", "youtube.com"}, // domain group expansion
		{"ytimg.com", "youtube.com"},
		{"www.reddit.com", "reddit.com"},
		{"i.redd.it", "reddit.com"},
		{"example.org", "example.org"},
		{"sub.example.org", ""}, // exact-only rule rejects subdomain
		{"unrelated.com", ""},
		{"notyoutube.com", ""}, // must not false-match on substring
	}
	for _, c := range cases {
		got := rs.Match(c.host)
		if c.wantKey == "" {
			if got != nil {
				t.Errorf("Match(%q) = %+v, want nil", c.host, got)
			}
			continue
		}
		if got == nil {
			t.Errorf("Match(%q) = nil, want rule for %q", c.host, c.wantKey)
			continue
		}
		if got.Domain != c.wantKey {
			t.Errorf("Match(%q).Domain = %q, want %q", c.host, got.Domain, c.wantKey)
		}
	}
}

func TestRulesetDisabledReturnsNoMatch(t *testing.T) {
	cfg := Config{
		Enabled: false,
		Rules:   []Rule{{Domain: "youtube.com", MatchSubdomains: true, Mode: ModeBlocked}},
	}
	rs := BuildRuleset(cfg)
	if got := rs.Match("youtube.com"); got != nil {
		t.Errorf("disabled ruleset returned a match: %+v", got)
	}
}

func TestRulesetOffModeIsIgnored(t *testing.T) {
	cfg := Config{
		Enabled: true,
		Rules:   []Rule{{Domain: "youtube.com", MatchSubdomains: true, Mode: ModeOff}},
	}
	rs := BuildRuleset(cfg)
	if got := rs.Match("youtube.com"); got != nil {
		t.Errorf("off-mode rule should not match: %+v", got)
	}
}
