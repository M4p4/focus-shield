package main

import (
	"testing"
	"time"
)

func TestBypasserGrantExpires(t *testing.T) {
	b := NewBypasser()
	now := time.Date(2026, 5, 24, 12, 0, 0, 0, time.UTC)
	b.now = func() time.Time { return now }

	if b.IsActive("youtube.com") {
		t.Fatal("no grant should be inactive")
	}

	b.Grant("youtube.com", 5*time.Minute)
	if !b.IsActive("youtube.com") {
		t.Fatal("fresh grant should be active")
	}

	now = now.Add(4 * time.Minute)
	if !b.IsActive("youtube.com") {
		t.Fatal("4min into a 5min grant should still be active")
	}

	now = now.Add(2 * time.Minute) // total 6min — past expiry
	if b.IsActive("youtube.com") {
		t.Fatal("expired grant should be inactive")
	}
}

func TestBypasserRegrantExtends(t *testing.T) {
	b := NewBypasser()
	now := time.Date(2026, 5, 24, 12, 0, 0, 0, time.UTC)
	b.now = func() time.Time { return now }

	b.Grant("reddit.com", 1*time.Minute)
	now = now.Add(30 * time.Second)
	newExp := b.Grant("reddit.com", 5*time.Minute) // extends, doesn't stack

	want := now.Add(5 * time.Minute)
	if !newExp.Equal(want) {
		t.Errorf("regrant expiry = %s, want %s", newExp, want)
	}
}
