package main

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"net"
	"os"
	"sync"
	"time"
)

// IPC speaks a newline-delimited JSON protocol. Each request is one JSON
// object terminated by '\n'; each response is one JSON object terminated by
// '\n'. The server also pushes unsolicited event objects on the same
// connection — distinguished by the absence of an "id" field that matches
// any pending request.
//
// Requests carry an optional "id" the server echoes back so the client can
// correlate. Push events have no "id".

type ipcMessage struct {
	Type            string          `json:"type"`
	ID              string          `json:"id,omitempty"`
	Enabled         *bool           `json:"enabled,omitempty"`
	Active          *bool           `json:"active,omitempty"`
	Rules           json.RawMessage `json:"rules,omitempty"`
	Domain          string          `json:"domain,omitempty"`
	Minutes         int             `json:"minutes,omitempty"`
	Password        string          `json:"password,omitempty"`
	CurrentPassword string          `json:"currentPassword,omitempty"`
	NewPassword     string          `json:"newPassword,omitempty"`
}

type ipcResponse struct {
	Type   string      `json:"type,omitempty"`
	ID     string      `json:"id,omitempty"`
	OK     bool        `json:"ok"`
	Error  string      `json:"error,omitempty"`
	Result interface{} `json:"result,omitempty"`
}

type ipcEvent struct {
	Type   string      `json:"type"`
	Result interface{} `json:"result,omitempty"`
}

type usageResult struct {
	Usage         map[string]int `json:"usage"`
	BypassesUsed  []BypassRecord `json:"bypassesUsed"`
	ActiveGrants  []ActiveGrant  `json:"activeGrants"`
}

type configResult struct {
	Config        Config `json:"config"`
	PasswordIsSet bool   `json:"passwordIsSet"`
}

type verifyResult struct {
	Valid bool `json:"valid"`
}

// IPCServer owns the Unix socket, accepts connections, dispatches requests,
// and broadcasts push events. It mutates the shared rules + config through
// the holder and config path. Concurrency: handlers run on per-connection
// goroutines; mutations are serialised by stateMu.
type IPCServer struct {
	socketPath string
	configPath string

	rules   *RulesetHolder
	tracker *Tracker
	auth    *Auth
	bypass  *Bypasser

	stateMu sync.Mutex
	config  Config

	clientsMu sync.Mutex
	clients   map[*ipcClient]struct{}

	ln net.Listener
}

type ipcClient struct {
	conn net.Conn
	send chan []byte
}

func NewIPCServer(socketPath, configPath string, initial Config, rules *RulesetHolder, tracker *Tracker, auth *Auth, bypass *Bypasser) *IPCServer {
	return &IPCServer{
		socketPath: socketPath,
		configPath: configPath,
		rules:      rules,
		tracker:    tracker,
		auth:       auth,
		bypass:     bypass,
		config:     initial,
		clients:    make(map[*ipcClient]struct{}),
	}
}

func (s *IPCServer) Start(ctx context.Context) error {
	// Stale socket from a previous run (or crash) would make Listen fail.
	_ = os.Remove(s.socketPath)
	ln, err := net.Listen("unix", s.socketPath)
	if err != nil {
		return fmt.Errorf("listen %s: %w", s.socketPath, err)
	}
	if err := os.Chmod(s.socketPath, 0o600); err != nil {
		return err
	}
	s.ln = ln

	go s.acceptLoop(ctx)
	go s.broadcastLoop(ctx)

	go func() {
		<-ctx.Done()
		_ = ln.Close()
		_ = os.Remove(s.socketPath)
	}()

	log.Printf("ipc listening on %s", s.socketPath)
	return nil
}

func (s *IPCServer) acceptLoop(ctx context.Context) {
	for {
		conn, err := s.ln.Accept()
		if err != nil {
			if errors.Is(err, net.ErrClosed) {
				return
			}
			log.Printf("ipc accept: %v", err)
			continue
		}
		c := &ipcClient{conn: conn, send: make(chan []byte, 32)}
		s.registerClient(c)
		go s.readLoop(ctx, c)
		go s.writeLoop(c)
	}
}

func (s *IPCServer) registerClient(c *ipcClient) {
	s.clientsMu.Lock()
	s.clients[c] = struct{}{}
	s.clientsMu.Unlock()
}

func (s *IPCServer) unregisterClient(c *ipcClient) {
	s.clientsMu.Lock()
	if _, ok := s.clients[c]; ok {
		delete(s.clients, c)
		close(c.send)
	}
	s.clientsMu.Unlock()
	_ = c.conn.Close()
}

func (s *IPCServer) writeLoop(c *ipcClient) {
	for buf := range c.send {
		// JSON-line: always append newline.
		if len(buf) == 0 || buf[len(buf)-1] != '\n' {
			buf = append(buf, '\n')
		}
		if _, err := c.conn.Write(buf); err != nil {
			return
		}
	}
}

func (s *IPCServer) readLoop(ctx context.Context, c *ipcClient) {
	defer s.unregisterClient(c)
	scanner := bufio.NewScanner(c.conn)
	scanner.Buffer(make([]byte, 64*1024), 1024*1024)
	for scanner.Scan() {
		line := scanner.Bytes()
		if len(line) == 0 {
			continue
		}
		var req ipcMessage
		if err := json.Unmarshal(line, &req); err != nil {
			s.sendTo(c, ipcResponse{ID: "", OK: false, Error: "invalid json: " + err.Error()})
			continue
		}
		resp := s.dispatch(req)
		s.sendTo(c, resp)
	}
}

func (s *IPCServer) sendTo(c *ipcClient, resp ipcResponse) {
	buf, err := json.Marshal(resp)
	if err != nil {
		return
	}
	select {
	case c.send <- buf:
	default:
		// Client backed up — drop the message rather than blocking.
		log.Printf("ipc: client send buffer full, dropping response")
	}
}

