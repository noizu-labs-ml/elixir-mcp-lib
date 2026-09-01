package main

import (
	"encoding/binary"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"os"
	"sync"
	"syscall"
	"time"
)

// JSON-RPC error codes used by the VFS transport (see the VFSClient
// moduledoc in the Elixir library for the canonical contract).
const (
	codeAuthFailed = -32001
	codeNotFound   = -32002
	codeAccess     = -32040
	codeExists     = -32041
	codeReadOnly   = -32042
	codeIsDir      = -32043
	codeNotDir     = -32044
	codeNotEmpty   = -32045
	codeNoSys      = -32046
)

const maxFrameSize = 64 << 20

// Node mirrors the wire map returned by vfs/stat, vfs/write, vfs/create.
type Node struct {
	Type       string `json:"type"` // "dir" | "file" | "control"
	Size       int64  `json:"size"`
	Mtime      int64  `json:"mtime"` // unix milliseconds
	Version    int64  `json:"version"`
	Writable   bool   `json:"writable"`
	Executable bool   `json:"executable"`
}

// Entry mirrors one element of vfs/list's "entries" array.
type Entry struct {
	Name    string `json:"name"`
	Type    string `json:"type"`
	Size    int64  `json:"size"`
	Mtime   int64  `json:"mtime"`
	Version int64  `json:"version"`
}

// ReadResult is the vfs/read response body. Content is a JSON string on
// the wire (the Elixir side sends the raw binary), not base64, so it is
// decoded as a string and converted.
type ReadResult struct {
	Content string `json:"content"`
	Version int64  `json:"version"`
}

type rpcError struct {
	Code    int            `json:"code"`
	Message string         `json:"message"`
	Data    map[string]any `json:"data"`
}

type rpcResponse struct {
	JSONRPC string          `json:"jsonrpc"`
	ID      uint64          `json:"id"`
	Result  json.RawMessage `json:"result"`
	Error   *rpcError       `json:"error"`
}

// Client is a mutex-serialized JSON-RPC client for one VFS unix socket.
// It handles the vfs/auth handshake, framing, reconnect-with-backoff and
// errno translation. A timeout maps to ESTALE; transport failures are
// retried once on a fresh connection before surfacing EIO.
type Client struct {
	mu      sync.Mutex
	sock    string
	apiKey  string
	timeout time.Duration
	debug   bool

	conn   net.Conn
	nextID uint64
}

func NewClient(sock, apiKey string, timeout time.Duration, debug bool) *Client {
	return &Client{sock: sock, apiKey: apiKey, timeout: timeout, debug: debug}
}

// Ensure dials and authenticates if needed; used to fail fast before mount.
func (c *Client) Ensure() syscall.Errno {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.conn != nil {
		return 0
	}
	if errno := c.dial(); errno != 0 {
		return errno
	}
	return 0
}

func (c *Client) logf(format string, args ...any) {
	if c.debug {
		fmt.Fprintf(os.Stderr, "mcp-fuse rpc: "+format+"\n", args...)
	}
}

// Call performs one RPC. method + params in, decoded result into out
// (may be nil). Returns 0 on success or a syscall.Errno.
func (c *Client) Call(method string, params map[string]any, out any) syscall.Errno {
	c.mu.Lock()
	defer c.mu.Unlock()

	for attempt := 0; ; attempt++ {
		if c.conn == nil {
			if errno := c.dial(); errno != 0 {
				return errno
			}
		}
		resp, errno := c.roundTrip(method, params)
		switch {
		case errno == 0:
			if resp.Error != nil {
				return errnoFromRPC(resp.Error)
			}
			if out != nil && len(resp.Result) > 0 {
				if err := json.Unmarshal(resp.Result, out); err != nil {
					c.logf("%s: bad result payload: %v", method, err)
					return syscall.EIO
				}
			}
			return 0
		case errno == syscall.ESTALE:
			// Timeout: surface immediately so callers see the stall.
			return errno
		default:
			// Transport-level failure: drop the connection and retry
			// once on a fresh one before giving up.
			c.closeConn()
			if attempt > 0 {
				return errno
			}
			c.logf("%s: transport error (%v), reconnecting", method, errno)
			time.Sleep(100 * time.Millisecond)
		}
	}
}

