package main

import (
	"encoding/binary"
	"encoding/json"
	"io"
	"net"
	"os"
	"path/filepath"
	"sync"
	"syscall"
	"testing"
	"time"

	"github.com/hanwen/go-fuse/v2/fs"
	"github.com/hanwen/go-fuse/v2/fuse"
)

// fakeServer is an in-test VFS unix-socket server speaking the same framed
// JSON-RPC protocol as Noizu.MCP.Transport.VFSSocket.
type fakeServer struct {
	t      *testing.T
	ln     net.Listener
	apiKey string
	mu     sync.Mutex

	// handler decides the (result, error) for each request. nil falls back
	// to a tiny built-in tree.
	handler func(method string, params map[string]any) (any, *rpcError)

	// dropAfterAuth closes the connection right after the FIRST successful
	// auth handshake, to exercise reconnect logic.
	dropAfterAuth bool
	dropped       bool

	// delay makes every response slower than the client timeout when set.
	delay time.Duration

	conns []net.Conn
}

func startFakeServer(t *testing.T, s *fakeServer) *fakeServer {
	t.Helper()
	dir, err := os.MkdirTemp("", "mcp-fuse-test")
	if err != nil {
		t.Fatal(err)
	}
	sock := filepath.Join(dir, "vfs.sock")
	ln, err := net.Listen("unix", sock)
	if err != nil {
		t.Fatal(err)
	}
	s.t = t
	s.ln = ln
	go s.acceptLoop()
	t.Cleanup(func() {
		ln.Close()
		s.mu.Lock()
		conns := append([]net.Conn(nil), s.conns...)
		s.mu.Unlock()
		for _, c := range conns {
			c.Close()
		}
		os.RemoveAll(dir)
	})
	return s
}

func (s *fakeServer) Path() string { return s.ln.Addr().String() }

func (s *fakeServer) acceptLoop() {
	for {
		conn, err := s.ln.Accept()
		if err != nil {
			return
		}
		s.mu.Lock()
		s.conns = append(s.conns, conn)
		s.mu.Unlock()
		go s.serve(conn)
	}
}

func (s *fakeServer) serve(conn net.Conn) {
	defer conn.Close()
	authenticated := false
	for {
		var lenBuf [4]byte
		if _, err := io.ReadFull(conn, lenBuf[:]); err != nil {
			return
		}
		size := binary.BigEndian.Uint32(lenBuf[:])
		body := make([]byte, size)
		if _, err := io.ReadFull(conn, body); err != nil {
			return
		}
		var req struct {
			JSONRPC string         `json:"jsonrpc"`
			ID      uint64         `json:"id"`
			Method  string         `json:"method"`
			Params  map[string]any `json:"params"`
		}
		if err := json.Unmarshal(body, &req); err != nil {
			continue
		}

		if !authenticated {
			if req.Method != "vfs/auth" {
				s.reply(conn, req.ID, nil, &rpcError{Code: codeAuthFailed, Message: "auth required"})
				return
			}
			if key, _ := req.Params["api_key"].(string); key != s.apiKey {
				s.reply(conn, req.ID, nil, &rpcError{Code: codeAuthFailed, Message: "invalid token"})
				return
			}
			authenticated = true
			s.reply(conn, req.ID, map[string]any{"authenticated": true, "session_id": "test-session"}, nil)
			if s.takeDropAfterAuth() {
				return
			}
			continue
		}

		if s.delay > 0 {
			time.Sleep(s.delay)
		}
		result, rpcErr := s.dispatch(req.Method, req.Params)
		s.reply(conn, req.ID, result, rpcErr)
	}
}

func (s *fakeServer) takeDropAfterAuth() bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	if !s.dropAfterAuth || s.dropped {
		return false
	}
	s.dropped = true
	return true
}

func (s *fakeServer) closeFirstConn() {
	s.mu.Lock()
	defer s.mu.Unlock()
	if len(s.conns) > 0 {
		s.conns[0].Close()
	}
}

