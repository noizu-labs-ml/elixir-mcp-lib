//go:build linux

package main

import (
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/hanwen/go-fuse/v2/fs"
	"github.com/hanwen/go-fuse/v2/fuse"
)

// TestMountedRootIntegration crosses the kernel FUSE boundary. It is opt-in
// because developer machines and hosted CI runners do not always expose
// /dev/fuse; the workflow runs it whenever that device is available.
func TestMountedRootIntegration(t *testing.T) {
	if os.Getenv("MCP_FUSE_MOUNT_TEST") != "1" {
		t.Skip("set MCP_FUSE_MOUNT_TEST=1 to run the kernel-mount smoke")
	}
	if info, err := os.Stat("/dev/fuse"); err != nil || info.Mode()&os.ModeDevice == 0 {
		t.Skip("/dev/fuse is unavailable")
	}

	s := startFakeServer(t, &fakeServer{apiKey: "k"})
	root := newVFSRoot(testClient(t, s), NewCache(time.Second, time.Second), true)
	rawFS := fs.NewNodeFS(root, &fs.Options{})
	mountpoint := t.TempDir()
	server, err := fuse.NewServer(rawFS, mountpoint, &fuse.MountOptions{FsName: "mcp-fuse-test"})
	if err != nil {
		t.Fatalf("mount: %v", err)
	}
	go server.Serve()
	t.Cleanup(func() { _ = server.Unmount() })
	if err := server.WaitMount(); err != nil {
		t.Fatalf("wait mount: %v", err)
	}

	entries, err := os.ReadDir(mountpoint)
	if err != nil {
		t.Fatalf("read mounted root: %v", err)
	}
	if len(entries) != 1 || entries[0].Name() != "hello.txt" {
		t.Fatalf("mounted root entries: %+v", entries)
	}
	content, err := os.ReadFile(filepath.Join(mountpoint, "hello.txt"))
	if err != nil {
		t.Fatalf("read mounted file: %v", err)
	}
	if string(content) != "hello\n" {
		t.Fatalf("mounted file content = %q", content)
	}
}
