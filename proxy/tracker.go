package main

import (
	"encoding/json"
	"fmt"
	"os"
	"sync"
	"time"
)

const (
	idleThreshold = 30 * time.Second
	flushInterval = 5 * time.Second
)

type sessionState struct {
	lastActivityAt     time.Time
	activeSessionStart time.Time // zero if no active session
	accumulated        time.Duration
}

// BypassRecord captures a manual "unlock anyway" event (M7).
type BypassRecord struct {
	Domain  string    `json:"domain"`
	At      time.Time `json:"at"`
	Minutes int       `json:"minutes"`
}

// UsageFile is the on-disk representation of today's tracker state.
type UsageFile struct {
	Date         string         `json:"date"` // YYYY-MM-DD in local time
	Usage        map[string]int `json:"usage"`
	BypassesUsed []BypassRecord `json:"bypassesUsed"`
}

// Tracker keeps per-rule elapsed time using an idle-based session model:
// every request to a tracked domain extends the session; if no activity
// for idleThreshold, the session closes and its duration is rolled into
// accumulated. Times are reported in seconds.
//
// The active session is partially flushed to disk every flushInterval so
// usage survives proxy restarts mid-day. Midnight reset is handled
// externally by the scheduler.
type Tracker struct {
	mu       sync.Mutex
	state    map[string]*sessionState
	bypasses []BypassRecord
	now      func() time.Time

	usagePath string
	dirty     bool

	// userActive is the AND of "user not idle" + "browser frontmost",
	// reported by the Swift app over IPC every ~5s. Defaults to true so
	// that if the app has never sent an update (proxy run standalone,
	// IPC down, race at startup) we don't silently stop tracking.
	userActive bool

	stop chan struct{}
	done chan struct{}
}

func NewTracker() *Tracker {
	return &Tracker{
		state:      make(map[string]*sessionState),
		now:        time.Now,
		userActive: true,
		stop:       make(chan struct{}),
		done:       make(chan struct{}),
	}
}

// SetUsagePath enables disk persistence. Call before Run.
func (t *Tracker) SetUsagePath(path string) {
	t.mu.Lock()
	t.usagePath = path
	t.mu.Unlock()
}

// LoadFromDisk restores state from usage.json if it exists AND its date
// matches today's local date. A stale (yesterday's) file is ignored — the
// scheduler will overwrite it on the next save.
func (t *Tracker) LoadFromDisk() error {
	t.mu.Lock()
	path := t.usagePath
	t.mu.Unlock()
	if path == "" {
		return nil
	}
	data, err := os.ReadFile(path)
	if os.IsNotExist(err) {
		return nil
	}
	if err != nil {
		return fmt.Errorf("read usage: %w", err)
	}
	var u UsageFile
	if err := json.Unmarshal(data, &u); err != nil {
		return fmt.Errorf("parse usage: %w", err)
	}
	today := dateKey(t.now())
	if u.Date != today {
		// Stale — leave state empty; SaveToDisk will rewrite with today's date.
		return nil
	}
	t.mu.Lock()
	defer t.mu.Unlock()
	for k, secs := range u.Usage {
		t.state[k] = &sessionState{accumulated: time.Duration(secs) * time.Second}
	}
	t.bypasses = append([]BypassRecord(nil), u.BypassesUsed...)
	return nil
}

// SaveToDisk writes the current snapshot atomically.
func (t *Tracker) SaveToDisk() error {
	t.mu.Lock()
	path := t.usagePath
	if path == "" {
		t.mu.Unlock()
		return nil
	}
	snap := t.snapshotLocked()
	bypasses := append([]BypassRecord{}, t.bypasses...)
	t.dirty = false
	t.mu.Unlock()

	out := UsageFile{
		Date:         dateKey(t.now()),
		Usage:        snap,
		BypassesUsed: bypasses,
	}
	data, err := json.MarshalIndent(out, "", "  ")
	if err != nil {
		return err
	}
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, data, 0o644); err != nil {
		return err
	}
	return os.Rename(tmp, path)
}

