package main

import (
	"testing"
	"time"
)

func TestTrackerAccumulatesActiveSession(t *testing.T) {
	tr := NewTracker()
	now := time.Date(2026, 5, 24, 12, 0, 0, 0, time.UTC)
	tr.now = func() time.Time { return now }

	// First activity opens a session.
	tr.OnActivity("youtube.com")
	if got := tr.Elapsed("youtube.com"); got != 0 {
		t.Errorf("elapsed at session start = %d, want 0", got)
	}

	// 10s of continuous activity.
	now = now.Add(10 * time.Second)
	tr.OnActivity("youtube.com")
	if got := tr.Elapsed("youtube.com"); got != 10 {
		t.Errorf("elapsed after 10s = %d, want 10", got)
	}
}

func TestTrackerClosesIdleSession(t *testing.T) {
	tr := NewTracker()
	now := time.Date(2026, 5, 24, 12, 0, 0, 0, time.UTC)
	tr.now = func() time.Time { return now }

	tr.OnActivity("x.com")
	now = now.Add(5 * time.Second)
	tr.OnActivity("x.com") // session: 5s of activity

	// Go idle past the threshold.
	now = now.Add(idleThreshold + time.Second)
	tr.tick() // should roll session into accumulated

	if got := tr.Elapsed("x.com"); got != 5 {
		t.Errorf("after idle close, elapsed = %d, want 5 (idle gap not counted)", got)
	}

	// A new activity opens a new session, accumulated total grows.
	tr.OnActivity("x.com")
	now = now.Add(3 * time.Second)
	tr.OnActivity("x.com")
	if got := tr.Elapsed("x.com"); got != 8 {
		t.Errorf("after new session, elapsed = %d, want 8 (5+3)", got)
	}
}

func TestTrackerResetClearsState(t *testing.T) {
	tr := NewTracker()
	tr.OnActivity("reddit.com")
	tr.Reset()
	if got := tr.Elapsed("reddit.com"); got != 0 {
		t.Errorf("after Reset, elapsed = %d, want 0", got)
	}
}

func TestTrackerPersistsAndReloadsSameDay(t *testing.T) {
	dir := t.TempDir()
	path := dir + "/usage.json"

	day := time.Date(2026, 5, 24, 10, 0, 0, 0, time.UTC)

	tr1 := NewTracker()
	tr1.now = func() time.Time { return day }
	tr1.SetUsagePath(path)
	tr1.OnActivity("youtube.com")
	day = day.Add(7 * time.Second)
	tr1.OnActivity("youtube.com") // 7s session
	if err := tr1.SaveToDisk(); err != nil {
		t.Fatalf("SaveToDisk: %v", err)
	}

	// New tracker on the same day → loads the prior usage.
	tr2 := NewTracker()
	tr2.now = func() time.Time { return day.Add(time.Minute) }
	tr2.SetUsagePath(path)
	if err := tr2.LoadFromDisk(); err != nil {
		t.Fatalf("LoadFromDisk: %v", err)
	}
	if got := tr2.Elapsed("youtube.com"); got != 7 {
		t.Errorf("reloaded elapsed = %d, want 7", got)
	}
}

func TestTrackerIgnoresStaleFile(t *testing.T) {
	dir := t.TempDir()
	path := dir + "/usage.json"

	yesterday := time.Date(2026, 5, 23, 10, 0, 0, 0, time.UTC)

	tr1 := NewTracker()
	tr1.now = func() time.Time { return yesterday }
	tr1.SetUsagePath(path)
	tr1.OnActivity("youtube.com")
	yesterday = yesterday.Add(7 * time.Second)
	tr1.OnActivity("youtube.com")
	_ = tr1.SaveToDisk()

	// Today's tracker should ignore yesterday's file.
	today := time.Date(2026, 5, 24, 1, 0, 0, 0, time.UTC)
	tr2 := NewTracker()
	tr2.now = func() time.Time { return today }
	tr2.SetUsagePath(path)
	_ = tr2.LoadFromDisk()
	if got := tr2.Elapsed("youtube.com"); got != 0 {
		t.Errorf("stale file shouldn't load; elapsed = %d, want 0", got)
	}
}

func TestTrackerIgnoresActivityWhenUserInactive(t *testing.T) {
	tr := NewTracker()
	now := time.Date(2026, 5, 24, 12, 0, 0, 0, time.UTC)
	tr.now = func() time.Time { return now }

	tr.SetUserActive(false)
	tr.OnActivity("youtube.com") // should be a no-op
	now = now.Add(20 * time.Second)
	tr.OnActivity("youtube.com")

	if got := tr.Elapsed("youtube.com"); got != 0 {
		t.Errorf("inactive user: elapsed = %d, want 0", got)
	}
}

func TestTrackerClosesOpenSessionWhenGoingInactive(t *testing.T) {
	tr := NewTracker()
	now := time.Date(2026, 5, 24, 12, 0, 0, 0, time.UTC)
	tr.now = func() time.Time { return now }

	// Active: rack up 10s.
	tr.OnActivity("youtube.com")
	now = now.Add(10 * time.Second)
	tr.OnActivity("youtube.com")

	// Switching to inactive should commit the 10s and close the session.
	tr.SetUserActive(false)
	if got := tr.Elapsed("youtube.com"); got != 10 {
		t.Errorf("after inactive: elapsed = %d, want 10", got)
	}

	// 30 minutes pass without activity reports — still 10s, no drift.
	now = now.Add(30 * time.Minute)
	if got := tr.Elapsed("youtube.com"); got != 10 {
		t.Errorf("during inactive: elapsed = %d, want 10", got)
	}

	// Reactivate and accumulate more.
	tr.SetUserActive(true)
	tr.OnActivity("youtube.com")
	now = now.Add(5 * time.Second)
	tr.OnActivity("youtube.com")
	if got := tr.Elapsed("youtube.com"); got != 15 {
		t.Errorf("after reactivate: elapsed = %d, want 15", got)
	}
}

func TestNextLocalMidnightHandlesEndOfMonth(t *testing.T) {
	loc, _ := time.LoadLocation("America/New_York")
	now := time.Date(2026, 1, 31, 23, 30, 0, 0, loc)
	next := nextLocalMidnight(now)
	want := time.Date(2026, 2, 1, 0, 0, 0, 0, loc)
	if !next.Equal(want) {
		t.Errorf("nextLocalMidnight(%s) = %s, want %s", now, next, want)
	}
}
