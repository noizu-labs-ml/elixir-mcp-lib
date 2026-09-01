// Package main implements mcp-fuse: a FUSE daemon that mounts a remote
// MCP VFS (served over the unix-socket JSON-RPC transport described in
// lib/noizu/mcp/transport/vfs_client.ex) as a local filesystem.
package main

import (
	"flag"
	"fmt"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"

	"github.com/hanwen/go-fuse/v2/fs"
	"github.com/hanwen/go-fuse/v2/fuse"
)

const defaultRPCTimeout = 5 * time.Second

func main() {
	var (
		server     = flag.String("server", "", "VFS socket URL, unix:/path/to.sock (required)")
		mount      = flag.String("mount", "", "mountpoint, e.g. /Volumes/mcp (required)")
		apiKey     = flag.String("apikey", "", "API key (falls back to $MCP_VFS_TOKEN)")
		ro         = flag.Bool("ro", false, "read-only mount")
		attrTTL    = flag.Duration("cache-ttl-attr", time.Second, "attribute cache TTL")
		entryTTL   = flag.Duration("cache-ttl-entry", 2*time.Second, "directory-entry cache TTL")
		rpcTimeout = flag.Duration("rpc-timeout", defaultRPCTimeout, "per-request timeout")
		debug      = flag.Bool("debug", false, "verbose FUSE + RPC logging")
	)
	flag.Parse()

	if *server == "" || *mount == "" {
		flag.Usage()
		os.Exit(2)
	}
	sockPath := strings.TrimPrefix(*server, "unix:")
	key := *apiKey
	if key == "" {
		key = os.Getenv("MCP_VFS_TOKEN")
	}
	if key == "" {
		fmt.Fprintln(os.Stderr, "mcp-fuse: no API key: pass --apikey or set MCP_VFS_TOKEN")
		os.Exit(2)
	}

	client := NewClient(sockPath, key, *rpcTimeout, *debug)
	if errno := client.Ensure(); errno != 0 {
		fmt.Fprintf(os.Stderr, "mcp-fuse: connect/auth to %s failed: %v\n", sockPath, errno)
		os.Exit(1)
	}

	cache := NewCache(*attrTTL, *entryTTL)
	root := newVFSRoot(client, cache, *ro)
	rawFS := fs.NewNodeFS(root, &fs.Options{
		EntryTimeout: entryTTL,
		AttrTimeout:  attrTTL,
	})

	mountOpts := &fuse.MountOptions{
		FsName:  "mcp-fuse",
		Debug:   *debug,
		Options: []string{},
	}
	if *ro {
		mountOpts.Options = append(mountOpts.Options, "ro")
	}
	srv, err := fuse.NewServer(rawFS, *mount, mountOpts)
	if err != nil {
		fmt.Fprintf(os.Stderr, "mcp-fuse: mount %s failed: %v\n", *mount, err)
		os.Exit(1)
	}

	sig := make(chan os.Signal, 1)
	signal.Notify(sig, syscall.SIGINT, syscall.SIGTERM)
	go func() {
		s := <-sig
		if *debug {
			fmt.Fprintf(os.Stderr, "mcp-fuse: %v, unmounting %s\n", s, *mount)
		}
		srv.Unmount()
	}()

	srv.WaitMount()
	if *debug {
		fmt.Fprintf(os.Stderr, "mcp-fuse: mounted %s (%s)\n", *mount, sockPath)
	}
	srv.Wait()
}
