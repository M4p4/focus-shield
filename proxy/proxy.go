package main

import (
	"crypto/tls"
	"encoding/json"
	"net/http"
	"strings"
	"time"

	"github.com/elazarl/goproxy"
)

// installCA wires our persistent root CA into goproxy's globals. goproxy's
// default OkConnect / MitmConnect actions capture the CA at package init,
// so we have to rebuild them after swapping GoproxyCa.
func installCA(ca tls.Certificate) {
	goproxy.GoproxyCa = ca
	tlsCfg := goproxy.TLSConfigFromCA(&ca)
	goproxy.OkConnect = &goproxy.ConnectAction{Action: goproxy.ConnectAccept, TLSConfig: tlsCfg}
	goproxy.MitmConnect = &goproxy.ConnectAction{Action: goproxy.ConnectMitm, TLSConfig: tlsCfg}
	goproxy.HTTPMitmConnect = &goproxy.ConnectAction{Action: goproxy.ConnectHTTPMitm, TLSConfig: tlsCfg}
	goproxy.RejectConnect = &goproxy.ConnectAction{Action: goproxy.ConnectReject, TLSConfig: tlsCfg}
}

// internalPath is the path the block page POSTs to. Served on whatever host
// the user is currently blocked from (same-origin from the block page), so
// we sidestep every category of DNS / proxy-bypass / mixed-content gotcha
// that a synthetic hostname would introduce. The /.well-known/ prefix
// (RFC 8615) keeps us in a namespace conventionally reserved for this kind
// of thing.
const internalPath = "/.well-known/__bhb__/unlock"

// newProxy builds the MITM proxy with the rules engine, tracker, bypass
// manager and auth wired in. ipc is consulted for the password-gate
// state so the block page renders a password field when needed.
func newProxy(rules *RulesetHolder, tracker *Tracker, bypass *Bypasser, ipc *IPCServer, passthrough *PassthroughList, verbose bool) *goproxy.ProxyHttpServer {
	p := goproxy.NewProxyHttpServer()
	p.Verbose = verbose

	// Decide per-CONNECT whether to MITM. Hosts on the passthrough list
	// are tunneled untouched so cert-pinning sites (Apple, banks, …)
	// don't break.
	p.OnRequest().HandleConnect(goproxy.FuncHttpsHandler(func(host string, ctx *goproxy.ProxyCtx) (*goproxy.ConnectAction, string) {
		if passthrough.Matches(hostOnly(host)) {
			return goproxy.OkConnect, host
		}
		return goproxy.MitmConnect, host
	}))

	p.OnRequest().DoFunc(func(req *http.Request, ctx *goproxy.ProxyCtx) (*http.Request, *http.Response) {
		host := hostOnly(req.Host)

		// Internal endpoints are matched by path on whatever host the
		// request is going to — same-origin from the block page, so no
		// CORS / DNS / mixed-content surprises. Checked before any rule
		// lookup so it can't be accidentally blocked by an over-broad
		// rule covering the host.
		if req.URL.Path == internalPath {
			return req, handleUnlock(req, bypass, tracker, ipc)
		}

		rs := rules.Get()
		rule := rs.Match(host)
		if rule == nil {
			return req, nil
		}

		// Active bypass takes precedence over the rule's normal action.
		if bypass.IsActive(rule.Domain) {
			return req, nil
		}

		switch rule.Mode {
		case ModeBlocked:
			return req, blockResponse(req, host, rule, 0, ipc)
		case ModeTimed:
			elapsed := tracker.Elapsed(rule.Domain)
			if elapsed >= rule.DailyLimitSeconds {
				return req, blockResponse(req, host, rule, elapsed, ipc)
			}
			tracker.OnActivity(rule.Domain)
			return req, nil
		default:
			return req, nil
		}
	})

	return p
}

func blockResponse(req *http.Request, host string, rule *Rule, elapsed int, ipc *IPCServer) *http.Response {
	body := renderBlockPage(host, rule, elapsed, time.Now(), ipc.PasswordGateActive())
	resp := goproxy.NewResponse(req, "text/html; charset=utf-8", http.StatusOK, string(body))
	resp.Header.Set("Cache-Control", "no-store")
	return resp
}

type unlockRequest struct {
	Domain   string `json:"domain"`
	Minutes  int    `json:"minutes"`
	Password string `json:"password,omitempty"` // honored in M8
}

func handleUnlock(req *http.Request, bypass *Bypasser, tracker *Tracker, ipc *IPCServer) *http.Response {
	if req.Method != http.MethodPost {
		return jsonResponse(req, http.StatusMethodNotAllowed, map[string]any{"ok": false, "error": "POST only"})
	}
	defer req.Body.Close()
	var body unlockRequest
	if err := json.NewDecoder(req.Body).Decode(&body); err != nil {
		return jsonResponse(req, http.StatusBadRequest, map[string]any{"ok": false, "error": "bad json"})
	}
	if body.Domain == "" || body.Minutes <= 0 {
		return jsonResponse(req, http.StatusBadRequest, map[string]any{"ok": false, "error": "missing domain/minutes"})
	}
	// Clamp the duration to a sane range; the UI always sends 5, but a
	// hand-crafted request shouldn't be able to grant itself a week.
	if body.Minutes > 60 {
		body.Minutes = 60
	}

	if ipc.PasswordGateActive() && !ipc.Auth().Verify(body.Password) {
		return jsonResponse(req, http.StatusUnauthorized, map[string]any{"ok": false, "error": "wrong password"})
	}

	exp := bypass.Grant(body.Domain, time.Duration(body.Minutes)*time.Minute)
	tracker.AddBypass(BypassRecord{
		Domain:  body.Domain,
		At:      time.Now().UTC(),
		Minutes: body.Minutes,
	})
	return jsonResponse(req, http.StatusOK, map[string]any{
		"ok":        true,
		"expiresAt": exp.UTC().Format(time.RFC3339),
	})
}

func jsonResponse(req *http.Request, status int, payload any) *http.Response {
	buf, _ := json.Marshal(payload)
	resp := goproxy.NewResponse(req, "application/json", status, string(buf))
	resp.Header.Set("Cache-Control", "no-store")
	resp.Header.Set("Access-Control-Allow-Origin", "*")
	return resp
}

func hostOnly(hostport string) string {
	if i := strings.IndexByte(hostport, ':'); i >= 0 {
		return hostport[:i]
	}
	return hostport
}