func (s *fakeServer) dispatch(method string, params map[string]any) (any, *rpcError) {
	if s.handler != nil {
		return s.handler(method, params)
	}
	// Built-in default tree.
	switch method {
	case "vfs/stat":
		path, _ := params["path"].(string)
		if path == "/hello.txt" {
			return nodeMap("file", 6, 1700000000000, 7, true, false), nil
		}
		if path == "/" {
			return nodeMap("dir", 0, 1700000000000, 1, true, false), nil
		}
		return nil, &rpcError{Code: codeNotFound, Message: "not found", Data: map[string]any{"errno_atom": "enoent"}}
	case "vfs/list":
		return map[string]any{"entries": []any{map[string]any{"name": "hello.txt", "type": "file", "size": 6, "version": 7}}}, nil
	case "vfs/read":
		path, _ := params["path"].(string)
		if path == "/hello.txt" {
			return map[string]any{"content": "hello\n", "version": 7}, nil
		}
		return nil, &rpcError{Code: codeNotFound, Message: "not found", Data: map[string]any{"errno_atom": "enoent"}}
	case "vfs/write":
		path, _ := params["path"].(string)
		data, _ := params["data"].(string)
		return nodeMap("file", int64(len(data)), 1700000000001, 8, true, false), mapOrNil(path)
	}
	return nil, &rpcError{Code: -32601, Message: "method not found"}
}

func mapOrNil(path string) *rpcError {
	if path == "/conflict.txt" {
		return &rpcError{Code: codeAccess, Message: "stale version", Data: map[string]any{"errno_atom": "eacces"}}
	}
	return nil
}

func nodeMap(typ string, size, mtime, version int64, writable, exec bool) map[string]any {
	return map[string]any{
		"type": typ, "size": size, "mtime": mtime, "version": version,
		"writable": writable, "executable": exec, "xattrs": map[string]any{},
	}
}

func (s *fakeServer) reply(conn net.Conn, id uint64, result any, rpcErr *rpcError) {
	resp := rpcResponse{JSONRPC: "2.0", ID: id}
	if rpcErr != nil {
		resp.Error = rpcErr
	} else {
		raw, _ := json.Marshal(result)
		resp.Result = raw
	}
	raw, err := json.Marshal(resp)
	if err != nil {
		return
	}
	frame := make([]byte, 4+len(raw))
	binary.BigEndian.PutUint32(frame, uint32(len(raw)))
	copy(frame[4:], raw)
	conn.Write(frame)
}

func testClient(t *testing.T, s *fakeServer) *Client {
	t.Helper()
	c := NewClient(s.Path(), s.apiKey, 2*time.Second, false)
	if errno := c.Ensure(); errno != 0 {
		t.Fatalf("Ensure: %v", errno)
	}
	t.Cleanup(c.Close)
	return c
}

func TestAuthSuccess(t *testing.T) {
	s := startFakeServer(t, &fakeServer{apiKey: "sekrit"})
	c := NewClient(s.Path(), "sekrit", time.Second, false)
	if errno := c.Ensure(); errno != 0 {
		t.Fatalf("auth failed: %v", errno)
	}
}

func TestAuthFailure(t *testing.T) {
	s := startFakeServer(t, &fakeServer{apiKey: "sekrit"})
	c := NewClient(s.Path(), "wrong-key", time.Second, false)
	if errno := c.Ensure(); errno != syscall.EACCES {
		t.Fatalf("want EACCES, got %v", errno)
	}
}

func TestStatRoundTripAndFraming(t *testing.T) {
	var sawMethod string
	var sawParams map[string]any
	s := startFakeServer(t, &fakeServer{
		apiKey: "k",
		handler: func(method string, params map[string]any) (any, *rpcError) {
			sawMethod = method
			sawParams = params
			return nodeMap("file", 42, 1700000000000, 3, true, true), nil
		},
	})
	c := testClient(t, s)
	node, errno := c.Stat("/foo")
	if errno != 0 {
		t.Fatalf("Stat: %v", errno)
	}
	if sawMethod != "vfs/stat" || sawParams["path"] != "/foo" {
		t.Fatalf("server saw %s %v", sawMethod, sawParams)
	}
	if node.Type != "file" || node.Size != 42 || node.Version != 3 || !node.Executable || !node.Writable {
		t.Fatalf("bad node: %+v", node)
	}
	if node.Mtime != 1700000000000 {
		t.Fatalf("mtime must stay unix-ms, got %d", node.Mtime)
	}
}

