// turbo-net — a Tailscale node embedded in the Turbo apps (tsnet, userspace).
//
// No daemon, no root, no system extension: the app launches this helper the
// way it launches ffmpeg, and the helper joins the Turbo tailnet on its own.
// One process per app = one node. The app then opens tunnels on demand with
// one JSON command per line on stdin:
//
//	{"cmd":"listen","id":"srt","port":8890,"to":"127.0.0.1:8890"}
//	    Receiver: accept UDP on the tailnet, forward to the local MediaMTX.
//	{"cmd":"dial","id":"s1","to":"100.64.0.7:8890"}
//	    Streamer: open a local UDP port; whatever ffmpeg sends there goes to
//	    the peer, replies come back. Answered with a "local" event.
//	{"cmd":"close","id":"s1"}
//
// Everything the app needs to know arrives on stdout, one JSON object per
// line: auth_url (login needed), up (node has an IP), listening / local
// (tunnel ready), peer (direct or relayed path, every few seconds), closed,
// error.
package main

import (
	"bufio"
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"net"
	"net/netip"
	"os"
	"regexp"
	"strings"
	"sync"
	"time"

	"tailscale.com/tsnet"
)

var (
	stateDir  = flag.String("state", "", "directory for the node's state (identity, keys)")
	hostname  = flag.String("hostname", "turbo", "node name shown in the tailnet")
	authKey   = flag.String("authkey", os.Getenv("TS_AUTHKEY"), "pre-authorised key; a login URL is printed if absent")
	ephemeral = flag.Bool("ephemeral", false, "node disappears from the tailnet when this process exits (use with a fresh key each launch)")
)

var emitMu sync.Mutex

func emit(kv map[string]any) {
	emitMu.Lock()
	defer emitMu.Unlock()
	b, _ := json.Marshal(kv)
	fmt.Fprintln(os.Stdout, string(b))
}

func fail(format string, a ...any) {
	emit(map[string]any{"event": "error", "message": fmt.Sprintf(format, a...)})
	os.Exit(1)
}

var authURLRe = regexp.MustCompile(`https://login\.tailscale\.com/a/[A-Za-z0-9]+`)

// One UDP "flow" = one remote address talking through a tunnel; each gets its
// own socket towards the other side so replies find their way back.
type flow struct {
	conn net.Conn
	last time.Time
}

type tunnel struct {
	id     string
	closer func()
}

func main() {
	flag.Parse()
	if *stateDir == "" {
		fail("--state is required")
	}
	if err := os.MkdirAll(*stateDir, 0o700); err != nil {
		fail("state dir: %v", err)
	}

	srv := &tsnet.Server{
		Dir:       *stateDir,
		Hostname:  *hostname,
		AuthKey:   *authKey,
		Ephemeral: *ephemeral,
		Logf:      func(string, ...any) {},
	}
	// The login URL only ever appears in the user-facing log line; lift it out.
	srv.UserLogf = func(format string, args ...any) {
		line := fmt.Sprintf(format, args...)
		if u := authURLRe.FindString(line); u != "" {
			emit(map[string]any{"event": "auth_url", "url": u})
		}
	}

	ctx := context.Background()
	emit(map[string]any{"event": "starting", "hostname": *hostname})
	if _, err := srv.Up(ctx); err != nil {
		fail("tailscale up: %v", err)
	}
	ip4, _ := srv.TailscaleIPs()
	emit(map[string]any{"event": "up", "ip": ip4.String(), "hostname": *hostname})

	var mu sync.Mutex
	tunnels := map[string]*tunnel{}

	sc := bufio.NewScanner(os.Stdin)
	sc.Buffer(make([]byte, 64*1024), 64*1024)
	for sc.Scan() {
		var cmd struct {
			Cmd  string `json:"cmd"`
			ID   string `json:"id"`
			Port int    `json:"port"`
			To   string `json:"to"`
		}
		if err := json.Unmarshal(sc.Bytes(), &cmd); err != nil || cmd.ID == "" {
			emit(map[string]any{"event": "error", "message": "bad command"})
			continue
		}
		mu.Lock()
		if t := tunnels[cmd.ID]; t != nil {
			t.closer()
			delete(tunnels, cmd.ID)
		}
		switch cmd.Cmd {
		case "listen":
			if c, err := listenTunnel(ctx, srv, cmd.ID, cmd.Port, cmd.To); err != nil {
				emit(map[string]any{"event": "error", "id": cmd.ID, "message": err.Error()})
			} else {
				tunnels[cmd.ID] = &tunnel{id: cmd.ID, closer: c}
			}
		case "dial":
			if c, err := dialTunnel(ctx, srv, cmd.ID, cmd.To); err != nil {
				emit(map[string]any{"event": "error", "id": cmd.ID, "message": err.Error()})
			} else {
				tunnels[cmd.ID] = &tunnel{id: cmd.ID, closer: c}
			}
		case "close":
			emit(map[string]any{"event": "closed", "id": cmd.ID})
		case "logout":
			// Tell the control server to forget this node before the app wipes the
			// local state: Tailscale refuses to register a node key it already knows
			// under another account ("device already exists; please log out").
			if lc, err := srv.LocalClient(); err == nil {
				lctx, cancel := context.WithTimeout(ctx, 15*time.Second)
				err = lc.Logout(lctx)
				cancel()
				if err != nil {
					emit(map[string]any{"event": "error", "id": cmd.ID, "message": "logout: " + err.Error()})
				}
			}
			emit(map[string]any{"event": "logged_out", "id": cmd.ID})
		default:
			emit(map[string]any{"event": "error", "id": cmd.ID, "message": "unknown cmd"})
		}
		mu.Unlock()
	}
	// stdin closed = the app is gone; take the node down with us.
	srv.Close()
}

