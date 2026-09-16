package main

import (
	"flag"
	"fmt"
	"os"
	"strings"
	"time"
)

const defaultRPCTimeout = 5 * time.Second

type fuseOpts struct {
	sockPath   string
	mount      string
	apiKey     string
	ro         bool
	attrTTL    time.Duration
	entryTTL   time.Duration
	rpcTimeout time.Duration
	maxFile    uint64
	debug      bool
}

func parseFuseOpts() fuseOpts {
	var (
		server     = flag.String("server", "", "VFS socket URL, unix:/path/to.sock (required; Windows 10+ AF_UNIX)")
		mount      = flag.String("mount", "", "mountpoint, e.g. /Volumes/mcp or X: (required)")
		apiKey     = flag.String("apikey", "", "API key (falls back to $MCP_VFS_TOKEN)")
		ro         = flag.Bool("ro", false, "read-only mount")
		attrTTL    = flag.Duration("cache-ttl-attr", time.Second, "attribute cache TTL")
		entryTTL   = flag.Duration("cache-ttl-entry", 2*time.Second, "directory-entry cache TTL")
		rpcTimeout = flag.Duration("rpc-timeout", defaultRPCTimeout, "per-request timeout")
		maxFile    = flag.Uint64("max-file-size", defaultMaxFileSize, "maximum buffered file size in bytes")
		debug      = flag.Bool("debug", false, "verbose FUSE + RPC logging")
	)
	flag.Parse()

	if *server == "" || *mount == "" {
		flag.Usage()
		os.Exit(2)
	}
	key := *apiKey
	if key == "" {
		key = os.Getenv("MCP_VFS_TOKEN")
	}
	if key == "" {
		fmt.Fprintln(os.Stderr, "mcp-fuse: no API key: pass --apikey or set MCP_VFS_TOKEN")
		os.Exit(2)
	}
	return fuseOpts{
		sockPath:   strings.TrimPrefix(*server, "unix:"),
		mount:      *mount,
		apiKey:     key,
		ro:         *ro,
		attrTTL:    *attrTTL,
		entryTTL:   *entryTTL,
		rpcTimeout: *rpcTimeout,
		maxFile:    *maxFile,
		debug:      *debug,
	}
}