// dial establishes the connection and runs the vfs/auth handshake.
// Caller holds c.mu.
func (c *Client) dial() syscall.Errno {
	var lastErrno syscall.Errno
	for attempt := 0; attempt < 3; attempt++ {
		if attempt > 0 {
			time.Sleep(time.Duration(attempt) * 200 * time.Millisecond)
		}
		conn, err := net.DialTimeout("unix", c.sock, c.timeout)
		if err != nil {
			lastErrno = errnoFromTransport(err)
			continue
		}
		c.conn = conn
		c.nextID = 0
		if errno := c.auth(); errno != 0 {
			c.closeConn()
			return errno // auth failures are fatal, not retryable
		}
		c.logf("connected to %s", c.sock)
		return 0
	}
	return lastErrno
}

func (c *Client) auth() syscall.Errno {
	resp, errno := c.roundTrip("vfs/auth", map[string]any{"api_key": c.apiKey})
	if errno != 0 {
		return syscall.EACCES
	}
	if resp.Error != nil {
		return errnoFromRPC(resp.Error)
	}
	var ok struct {
		Authenticated bool   `json:"authenticated"`
		SessionID     string `json:"session_id"`
	}
	if err := json.Unmarshal(resp.Result, &ok); err != nil || !ok.Authenticated {
		return syscall.EACCES
	}
	return 0
}

// roundTrip sends one framed request and awaits the matching response.
// Caller holds c.mu.
func (c *Client) roundTrip(method string, params map[string]any) (*rpcResponse, syscall.Errno) {
	c.nextID++
	id := c.nextID

	req := struct {
		JSONRPC string         `json:"jsonrpc"`
		ID      uint64         `json:"id"`
		Method  string         `json:"method"`
		Params  map[string]any `json:"params"`
	}{"2.0", id, method, params}
	body, err := json.Marshal(req)
	if err != nil {
		return nil, syscall.EIO
	}

	frame := make([]byte, 4+len(body))
	binary.BigEndian.PutUint32(frame, uint32(len(body)))
	copy(frame[4:], body)

	c.conn.SetDeadline(time.Now().Add(c.timeout))
	if _, err := c.conn.Write(frame); err != nil {
		return nil, errnoFromTransport(err)
	}

	// Read frames until the response to our id arrives; skip anything else
	// so a noisy server cannot desync the caller.
	for {
		resp, errno := c.readFrame()
		if errno != 0 {
			return nil, errno
		}
		if resp.ID == id {
			return resp, 0
		}
		c.logf("skipping frame with id %d (want %d)", resp.ID, id)
	}
}

func (c *Client) readFrame() (*rpcResponse, syscall.Errno) {
	var lenBuf [4]byte
	if _, err := io.ReadFull(c.conn, lenBuf[:]); err != nil {
		return nil, errnoFromTransport(err)
	}
	size := binary.BigEndian.Uint32(lenBuf[:])
	if size == 0 || size > maxFrameSize {
		return nil, syscall.EIO
	}
	buf := make([]byte, size)
	if _, err := io.ReadFull(c.conn, buf); err != nil {
		return nil, errnoFromTransport(err)
	}
	var resp rpcResponse
	if err := json.Unmarshal(buf, &resp); err != nil {
		return nil, syscall.EIO
	}
	return &resp, 0
}

func (c *Client) closeConn() {
	if c.conn != nil {
		c.conn.Close()
		c.conn = nil
	}
}

// Close tears the connection down (used by tests).
func (c *Client) Close() {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.closeConn()
}

// ── typed VFS operations ──────────────────────────────────────────────────