func TestErrnoMapping(t *testing.T) {
	cases := []struct {
		code int
		atom string
		want syscall.Errno
	}{
		{codeNotFound, "enoent", syscall.ENOENT},
		{codeAccess, "eacces", syscall.EACCES},
		{codeExists, "eexist", syscall.EEXIST},
		{codeReadOnly, "erofs", syscall.EROFS},
		{codeIsDir, "eisdir", syscall.EISDIR},
		{codeNotDir, "enotdir", syscall.ENOTDIR},
		{codeNotEmpty, "enotempty", syscall.ENOTEMPTY},
		{codeNoSys, "enosys", syscall.ENOSYS},
		// errno_atom wins over the code when they disagree
		{codeNotFound, "eisdir", syscall.EISDIR},
		// code fallback when atom is unknown
		{-99999, "weird", syscall.EIO},
		// code fallback when atom is absent
		{codeReadOnly, "", syscall.EROFS},
	}
	for _, tc := range cases {
		var data map[string]any
		if tc.atom != "" {
			data = map[string]any{"errno_atom": tc.atom}
		}
		got := errnoFromRPC(&rpcError{Code: tc.code, Data: data})
		if got != tc.want {
			t.Errorf("code=%d atom=%q: want %v got %v", tc.code, tc.atom, tc.want, got)
		}
	}
}

func TestListPaginationLoop(t *testing.T) {
	pages := []struct {
		cursor string
		names  []string
		next   string
	}{
		{"", []string{"a"}, "p2"},
		{"p2", []string{"b"}, "p3"},
		{"p3", []string{"c"}, ""},
	}
	var seen []string
	s := startFakeServer(t, &fakeServer{
		apiKey: "k",
		handler: func(method string, params map[string]any) (any, *rpcError) {
			cursor, _ := params["cursor"].(string)
			seen = append(seen, cursor)
			for _, p := range pages {
				if p.cursor == cursor {
					entries := []any{}
					for _, n := range p.names {
						entries = append(entries, map[string]any{"name": n, "type": "file"})
					}
					out := map[string]any{"entries": entries}
					if p.next != "" {
						out["nextCursor"] = p.next
					}
					return out, nil
				}
			}
			return nil, &rpcError{Code: codeNotFound, Message: "bad cursor"}
		},
	})
	root := newVFSRoot(testClient(t, s), NewCache(time.Second, time.Second), false)
	node := &vfsNode{root: root, path: "/"}
	entries, errno := node.listAll()
	if errno != 0 {
		t.Fatalf("listAll: %v", errno)
	}
	if len(entries) != 3 || entries[0].Name != "a" || entries[2].Name != "c" {
		t.Fatalf("want [a b c], got %+v", entries)
	}
	if len(seen) != 3 || seen[0] != "" || seen[1] != "p2" || seen[2] != "p3" {
		t.Fatalf("cursor chain wrong: %v", seen)
	}
}

func TestReconnectAfterDrop(t *testing.T) {
	s := startFakeServer(t, &fakeServer{apiKey: "k", dropAfterAuth: true})
	c := NewClient(s.Path(), "k", time.Second, false)
	if errno := c.Ensure(); errno != 0 {
		t.Fatalf("first auth: %v", errno)
	}
	// Connection was dropped by the server after auth; the next call must
	// transparently redial + re-auth.
	node, errno := c.Stat("/")
	if errno != 0 {
		t.Fatalf("Stat after drop: %v", errno)
	}
	if node.Type != "dir" {
		t.Fatalf("unexpected node %+v", node)
	}
}

func TestReconnectMidCall(t *testing.T) {
	// Server handler closes the underlying conn under the client: the very
	// first request fails, the retry on a fresh connection succeeds.
	var s *fakeServer
	var calls int
	s = startFakeServer(t, &fakeServer{
		apiKey: "k",
		handler: func(method string, params map[string]any) (any, *rpcError) {
			calls++
			if calls == 1 {
				s.closeFirstConn() // kill the client's live connection
			}
			return nodeMap("file", 1, 0, 1, true, false), nil
		},
	})
	c := testClient(t, s)
	if _, errno := c.Stat("/x"); errno != 0 {
		t.Fatalf("Stat should succeed after reconnect: %v", errno)
	}
}

