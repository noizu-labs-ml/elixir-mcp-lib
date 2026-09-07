//go:build windows

package main

import (
	"fmt"
	"os"
	"os/signal"
	"syscall"

	"github.com/winfsp/cgofuse/fuse"
)

func main() {
	opt := parseFuseOpts()

	client := NewClient(opt.sockPath, opt.apiKey, opt.rpcTimeout, opt.debug)
	if errno := client.Ensure(); errno != 0 {
		fmt.Fprintf(os.Stderr, "mcp-fuse: connect/auth to %s failed: %v\n", opt.sockPath, errno)
		os.Exit(1)
	}

	cache := NewCache(opt.attrTTL, opt.entryTTL)
	wfs := newWinFS(client, cache, opt.ro, opt.maxFile)
	host := fuse.NewFileSystemHost(wfs)
	host.SetCapReaddirPlus(true)

	var fuseArgs []string
	if opt.ro {
		fuseArgs = append(fuseArgs, "-o", "ro")
	}
	if opt.debug {
		fuseArgs = append(fuseArgs, "-d")
	}

	sig := make(chan os.Signal, 1)
	signal.Notify(sig, os.Interrupt, syscall.SIGTERM)
	go func() {
		s := <-sig
		if opt.debug {
			fmt.Fprintf(os.Stderr, "mcp-fuse: %v, unmounting %s\n", s, opt.mount)
		}
		host.Unmount()
	}()

	if opt.debug {
		fmt.Fprintf(os.Stderr, "mcp-fuse: mounting %s (%s) via WinFsp\n", opt.mount, opt.sockPath)
	}

	defer func() {
		if r := recover(); r != nil {
			fmt.Fprintf(os.Stderr, "mcp-fuse: %v (install WinFsp from https://winfsp.dev/ and retry)\n", r)
			os.Exit(1)
		}
	}()
	if !host.Mount(opt.mount, fuseArgs) {
		fmt.Fprintf(os.Stderr, "mcp-fuse: mount %s failed (is WinFsp installed?)\n", opt.mount)
		os.Exit(1)
	}
}
