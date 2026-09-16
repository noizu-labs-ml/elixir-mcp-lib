//go:build unix

// Package main implements mcp-fuse: a FUSE daemon that mounts a remote
// MCP VFS (served over the unix-socket JSON-RPC transport described in
// lib/noizu/mcp/transport/vfs_client.ex) as a local filesystem.
package main

import (
	"fmt"
	"os"
	"os/signal"
	"syscall"

	"github.com/hanwen/go-fuse/v2/fs"
	"github.com/hanwen/go-fuse/v2/fuse"
)

func main() {
	opt := parseFuseOpts()

	client := NewClient(opt.sockPath, opt.apiKey, opt.rpcTimeout, opt.debug)
	if errno := client.Ensure(); errno != 0 {
		fmt.Fprintf(os.Stderr, "mcp-fuse: connect/auth to %s failed: %v\n", opt.sockPath, errno)
		os.Exit(1)
	}

	cache := NewCache(opt.attrTTL, opt.entryTTL)
	root := newVFSRoot(client, cache, opt.ro)
	root.maxFileSize = opt.maxFile
	rawFS := fs.NewNodeFS(root, &fs.Options{
		EntryTimeout: &opt.entryTTL,
		AttrTimeout:  &opt.attrTTL,
	})

	mountOpts := &fuse.MountOptions{
		FsName:  "mcp-fuse",
		Debug:   opt.debug,
		Options: []string{},
	}
	if opt.ro {
		mountOpts.Options = append(mountOpts.Options, "ro")
	}
	srv, err := fuse.NewServer(rawFS, opt.mount, mountOpts)
	if err != nil {
		fmt.Fprintf(os.Stderr, "mcp-fuse: mount %s failed: %v\n", opt.mount, err)
		os.Exit(1)
	}

	sig := make(chan os.Signal, 1)
	signal.Notify(sig, syscall.SIGINT, syscall.SIGTERM)
	go func() {
		s := <-sig
		if opt.debug {
			fmt.Fprintf(os.Stderr, "mcp-fuse: %v, unmounting %s\n", s, opt.mount)
		}
		srv.Unmount()
	}()

	go srv.Serve()
	if err := srv.WaitMount(); err != nil {
		fmt.Fprintf(os.Stderr, "mcp-fuse: mount %s did not become ready: %v\n", opt.mount, err)
		os.Exit(1)
	}
	if opt.debug {
		fmt.Fprintf(os.Stderr, "mcp-fuse: mounted %s (%s)\n", opt.mount, opt.sockPath)
	}
	srv.Wait()
}
