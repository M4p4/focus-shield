package main

import (
	"context"
	"log"
	"time"
)

// runMidnightReset fires Tracker.Reset() at every local midnight.
//
// Implementation note: the wake-up time is recomputed from time.Now() each
// iteration rather than using a fixed Ticker. This handles DST springs
// forward / falls back, system clock changes, and laptop sleep correctly —
// time.Date normalises (d+1, 0:0:0), and Sleep until that absolute moment
// always lands on the next real midnight.
func runMidnightReset(ctx context.Context, t *Tracker) {
	for {
		now := time.Now()
		next := nextLocalMidnight(now)
		wait := next.Sub(now)
		log.Printf("midnight reset scheduled for %s (in %s)", next.Format(time.RFC3339), wait.Round(time.Second))

		select {
		case <-ctx.Done():
			return
		case <-time.After(wait):
			log.Print("midnight reached — resetting tracker")
			t.Reset()
		}
	}
}

func nextLocalMidnight(t time.Time) time.Time {
	y, m, d := t.Date()
	return time.Date(y, m, d+1, 0, 0, 0, 0, t.Location())
}
