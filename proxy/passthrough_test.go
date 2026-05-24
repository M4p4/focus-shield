package main

import "testing"

func TestPassthroughMatchSuffixes(t *testing.T) {
	pl := NewPassthroughList([]string{"apple.com", "*.chase.com"})
	cases := map[string]bool{
		"apple.com":         true,
		"id.apple.com":      true,
		"www.id.apple.com":  true,
		"shyapple.com":      false, // not a real suffix (no leading dot)
		"chase.com":         true,  // wildcard prefix was stripped
		"banking.chase.com": true,
		"chase.example":     false,
		"google.com":        false,
	}
	for host, want := range cases {
		if got := pl.Matches(host); got != want {
			t.Errorf("Matches(%q) = %v, want %v", host, got, want)
		}
	}
}

func TestPassthroughSetReplaces(t *testing.T) {
	pl := NewPassthroughList([]string{"apple.com"})
	if !pl.Matches("apple.com") {
		t.Fatal("initial entry missing")
	}
	pl.Set([]string{"icloud.com"})
	if pl.Matches("apple.com") {
		t.Error("old entry should be gone after Set")
	}
	if !pl.Matches("icloud.com") {
		t.Error("new entry should be present after Set")
	}
}
