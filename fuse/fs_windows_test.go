//go:build windows

package main

import (
	"encoding/binary"
	"encoding/json"
	"io"
	"net"
	"testing"
	"time"

	"github.com/winfsp/cgofuse/fuse"
)

// A framed RPC peer keeps adapter tests independent of WinFsp installation.
func windowsTestFS(t *testing.T) *winFS {
	t.Helper()
	clientConn, serverConn := net.Pipe()
	t.Cleanup(func() { clientConn.Close(); serverConn.Close() })
	go func() {
		content := "base"
		version := int64(1)
		for {
			var length [4]byte
			if _, err := io.ReadFull(serverConn, length[:]); err != nil {
				return
			}
			body := make([]byte, binary.BigEndian.Uint32(length[:]))
			if _, err := io.ReadFull(serverConn, body); err != nil {
				return
			}
			var req struct {
				ID     uint64         `json:"id"`
				Method string         `json:"method"`
				Params map[string]any `json:"params"`
			}
			if json.Unmarshal(body, &req) != nil {
				return
			}
			node := func() Node {
				return Node{Type: "file", Size: int64(len(content)), Version: version, Writable: req.Params["path"] != "/locked"}
			}
			var result any
			switch req.Method {
			case "vfs/stat":
				result = node()
			case "vfs/read":
				result = ReadResult{Content: content, Version: version}
			case "vfs/write":
				content = req.Params["data"].(string)
				version++
				result = node()
			case "vfs/list":
				result = map[string]any{"entries": []Entry{{Name: "locked", Type: "file", Size: int64(len(content))}}}
			default:
				return
			}
			reply, _ := json.Marshal(map[string]any{"jsonrpc": "2.0", "id": req.ID, "result": result})
			binary.BigEndian.PutUint32(length[:], uint32(len(reply)))
			if _, err := serverConn.Write(append(length[:], reply...)); err != nil {
				return
			}
		}
	}()
	client := NewClient("", "", time.Second, false)
	client.conn = clientConn
	return newWinFS(client, NewCache(time.Minute, time.Minute), false, 1024)
}

func TestWindowsAppendPublishesSizeAndContentAcrossHandles(t *testing.T) {
	fs := windowsTestFS(t)
	errc, writer := fs.Open("/file", fuse.O_RDWR)
	if errc != 0 {
		t.Fatal(errc)
	}
	errc, reader := fs.Open("/file", fuse.O_RDONLY)
	if errc != 0 {
		t.Fatal(errc)
	}
	for _, chunk := range []string{"one", "two"} {
		var st fuse.Stat_t
		if errc := fs.Getattr("/file", &st, writer); errc != 0 {
			t.Fatal(errc)
		}
		// WinFsp resolves each append's offset from Getattr, without Flush.
		if n := fs.Write("/file", []byte(chunk), st.Size, writer); n != len(chunk) {
			t.Fatal(n)
		}
	}
	var st fuse.Stat_t
	if errc := fs.Getattr("/file", &st, reader); errc != 0 || st.Size != 10 {
		t.Fatalf("stat: %d %+v", errc, st)
	}
	buf := make([]byte, 32)
	if n := fs.Read("/file", buf, 0, reader); n != 10 || string(buf[:n]) != "baseonetwo" {
		t.Fatalf("read: %d %q", n, buf)
	}
	if errc := fs.Truncate("/file", 2, writer); errc != 0 {
		t.Fatal(errc)
	}
	if errc := fs.Getattr("/file", &st, reader); errc != 0 || st.Size != 2 {
		t.Fatalf("truncate stat: %d %+v", errc, st)
	}
	if n := fs.Read("/file", buf, 0, reader); n != 2 || string(buf[:n]) != "ba" {
		t.Fatalf("truncate read: %d %q", n, buf)
	}
}

func TestWindowsOpenTruncateVisibleBeforeClose(t *testing.T) {
	fs := windowsTestFS(t)
	errc, fh := fs.Open("/file", fuse.O_WRONLY|fuse.O_TRUNC)
	if errc != 0 {
		t.Fatal(errc)
	}
	var st fuse.Stat_t
	if errc := fs.Getattr("/file", &st, fh); errc != 0 || st.Size != 0 {
		t.Fatalf("stat: %d %+v", errc, st)
	}
}

func TestWindowsReaddirPreservesReadOnlyMode(t *testing.T) {
	fs := windowsTestFS(t)
	found := false
	errc := fs.Readdir("/", func(name string, st *fuse.Stat_t, off int64) bool {
		if name == "locked" {
			found = true
			if st == nil || st.Mode&0222 != 0 {
				t.Errorf("read-only entry: %+v", st)
			}
		}
		return true
	}, 0, 0)
	if errc != 0 || !found {
		t.Fatalf("readdir: %d found=%v", errc, found)
	}
}

func TestWindowsRejectedMutationsLeaveContentUnchanged(t *testing.T) {
	fs := windowsTestFS(t)
	errc, reader := fs.Open("/file", fuse.O_RDONLY)
	if errc != 0 {
		t.Fatal(errc)
	}
	if got := fs.Write("/file", []byte("bad"), 0, reader); got != -fuse.EBADF {
		t.Fatalf("read-only write: %d", got)
	}
	if got := fs.Truncate("/file", 0, reader); got != -fuse.EBADF {
		t.Fatalf("read-only truncate: %d", got)
	}
	errc, writer := fs.Open("/file", fuse.O_RDWR)
	if errc != 0 {
		t.Fatal(errc)
	}
	if got := fs.Write("/file", []byte("bad"), 1024, writer); got != -fuse.EFBIG {
		t.Fatalf("oversized write: %d", got)
	}
	if got := fs.Truncate("/file", 1025, writer); got != -fuse.EFBIG {
		t.Fatalf("oversized truncate: %d", got)
	}
	fs.Flush("/file", writer)
	fs.Release("/file", writer)
	buf := make([]byte, 32)
	if n := fs.Read("/file", buf, 0, reader); n != 4 || string(buf[:n]) != "base" {
		t.Fatalf("rejected mutation changed content: %d %q", n, buf)
	}
}