func (c *Client) Stat(path string) (*Node, syscall.Errno) {
	var node Node
	if errno := c.Call("vfs/stat", map[string]any{"path": path}, &node); errno != 0 {
		return nil, errno
	}
	return &node, 0
}

func (c *Client) List(path, cursor string) ([]Entry, string, syscall.Errno) {
	params := map[string]any{"path": path}
	if cursor != "" {
		params["cursor"] = cursor
	}
	var out struct {
		Entries    []Entry `json:"entries"`
		NextCursor string  `json:"nextCursor"`
	}
	if errno := c.Call("vfs/list", params, &out); errno != 0 {
		return nil, "", errno
	}
	return out.Entries, out.NextCursor, 0
}

func (c *Client) Read(path string) ([]byte, int64, syscall.Errno) {
	var res ReadResult
	if errno := c.Call("vfs/read", map[string]any{"path": path}, &res); errno != 0 {
		return nil, 0, errno
	}
	return []byte(res.Content), res.Version, 0
}

func (c *Client) Write(path string, data []byte) (*Node, syscall.Errno) {
	var node Node
	params := map[string]any{"path": path, "data": string(data)}
	if errno := c.Call("vfs/write", params, &node); errno != 0 {
		return nil, errno
	}
	return &node, 0
}

func (c *Client) Create(path string, data []byte) (*Node, syscall.Errno) {
	var node Node
	params := map[string]any{"path": path, "data": string(data)}
	if errno := c.Call("vfs/create", params, &node); errno != 0 {
		return nil, errno
	}
	return &node, 0
}

func (c *Client) Remove(path string) syscall.Errno {
	return c.Call("vfs/remove", map[string]any{"path": path}, nil)
}

// ── errno translation ─────────────────────────────────────────────────────

var errnoByAtom = map[string]syscall.Errno{
	"enoent":    syscall.ENOENT,
	"eacces":    syscall.EACCES,
	"eperm":     syscall.EACCES,
	"eexist":    syscall.EEXIST,
	"erofs":     syscall.EROFS,
	"eisdir":    syscall.EISDIR,
	"enotdir":   syscall.ENOTDIR,
	"enotempty": syscall.ENOTEMPTY,
	"enosys":    syscall.ENOSYS,
	"enotsup":   syscall.EOPNOTSUPP,
	"eio":       syscall.EIO,
}

var errnoByCode = map[int]syscall.Errno{
	codeNotFound:   syscall.ENOENT,
	codeAccess:     syscall.EACCES,
	codeExists:     syscall.EEXIST,
	codeReadOnly:   syscall.EROFS,
	codeIsDir:      syscall.EISDIR,
	codeNotDir:     syscall.ENOTDIR,
	codeNotEmpty:   syscall.ENOTEMPTY,
	codeNoSys:      syscall.ENOSYS,
	codeAuthFailed: syscall.EACCES,
}

func errnoFromRPC(err *rpcError) syscall.Errno {
	if err == nil {
		return 0
	}
	if atom, ok := err.Data["errno_atom"].(string); ok {
		if errno, ok := errnoByAtom[atom]; ok {
			return errno
		}
	}
	if errno, ok := errnoByCode[err.Code]; ok {
		return errno
	}
	return syscall.EIO
}

func errnoFromTransport(err error) syscall.Errno {
	if err == nil {
		return 0
	}
	if netErr, ok := err.(net.Error); ok && netErr.Timeout() {
		return syscall.ESTALE
	}
	if err == io.EOF || err == io.ErrUnexpectedEOF {
		return syscall.ECONNRESET
	}
	var se syscall.Errno
	if errorsAs(err, &se) {
		return se
	}
	return syscall.EIO
}

// errorsAs avoids importing errors just for one unwrapping call site.
func errorsAs(err error, target *syscall.Errno) bool {
	for err != nil {
		if e, ok := err.(syscall.Errno); ok {
			*target = e
			return true
		}
		u, ok := err.(interface{ Unwrap() error })
		if !ok {
			return false
		}
		err = u.Unwrap()
	}
	return false
}