func TestTimeoutMapsToEstale(t *testing.T) {
	s := startFakeServer(t, &fakeServer{apiKey: "k", delay: 2 * time.Second})
	c := NewClient(s.Path(), "k", 300*time.Millisecond, false)
	if errno := c.Ensure(); errno != 0 {
		t.Fatalf("auth: %v", errno)
	}
	if _, errno := c.Stat("/"); errno != syscall.ESTALE {
		t.Fatalf("want ESTALE on timeout, got %v", errno)
	}
}

func TestWriteFlushReadModifyWrite(t *testing.T) {
	var written string
	var writePath string
	s := startFakeServer(t, &fakeServer{
		apiKey: "k",
		handler: func(method string, params map[string]any) (any, *rpcError) {
			switch method {
			case "vfs/stat":
				path, _ := params["path"].(string)
				if path == "/log.txt" {
					return nodeMap("file", 6, 0, 7, true, false), nil
				}
				return nil, &rpcError{Code: codeNotFound, Message: "nf", Data: map[string]any{"errno_atom": "enoent"}}
			case "vfs/read":
				return map[string]any{"content": "hello\n", "version": 7}, nil
			case "vfs/write":
				writePath, _ = params["path"].(string)
				written, _ = params["data"].(string)
				return nodeMap("file", int64(len(written)), 0, 8, true, false), nil
			}
			return nil, &rpcError{Code: -32601, Message: "nope"}
		},
	})
	c := testClient(t, s)
	cache := NewCache(time.Second, time.Second)
	root := newVFSRoot(c, cache, false)

	h := &fileHandle{root: root, path: "/log.txt"}
	if _, errno := h.Write(nil, []byte("WORLD"), 0); errno != 0 {
		t.Fatalf("Write: %v", errno)
	}
	if _, errno := h.Write(nil, []byte("!"), 5); errno != 0 {
		t.Fatalf("Write2: %v", errno)
	}
	if errno := h.Flush(nil); errno != 0 {
		t.Fatalf("Flush: %v", errno)
	}
	if writePath != "/log.txt" {
		t.Fatalf("wrote to %q", writePath)
	}
	if written != "WORLD!" {
		t.Fatalf("read-modify-write splice wrong: %q", written)
	}
	// A second Flush must be a no-op (nothing new buffered).
	written = ""
	if errno := h.Flush(nil); errno != 0 || written != "" {
		t.Fatalf("double flush re-wrote: %q %v", written, errno)
	}
}

func TestTruncateFlushSkipsRead(t *testing.T) {
	readCalled := false
	var written string
	s := startFakeServer(t, &fakeServer{
		apiKey: "k",
		handler: func(method string, params map[string]any) (any, *rpcError) {
			switch method {
			case "vfs/stat":
				return nodeMap("file", 6, 0, 7, true, false), nil
			case "vfs/read":
				readCalled = true
				return map[string]any{"content": "hello\n", "version": 7}, nil
			case "vfs/write":
				written, _ = params["data"].(string)
				return nodeMap("file", int64(len(written)), 0, 9, true, false), nil
			}
			return nil, &rpcError{Code: -32601, Message: "nope"}
		},
	})
	c := testClient(t, s)
	root := newVFSRoot(c, NewCache(time.Second, time.Second), false)
	h := &fileHandle{root: root, path: "/log.txt", startTrunc: true}
	if _, errno := h.Write(nil, []byte("only this"), 0); errno != 0 {
		t.Fatalf("Write: %v", errno)
	}
	if errno := h.Flush(nil); errno != 0 {
		t.Fatalf("Flush: %v", errno)
	}
	if readCalled {
		t.Fatal("truncating flush must not read old content")
	}
	if written != "only this" {
		t.Fatalf("truncate content wrong: %q", written)
	}
}

func TestWriteConflictSurfacesEACCES(t *testing.T) {
	s := startFakeServer(t, &fakeServer{
		apiKey: "k",
		handler: func(method string, params map[string]any) (any, *rpcError) {
			switch method {
			case "vfs/stat":
				return nodeMap("file", 1, 0, 7, true, false), nil
			case "vfs/read":
				return map[string]any{"content": "x", "version": 7}, nil
			case "vfs/write":
				return nil, &rpcError{Code: codeAccess, Message: "stale", Data: map[string]any{"errno_atom": "eacces"}}
			}
			return nil, &rpcError{Code: -32601, Message: "nope"}
		},
	})
	c := testClient(t, s)
	root := newVFSRoot(c, NewCache(time.Second, time.Second), false)
	h := &fileHandle{root: root, path: "/conflict.txt"}
	if _, errno := h.Write(nil, []byte("y"), 0); errno != 0 {
		t.Fatalf("Write: %v", errno)
	}
	if errno := h.Flush(nil); errno != syscall.EACCES {
		t.Fatalf("want EACCES on conflict, got %v", errno)
	}
}