func (s *IPCServer) dispatch(req ipcMessage) ipcResponse {
	resp := ipcResponse{ID: req.ID, OK: true}

	// Password gate: when passwordRequired is true and a password is set,
	// state-mutating operations need a valid password in the request. The
	// app prompts the user and forwards their input here.
	mutators := map[string]bool{
		"set_enabled":              true,
		"update_rules":             true,
		"set_password_required":    true,
	}
	if mutators[req.Type] && s.passwordGateActive() && !s.auth.Verify(req.Password) {
		return ipcResponse{ID: req.ID, OK: false, Error: "password required"}
	}

	switch req.Type {
	case "set_enabled":
		if req.Enabled == nil {
			return ipcResponse{ID: req.ID, OK: false, Error: "missing 'enabled'"}
		}
		if err := s.setEnabled(*req.Enabled); err != nil {
			return ipcResponse{ID: req.ID, OK: false, Error: err.Error()}
		}
	case "get_usage":
		resp.Result = usageResult{Usage: s.tracker.Snapshot(), BypassesUsed: s.tracker.Bypasses(), ActiveGrants: s.bypass.ActiveGrants()}
	case "get_config":
		s.stateMu.Lock()
		cfg := s.config
		s.stateMu.Unlock()
		resp.Result = configResult{Config: cfg, PasswordIsSet: s.auth.IsSet()}
	case "update_rules":
		var rules []Rule
		if len(req.Rules) > 0 {
			if err := json.Unmarshal(req.Rules, &rules); err != nil {
				return ipcResponse{ID: req.ID, OK: false, Error: "rules: " + err.Error()}
			}
		}
		if err := s.updateRules(rules); err != nil {
			return ipcResponse{ID: req.ID, OK: false, Error: err.Error()}
		}
	case "set_user_active":
		if req.Active == nil {
			return ipcResponse{ID: req.ID, OK: false, Error: "missing 'active'"}
		}
		s.tracker.SetUserActive(*req.Active)
	case "verify_password":
		resp.Result = verifyResult{Valid: s.auth.Verify(req.Password)}
	case "set_password":
		// First-time set: current may be empty. Change: current required.
		if err := s.auth.Set(req.CurrentPassword, req.NewPassword); err != nil {
			return ipcResponse{ID: req.ID, OK: false, Error: err.Error()}
		}
	case "set_password_required":
		// Enable or disable the gate. Enabling implicitly requires a
		// password to exist; disabling clears it after verifying.
		if req.Enabled == nil {
			return ipcResponse{ID: req.ID, OK: false, Error: "missing 'enabled'"}
		}
		if *req.Enabled && !s.auth.IsSet() {
			return ipcResponse{ID: req.ID, OK: false, Error: "set a password first"}
		}
		if !*req.Enabled && s.auth.IsSet() {
			if err := s.auth.Clear(req.Password); err != nil {
				return ipcResponse{ID: req.ID, OK: false, Error: err.Error()}
			}
		}
		if err := s.setPasswordRequired(*req.Enabled); err != nil {
			return ipcResponse{ID: req.ID, OK: false, Error: err.Error()}
		}
	default:
		return ipcResponse{ID: req.ID, OK: false, Error: "unknown type: " + req.Type}
	}
	return resp
}

// passwordGateActive returns true when the config flag is on AND a password
// has actually been set. Both must be true for the gate to fire.
func (s *IPCServer) passwordGateActive() bool {
	s.stateMu.Lock()
	required := s.config.PasswordRequired
	s.stateMu.Unlock()
	return required && s.auth.IsSet()
}

// PasswordGateActive is exported for the unlock endpoint to consult.
func (s *IPCServer) PasswordGateActive() bool { return s.passwordGateActive() }
func (s *IPCServer) Auth() *Auth              { return s.auth }

func (s *IPCServer) setPasswordRequired(on bool) error {
	s.stateMu.Lock()
	s.config.PasswordRequired = on
	cfg := s.config
	s.stateMu.Unlock()
	return SaveConfig(s.configPath, cfg)
}

func (s *IPCServer) setEnabled(on bool) error {
	s.stateMu.Lock()
	s.config.Enabled = on
	cfg := s.config
	s.stateMu.Unlock()

	s.rules.Set(BuildRuleset(cfg))
	return SaveConfig(s.configPath, cfg)
}

func (s *IPCServer) updateRules(rules []Rule) error {
	s.stateMu.Lock()
	s.config.Rules = rules
	cfg := s.config
	s.stateMu.Unlock()

	s.rules.Set(BuildRuleset(cfg))
	return SaveConfig(s.configPath, cfg)
}

// broadcastLoop pushes usage_updated events at a fixed cadence to every
// connected client. 1s gives the popover near-realtime updates without
// meaningful CPU cost — payload is a few hundred bytes of JSON.
func (s *IPCServer) broadcastLoop(ctx context.Context) {
	ticker := time.NewTicker(1 * time.Second)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			evt := ipcEvent{
				Type:   "usage_updated",
				Result: usageResult{Usage: s.tracker.Snapshot(), BypassesUsed: s.tracker.Bypasses(), ActiveGrants: s.bypass.ActiveGrants()},
			}
			s.broadcast(evt)
		}
	}
}

func (s *IPCServer) broadcast(evt ipcEvent) {
	buf, err := json.Marshal(evt)
	if err != nil {
		return
	}
	s.clientsMu.Lock()
	defer s.clientsMu.Unlock()
	for c := range s.clients {
		select {
		case c.send <- buf:
		default:
			// Slow client — skip this tick rather than blocking.
		}
	}
}