// listen: tailnet :port → local `to`
func listenTunnel(ctx context.Context, srv *tsnet.Server, id string, port int, to string) (func(), error) {
	pc, err := srv.ListenPacket("udp", fmt.Sprintf(":%d", port))
	if err != nil {
		return nil, fmt.Errorf("listen on tailnet: %w", err)
	}
	flows := &flowTable{m: map[string]*flow{}}
	go flows.reap()
	go func() {
		buf := make([]byte, 65535)
		for {
			n, raddr, err := pc.ReadFrom(buf)
			if err != nil {
				return
			}
			f := flows.get(raddr.String(), func() (net.Conn, error) { return net.Dial("udp", to) },
				func(c net.Conn) { // replies: local → tailnet
					rb := make([]byte, 65535)
					for {
						m, err := c.Read(rb)
						if err != nil {
							return
						}
						pc.WriteTo(rb[:m], raddr)
					}
				})
			if f != nil {
				f.conn.Write(buf[:n])
			}
		}
	}()
	emit(map[string]any{"event": "listening", "id": id, "port": port, "to": to})
	return func() { pc.Close(); flows.closeAll(); emit(map[string]any{"event": "closed", "id": id}) }, nil
}

// dial: local 127.0.0.1:<picked> → tailnet `to`
func dialTunnel(ctx context.Context, srv *tsnet.Server, id string, to string) (func(), error) {
	lsock, err := net.ListenUDP("udp", &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1), Port: 0})
	if err != nil {
		return nil, fmt.Errorf("local listen: %w", err)
	}
	flows := &flowTable{m: map[string]*flow{}}
	go flows.reap()
	stop := make(chan struct{})
	go reportPeer(ctx, srv, id, to, stop)
	go func() {
		buf := make([]byte, 65535)
		for {
			n, from, err := lsock.ReadFromUDP(buf)
			if err != nil {
				return
			}
			f := flows.get(from.String(), func() (net.Conn, error) { return srv.Dial(ctx, "udp", to) },
				func(c net.Conn) { // replies: tailnet → local
					rb := make([]byte, 65535)
					for {
						m, err := c.Read(rb)
						if err != nil {
							return
						}
						lsock.WriteToUDP(rb[:m], from)
					}
				})
			if f == nil {
				emit(map[string]any{"event": "error", "id": id, "message": "tailnet dial failed"})
				continue
			}
			f.conn.Write(buf[:n])
		}
	}()
	emit(map[string]any{"event": "local", "id": id, "addr": lsock.LocalAddr().String(), "to": to})
	return func() {
		close(stop)
		lsock.Close()
		flows.closeAll()
		emit(map[string]any{"event": "closed", "id": id})
	}, nil
}

type flowTable struct {
	mu sync.Mutex
	m  map[string]*flow
}

func (t *flowTable) get(key string, open func() (net.Conn, error), pump func(net.Conn)) *flow {
	t.mu.Lock()
	defer t.mu.Unlock()
	f := t.m[key]
	if f == nil {
		c, err := open()
		if err != nil {
			return nil
		}
		f = &flow{conn: c}
		t.m[key] = f
		go pump(c)
	}
	f.last = time.Now()
	return f
}

// Idle flows are closed after a minute of silence; their pump ends on the closed socket.
func (t *flowTable) reap() {
	for range time.Tick(15 * time.Second) {
		t.mu.Lock()
		for k, f := range t.m {
			if time.Since(f.last) > time.Minute {
				f.conn.Close()
				delete(t.m, k)
			}
		}
		t.mu.Unlock()
	}
}

func (t *flowTable) closeAll() {
	t.mu.Lock()
	defer t.mu.Unlock()
	for k, f := range t.m {
		f.conn.Close()
		delete(t.m, k)
	}
}

// Every few seconds: is the path to the peer direct, or through a DERP relay?
// The app shows this, because a relayed path is the moment to use turborelay.
func reportPeer(ctx context.Context, srv *tsnet.Server, id, to string, stop <-chan struct{}) {
	host, _, err := net.SplitHostPort(to)
	if err != nil {
		return
	}
	want, err := netip.ParseAddr(host)
	if err != nil {
		return
	}
	lc, err := srv.LocalClient()
	if err != nil {
		return
	}
	first := true
	for {
		if !first {
			select {
			case <-stop:
				return
			case <-time.After(5 * time.Second):
			}
		}
		first = false
		st, err := lc.Status(ctx)
		if err != nil {
			continue
		}
		found := false
		for _, p := range st.Peer {
			for _, a := range p.TailscaleIPs {
				if a == want {
					found = true
					emit(map[string]any{
						"event": "peer", "id": id, "addr": want.String(), "online": p.Online,
						"direct": p.CurAddr != "", "relay": strings.TrimSpace(p.Relay),
						"rx": p.RxBytes, "tx": p.TxBytes,
					})
				}
			}
		}
		// Not in our netmap at all = the other app is on a DIFFERENT account/tailnet,
		// or it isn't running. The single most common setup mistake, so name it.
		if !found {
			emit(map[string]any{"event": "peer_unknown", "id": id, "addr": want.String(),
				"self": st.Self.TailscaleIPs, "peers": len(st.Peer)})
		}
	}
}