func TestRootExposesAndDelegatesDirectoryOperations(t *testing.T) {
	s := startFakeServer(t, &fakeServer{apiKey: "k"})
	root := newVFSRoot(testClient(t, s), NewCache(time.Second, time.Second), false)
	_ = fs.NewNodeFS(root, &fs.Options{})

	if _, ok := any(root).(fs.NodeLookuper); !ok {
		t.Fatal("root must expose NodeLookuper")
	}
	if _, ok := any(root).(fs.NodeReaddirer); !ok {
		t.Fatal("root must expose NodeReaddirer")
	}

	stream, errno := root.Readdir(nil)
	if errno != 0 {
		t.Fatalf("root Readdir: %v", errno)
	}
	defer stream.Close()
	if !stream.HasNext() {
		t.Fatal("root Readdir returned an empty static tree")
	}
	entry, errno := stream.Next()
	if errno != 0 || entry.Name != "hello.txt" {
		t.Fatalf("root Readdir entry = %+v, %v", entry, errno)
	}

	var out fuse.EntryOut
	child, errno := root.Lookup(nil, "hello.txt", &out)
	if errno != 0 || child == nil || out.Attr.Size != 6 {
		t.Fatalf("root Lookup child=%v size=%d errno=%v", child, out.Attr.Size, errno)
	}
}

func TestWritesAfterFsyncAreNotDropped(t *testing.T) {
	content := "abcdef"
	writes := 0
	s := startFakeServer(t, &fakeServer{
		apiKey: "k",
		handler: func(method string, params map[string]any) (any, *rpcError) {
			switch method {
			case "vfs/stat":
				return nodeMap("file", int64(len(content)), 0, int64(writes+1), true, false), nil
			case "vfs/read":
				return map[string]any{"content": content, "version": writes + 1}, nil
			case "vfs/write":
				content, _ = params["data"].(string)
				writes++
				return nodeMap("file", int64(len(content)), 0, int64(writes+1), true, false), nil
			}
			return nil, &rpcError{Code: -32601, Message: "nope"}
		},
	})
	h := &fileHandle{root: newVFSRoot(testClient(t, s), NewCache(time.Second, time.Second), false), path: "/f"}

	h.Write(nil, []byte("X"), 0)
	if errno := h.Fsync(nil, 0); errno != 0 {
		t.Fatalf("first fsync: %v", errno)
	}
	h.Write(nil, []byte("Y"), 1)
	if errno := h.Release(nil); errno != 0 {
		t.Fatalf("release after second write: %v", errno)
	}
	if content != "XYcdef" || writes != 2 {
		t.Fatalf("content=%q writes=%d; second write was lost", content, writes)
	}
}

func TestConcurrentWritesOnOneHandleAreSerialized(t *testing.T) {
	var written string
	s := startFakeServer(t, &fakeServer{
		apiKey: "k",
		handler: func(method string, params map[string]any) (any, *rpcError) {
			if method == "vfs/write" {
				written, _ = params["data"].(string)
				return nodeMap("file", int64(len(written)), 0, 1, true, false), nil
			}
			return nil, &rpcError{Code: -32601, Message: "nope"}
		},
	})
	h := &fileHandle{
		root:       newVFSRoot(testClient(t, s), NewCache(time.Second, time.Second), false),
		path:       "/f",
		startTrunc: true,
	}

	const count = 32
	var wg sync.WaitGroup
	for i := 0; i < count; i++ {
		wg.Add(1)
		go func(offset int) {
			defer wg.Done()
			if _, errno := h.Write(nil, []byte{byte(offset)}, int64(offset)); errno != 0 {
				t.Errorf("write %d: %v", offset, errno)
			}
		}(i)
	}
	wg.Wait()
	if errno := h.Flush(nil); errno != 0 {
		t.Fatalf("flush: %v", errno)
	}
	if len(written) != count {
		t.Fatalf("written length = %d", len(written))
	}
	for i := 0; i < count; i++ {
		if written[i] != byte(i) {
			t.Fatalf("written[%d] = %d", i, written[i])
		}
	}
}