// OnActivity is called once per request to a tracked rule. If the user is
// currently flagged as inactive (browser not frontmost, or input idle), the
// request is ignored for tracking purposes — the page is still served / a
// blocked page still served, but no time accumulates. This is what stops a
// backgrounded YouTube tab's heartbeat traffic from eating quota.
func (t *Tracker) OnActivity(ruleKey string) {
	t.mu.Lock()
	defer t.mu.Unlock()
	if !t.userActive {
		return
	}
	s := t.state[ruleKey]
	if s == nil {
		s = &sessionState{}
		t.state[ruleKey] = s
	}
	now := t.now()
	if s.activeSessionStart.IsZero() {
		s.activeSessionStart = now
	}
	s.lastActivityAt = now
	t.dirty = true
}

// SetUserActive updates the active/inactive gate. Transitioning to inactive
// closes any open session immediately so we don't count time after the user
// goes AFK / switches to a non-browser app.
func (t *Tracker) SetUserActive(active bool) {
	t.mu.Lock()
	defer t.mu.Unlock()
	if t.userActive == active {
		return
	}
	t.userActive = active
	if !active {
		// Close every open session, attributing only up to the last
		// observed activity (matches the idle-close path in tick()).
		for _, s := range t.state {
			if s.activeSessionStart.IsZero() {
				continue
			}
			s.accumulated += s.lastActivityAt.Sub(s.activeSessionStart)
			s.activeSessionStart = time.Time{}
			t.dirty = true
		}
	}
}

// Elapsed returns the total seconds tracked for ruleKey today, including
// the in-flight session if one is open.
func (t *Tracker) Elapsed(ruleKey string) int {
	t.mu.Lock()
	defer t.mu.Unlock()
	return t.elapsedLocked(ruleKey)
}

func (t *Tracker) elapsedLocked(ruleKey string) int {
	s := t.state[ruleKey]
	if s == nil {
		return 0
	}
	total := s.accumulated
	if !s.activeSessionStart.IsZero() {
		total += s.lastActivityAt.Sub(s.activeSessionStart)
	}
	return int(total.Seconds())
}

// Snapshot returns a copy of elapsed seconds per rule.
func (t *Tracker) Snapshot() map[string]int {
	t.mu.Lock()
	defer t.mu.Unlock()
	return t.snapshotLocked()
}

func (t *Tracker) snapshotLocked() map[string]int {
	out := make(map[string]int, len(t.state))
	for k := range t.state {
		out[k] = t.elapsedLocked(k)
	}
	return out
}

// Reset clears all in-memory state and the on-disk file. Called by the
// scheduler at local midnight.
func (t *Tracker) Reset() {
	t.mu.Lock()
	t.state = make(map[string]*sessionState)
	t.bypasses = nil
	t.dirty = true
	t.mu.Unlock()
	_ = t.SaveToDisk()
}

// AddBypass records a manual unlock (M7).
func (t *Tracker) AddBypass(rec BypassRecord) {
	t.mu.Lock()
	t.bypasses = append(t.bypasses, rec)
	t.dirty = true
	t.mu.Unlock()
}

// Bypasses returns a copy of today's bypass records.
func (t *Tracker) Bypasses() []BypassRecord {
	t.mu.Lock()
	defer t.mu.Unlock()
	return append([]BypassRecord{}, t.bypasses...)
}

// Run starts the flush goroutine: closes idle sessions and persists state.
func (t *Tracker) Run() {
	go t.loop()
}

func (t *Tracker) loop() {
	defer close(t.done)
	ticker := time.NewTicker(flushInterval)
	defer ticker.Stop()
	for {
		select {
		case <-t.stop:
			_ = t.SaveToDisk()
			return
		case <-ticker.C:
			t.tick()
			_ = t.SaveToDisk()
		}
	}
}

func (t *Tracker) tick() {
	t.mu.Lock()
	defer t.mu.Unlock()
	now := t.now()
	for _, s := range t.state {
		if s.activeSessionStart.IsZero() {
			continue
		}
		if now.Sub(s.lastActivityAt) > idleThreshold {
			// Session ended at lastActivityAt — anything after is idle.
			s.accumulated += s.lastActivityAt.Sub(s.activeSessionStart)
			s.activeSessionStart = time.Time{}
			t.dirty = true
		}
	}
}

func (t *Tracker) Close() {
	close(t.stop)
	<-t.done
}

// dateKey returns YYYY-MM-DD in the given time's location.
func dateKey(t time.Time) string {
	y, m, d := t.Date()
	return fmt.Sprintf("%04d-%02d-%02d", y, m, d)
}
