package main

import (
	"bytes"
	_ "embed"
	"fmt"
	"html/template"
	"strings"
	"time"
)

//go:embed block_page.html
var blockPageHTML string

var blockTmpl = template.Must(template.New("block").Parse(blockPageHTML))

type blockData struct {
	Site             string  // pretty display name, e.g. "youtube.com"
	RuleKey          string  // canonical rule key for the bypass POST
	Reason           string  // human-readable reason
	ShowUsage        bool    // false for mode=blocked (no quota to show)
	UsageLabel       string  // "62 / 60 min" when timed
	UsagePercent     float64 // 0..100
	ShowUnlocksIn    bool    // false for mode=blocked (no daily reset to count down to)
	UnlocksIn        string  // "4h 23m"
	RequiresPassword bool    // bypass form needs a password field
}

func (b blockData) ShowStats() bool { return b.ShowUsage || b.ShowUnlocksIn }

// renderBlockPage renders the HTML body for a single blocked request.
func renderBlockPage(host string, rule *Rule, elapsed int, now time.Time, requiresPassword bool) []byte {
	data := blockData{
		Site:             prettySiteName(host),
		RuleKey:          rule.Domain,
		RequiresPassword: requiresPassword,
	}

	switch rule.Mode {
	case ModeBlocked:
		data.Reason = "this site is fully blocked today."
		data.ShowUsage = false
		data.ShowUnlocksIn = false
	case ModeTimed:
		limitMin := rule.DailyLimitSeconds / 60
		elapsedMin := elapsed / 60
		data.Reason = "daily time limit reached."
		data.ShowUsage = true
		data.ShowUnlocksIn = true
		data.UnlocksIn = humanDuration(timeUntilMidnight(now))
		data.UsageLabel = fmt.Sprintf("%d / %d min", elapsedMin, limitMin)
		if rule.DailyLimitSeconds > 0 {
			pct := float64(elapsed) / float64(rule.DailyLimitSeconds) * 100
			if pct > 100 {
				pct = 100
			}
			data.UsagePercent = pct
		}
	default:
		data.Reason = "blocked."
		data.ShowUnlocksIn = true
		data.UnlocksIn = humanDuration(timeUntilMidnight(now))
	}

	var buf bytes.Buffer
	_ = blockTmpl.Execute(&buf, data)
	return buf.Bytes()
}

func prettySiteName(host string) string {
	h := strings.TrimPrefix(host, "www.")
	if i := strings.Index(h, ":"); i >= 0 {
		h = h[:i]
	}
	return h
}

func timeUntilMidnight(now time.Time) time.Duration {
	return nextLocalMidnight(now).Sub(now)
}

// humanDuration: "4h 23m", "23m", "47s".
func humanDuration(d time.Duration) string {
	if d <= 0 {
		return "moments"
	}
	h := int(d.Hours())
	m := int(d.Minutes()) % 60
	if h > 0 {
		return fmt.Sprintf("%dh %dm", h, m)
	}
	if m > 0 {
		return fmt.Sprintf("%dm", m)
	}
	return fmt.Sprintf("%ds", int(d.Seconds()))
}