func TestOverlappingWritesPreserveCallOrder(t *testing.T) {
	got, errno := applyFileOps([]byte("0000"), []fileOp{
		{kind: opWrite, off: 1, data: []byte("abc")},
		{kind: opWrite, off: 2, data: []byte("Z")},
	}, defaultMaxFileSize)
	if errno != 0 || string(got) != "0aZc" {
		t.Fatalf("got %q errno=%v", got, errno)
	}
}

func TestOpenTruncateWithoutWriteFlushesEmptyContent(t *testing.T) {
	content := "not empty"
	s := startFakeServer(t, &fakeServer{
		apiKey: "k",
		handler: func(method string, params map[string]any) (any, *rpcError) {
			switch method {
			case "vfs/stat":
				return nodeMap("file", int64(len(content)), 0, 1, true, false), nil
			case "vfs/write":
				content, _ = params["data"].(string)
				return nodeMap("file", int64(len(content)), 0, 2, true, false), nil
			}
			return nil, &rpcError{Code: -32601, Message: "nope"}
		},
	})
	node := &vfsNode{root: newVFSRoot(testClient(t, s), NewCache(time.Second, time.Second), false), path: "/f"}
	fh, _, errno := node.Open(nil, uint32(syscall.O_WRONLY|syscall.O_TRUNC))
	if errno != 0 {
		t.Fatalf("open truncate: %v", errno)
	}
	if errno := fh.(*fileHandle).Release(nil); errno != 0 {
		t.Fatalf("release truncate: %v", errno)
	}
	if content != "" {
		t.Fatalf("O_TRUNC without writes left %q", content)
	}
}

func TestOpenTruncateStillEnforcesMountAndNodePermissions(t *testing.T) {
	writes := 0
	s := startFakeServer(t, &fakeServer{
		apiKey: "k",
		handler: func(method string, params map[string]any) (any, *rpcError) {
			switch method {
			case "vfs/stat":
				writable := params["path"] != "/locked"
				return nodeMap("file", 1, 0, 1, writable, false), nil
			case "vfs/write":
				writes++
				return nodeMap("file", 0, 0, 2, true, false), nil
			}
			return nil, &rpcError{Code: -32601, Message: "nope"}
		},
	})
	client := testClient(t, s)
	flags := uint32(syscall.O_RDONLY | syscall.O_TRUNC)

	roNode := &vfsNode{root: newVFSRoot(client, NewCache(time.Second, time.Second), true), path: "/f"}
	if _, _, errno := roNode.Open(nil, flags); errno != syscall.EROFS {
		t.Fatalf("read-only O_TRUNC returned %v", errno)
	}
	locked := &vfsNode{root: newVFSRoot(client, NewCache(time.Second, time.Second), false), path: "/locked"}
	if _, _, errno := locked.Open(nil, flags); errno != syscall.EACCES {
		t.Fatalf("non-writable O_TRUNC returned %v", errno)
	}
	if writes != 0 {
		t.Fatalf("permission failures issued %d write RPCs", writes)
	}
	direct := &fileHandle{root: roNode.root, path: "/f", startTrunc: true, dirty: true}
	if errno := direct.Flush(nil); errno != syscall.EROFS {
		t.Fatalf("defensive read-only Flush returned %v", errno)
	}
}

func TestOversizedWriteAndTruncateFailWithoutAllocation(t *testing.T) {
	root := &vfsRoot{maxFileSize: 4}
	h := &fileHandle{root: root, path: "/f"}
	if _, errno := h.Write(nil, []byte("x"), 4); errno != syscall.EFBIG {
		t.Fatalf("oversized offset write returned %v", errno)
	}
	if _, errno := resizeContent(nil, 5, root.maxFileSize); errno != syscall.EFBIG {
		t.Fatalf("oversized truncate returned %v", errno)
	}
	if _, errno := applyFileOps([]byte("oversized"), []fileOp{{kind: opWrite, off: 0, data: []byte("x")}}, 4); errno != syscall.EFBIG {
		t.Fatalf("write against oversized base returned %v", errno)
	}
	got, errno := applyFileOps([]byte("oversized"), []fileOp{
		{kind: opTruncate, size: 4},
		{kind: opWrite, off: 0, data: []byte("x")},
	}, 4)
	if errno != 0 || string(got) != "xver" {
		t.Fatalf("truncate-then-write got %q errno=%v", got, errno)
	}
}

func TestPathSetattrTruncatesAndRejectsUnsupportedMetadata(t *testing.T) {
	content := "hello"
	s := startFakeServer(t, &fakeServer{
		apiKey: "k",
		handler: func(method string, params map[string]any) (any, *rpcError) {
			switch method {
			case "vfs/stat":
				return nodeMap("file", int64(len(content)), 0, 1, true, false), nil
			case "vfs/read":
				return map[string]any{"content": content, "version": 1}, nil
			case "vfs/write":
				content, _ = params["data"].(string)
				return nodeMap("file", int64(len(content)), 0, 2, true, false), nil
			}
			return nil, &rpcError{Code: -32601, Message: "nope"}
		},
	})
	node := &vfsNode{root: newVFSRoot(testClient(t, s), NewCache(time.Second, time.Second), false), path: "/f"}
	var out fuse.AttrOut
	truncate := &fuse.SetAttrIn{SetAttrInCommon: fuse.SetAttrInCommon{Valid: fuse.FATTR_SIZE, Size: 2}}
	if errno := node.Setattr(nil, nil, truncate, &out); errno != 0 {
		t.Fatalf("path truncate: %v", errno)
	}
	if content != "he" || out.Attr.Size != 2 {
		t.Fatalf("content=%q attr.size=%d", content, out.Attr.Size)
	}
	h := &fileHandle{root: node.root, path: node.path}
	grow := &fuse.SetAttrIn{SetAttrInCommon: fuse.SetAttrInCommon{Valid: fuse.FATTR_SIZE, Size: 4}}
	if errno := node.Setattr(nil, h, grow, &out); errno != 0 {
		t.Fatalf("handle truncate: %v", errno)
	}
	if content != "he\x00\x00" || out.Attr.Size != 4 {
		t.Fatalf("grown content=%q attr.size=%d", content, out.Attr.Size)
	}
	node.root.maxFileSize = 4
	tooLarge := &fuse.SetAttrIn{SetAttrInCommon: fuse.SetAttrInCommon{Valid: fuse.FATTR_SIZE, Size: 5}}
	if errno := node.Setattr(nil, h, tooLarge, &out); errno != syscall.EFBIG {
		t.Fatalf("oversized handle truncate returned %v", errno)
	}
	valid := &fuse.SetAttrIn{SetAttrInCommon: fuse.SetAttrInCommon{Valid: fuse.FATTR_SIZE, Size: 1}}
	if errno := node.Setattr(nil, h, valid, &out); errno != 0 {
		t.Fatalf("valid truncate after rejected oversize: %v", errno)
	}
	if content != "h" {
		t.Fatalf("rejected truncate poisoned handle; content=%q", content)
	}
	chmod := &fuse.SetAttrIn{SetAttrInCommon: fuse.SetAttrInCommon{Valid: fuse.FATTR_MODE}}
	if errno := node.Setattr(nil, nil, chmod, &out); errno != syscall.EOPNOTSUPP {
		t.Fatalf("unsupported setattr returned %v", errno)
	}
}

func TestCreateInvalidatesContainingDirectoryListing(t *testing.T) {
	s := startFakeServer(t, &fakeServer{
		apiKey: "k",
		handler: func(method string, params map[string]any) (any, *rpcError) {
			if method == "vfs/create" {
				return nodeMap("file", 0, 0, 1, true, false), nil
			}
			return nil, &rpcError{Code: -32601, Message: "nope"}
		},
	})
	cache := NewCache(time.Second, time.Minute)
	cache.PutDentries("/dir", []Entry{{Name: "old", Type: "file"}})
	root := newVFSRoot(testClient(t, s), cache, false)
	_ = fs.NewNodeFS(root, &fs.Options{})
	node := &vfsNode{root: root, path: "/dir"}
	var out fuse.EntryOut
	if _, _, _, errno := node.Create(nil, "new", uint32(syscall.O_WRONLY), 0o644, &out); errno != 0 {
		t.Fatalf("create: %v", errno)
	}
	if _, ok := cache.GetDentries("/dir"); ok {
		t.Fatal("create retained stale containing-directory listing")
	}
}
