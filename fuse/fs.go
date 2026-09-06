package main

import (
	"context"
	"sync"
	"syscall"

	"github.com/hanwen/go-fuse/v2/fs"
	"github.com/hanwen/go-fuse/v2/fuse"
)

/*
FS-type choice: go-fuse v2's path-style NodeFS (github.com/hanwen/go-fuse/v2/fs).

The VFS protocol is path-addressed — every RPC names a path string — so
nodefs's Lookup/Getattr/OpenDir calls map one-to-one onto vfs/stat, vfs/list,
vfs/read. RawFS would mean hand-managing inode tables with no upside, and
nodefs gives us kernel-side entry/attr timeout caching for free (we set them
from the same TTLs as the daemon-side cache).
*/

type vfsRoot struct {
	fs.Inode
	client      *Client
	cache       *Cache
	ro          bool
	maxFileSize uint64
}

const defaultMaxFileSize = 8 << 20

func newVFSRoot(client *Client, cache *Cache, ro bool) *vfsRoot {
	return &vfsRoot{client: client, cache: cache, ro: ro, maxFileSize: defaultMaxFileSize}
}

// go-fuse dispatches root operations against the exact InodeEmbedder passed to
// fs.NewNodeFS. Keep the root as the owner of shared state, but explicitly
// expose the directory operations that ordinary vfsNode values implement.
func (r *vfsRoot) rootNode() *vfsNode {
	return &vfsNode{root: r, path: "/"}
}

func (r *vfsRoot) Getattr(ctx context.Context, fh fs.FileHandle, out *fuse.AttrOut) syscall.Errno {
	return r.rootNode().Getattr(ctx, fh, out)
}

func (r *vfsRoot) Lookup(ctx context.Context, name string, out *fuse.EntryOut) (*fs.Inode, syscall.Errno) {
	return r.rootNode().Lookup(ctx, name, out)
}

func (r *vfsRoot) Readdir(ctx context.Context) (fs.DirStream, syscall.Errno) {
	return r.rootNode().Readdir(ctx)
}

func (r *vfsRoot) Create(ctx context.Context, name string, flags uint32, mode uint32, out *fuse.EntryOut) (*fs.Inode, fs.FileHandle, uint32, syscall.Errno) {
	return r.rootNode().Create(ctx, name, flags, mode, out)
}

func (r *vfsRoot) Unlink(ctx context.Context, name string) syscall.Errno {
	return r.rootNode().Unlink(ctx, name)
}

func (r *vfsRoot) Setattr(ctx context.Context, fh fs.FileHandle, in *fuse.SetAttrIn, out *fuse.AttrOut) syscall.Errno {
	return r.rootNode().Setattr(ctx, fh, in, out)
}

// childPath joins a directory path with a child name.
func childPath(dir, name string) string {
	if dir == "/" {
		return "/" + name
	}
	return dir + "/" + name
}

// statCached resolves a path to node metadata through the attr cache.
func (r *vfsRoot) statCached(path string) (*Node, syscall.Errno) {
	if node, ok := r.cache.GetAttr(path); ok {
		return node, 0
	}
	node, errno := r.client.Stat(path)
	if errno != 0 {
		return nil, errno
	}
	r.cache.PutAttr(path, node)
	return node, 0
}

func (r *vfsRoot) newNode(path string, node *Node) *fs.Inode {
	return r.NewInode(context.Background(), &vfsNode{
		root: r,
		path: path,
		node: node,
	}, fs.StableAttr{Mode: modeOf(node)})
}

// modeOf maps a VFS node to unix mode bits. The capability flags become the
// permission bits: writable → owner-write, executable → execute.
func modeOf(node *Node) uint32 {
	switch node.Type {
	case "dir":
		m := uint32(syscall.S_IFDIR | 0o555)
		if node.Writable {
			m |= 0o200
		}
		return m
	default:
		m := uint32(syscall.S_IFREG | 0o444)
		if node.Writable {
			m |= 0o200
		}
		if node.Executable {
			m |= 0o111
		}
		return m
	}
}

func attrFromNode(node *Node, out *fuse.Attr) {
	out.Ino = 0 // kernel assigns
	out.Size = uint64(node.Size)
	out.Mtime = uint64(node.Mtime / 1000)
	out.Mtimensec = uint32((node.Mtime % 1000) * 1_000_000)
	out.Ctime = out.Mtime
	out.Ctimensec = out.Mtimensec
	out.Mode = modeOf(node)
	out.Nlink = 1
	out.Blksize = 4096
	out.Blocks = (out.Size + 511) / 512
}

// ── vfsNode ───────────────────────────────────────────────────────────────

type vfsNode struct {
	fs.Inode
	root *vfsRoot
	path string
	node *Node
}

var (
	_ fs.NodeGetattrer = (*vfsRoot)(nil)
	_ fs.NodeLookuper  = (*vfsRoot)(nil)
	_ fs.NodeReaddirer = (*vfsRoot)(nil)
	_ fs.NodeCreater   = (*vfsRoot)(nil)
	_ fs.NodeUnlinker  = (*vfsRoot)(nil)
	_ fs.NodeSetattrer = (*vfsRoot)(nil)

	_ fs.NodeGetattrer = (*vfsNode)(nil)
	_ fs.NodeLookuper  = (*vfsNode)(nil)
	_ fs.NodeOpener    = (*vfsNode)(nil)
	_ fs.NodeReaddirer = (*vfsNode)(nil)
	_ fs.NodeCreater   = (*vfsNode)(nil)
	_ fs.NodeUnlinker  = (*vfsNode)(nil)
	_ fs.NodeSetattrer = (*vfsNode)(nil)
)

// Getattr reports node metadata (M3 read path).
func (n *vfsNode) Getattr(ctx context.Context, fh fs.FileHandle, out *fuse.AttrOut) syscall.Errno {
	node, errno := n.root.statCached(n.path)
	if errno != 0 {
		return errno
	}
	attrFromNode(node, &out.Attr)
	out.SetTimeout(n.root.cache.attrTTL)
	return 0
}

// Lookup resolves a child name; primes the attr cache for the entry.
func (n *vfsNode) Lookup(ctx context.Context, name string, out *fuse.EntryOut) (*fs.Inode, syscall.Errno) {
	child := childPath(n.path, name)
	node, errno := n.root.statCached(child)
	if errno != 0 {
		return nil, errno
	}
	attrFromNode(node, &out.Attr)
	out.SetEntryTimeout(n.root.cache.dentryTTL)
	out.SetAttrTimeout(n.root.cache.attrTTL)
	return n.root.newNode(child, node), 0
}

// Open checks write capability up front so `open(W)` on a read-only node
// fails with EACCES rather than at flush time.
func (n *vfsNode) Open(ctx context.Context, flags uint32) (fs.FileHandle, uint32, syscall.Errno) {
	accmode := flags & uint32(syscall.O_ACCMODE)
	truncate := flags&uint32(syscall.O_TRUNC) != 0
	if accmode == syscall.O_WRONLY || accmode == syscall.O_RDWR || truncate {
		if n.root.ro {
			return nil, 0, syscall.EROFS
		}
		node, errno := n.root.statCached(n.path)
		if errno != 0 {
			return nil, 0, errno
		}
		if !node.Writable {
			return nil, 0, syscall.EACCES
		}
	}
	h := &fileHandle{
		root:       n.root,
		path:       n.path,
		startTrunc: truncate,
		dirty:      truncate,
	}
	return h, 0, 0
}

// Readdir lists children, looping the server's pagination cursor until the
// directory is exhausted (M3 read path).
func (n *vfsNode) Readdir(ctx context.Context) (fs.DirStream, syscall.Errno) {
	entries, errno := n.listAll()
	if errno != 0 {
		return nil, errno
	}
	de := make([]fuse.DirEntry, 0, len(entries))
	for _, e := range entries {
		de = append(de, fuse.DirEntry{
			Name: e.Name,
			Mode: modeOf(&Node{Type: e.Type, Writable: true}),
		})
	}
	return fs.NewListDirStream(de), 0
}

// listAll gathers every page of vfs/list for this directory, consulting
// the dentry cache first.
func (n *vfsNode) listAll() ([]Entry, syscall.Errno) {
	if entries, ok := n.root.cache.GetDentries(n.path); ok {
		return entries, 0
	}
	var all []Entry
	cursor := ""
	for {
		page, next, errno := n.root.client.List(n.path, cursor)
		if errno != 0 {
			return nil, errno
		}
		all = append(all, page...)
		if next == "" {
			break
		}
		cursor = next
	}
	n.root.cache.PutDentries(n.path, all)
	return all, 0
}

// Create implements O_CREAT (M4 write path): vfs/create with empty data.
func (n *vfsNode) Create(ctx context.Context, name string, flags uint32, mode uint32, out *fuse.EntryOut) (*fs.Inode, fs.FileHandle, uint32, syscall.Errno) {
	if n.root.ro {
		return nil, nil, 0, syscall.EROFS
	}
	child := childPath(n.path, name)
	node, errno := n.root.client.Create(child, nil)
	if errno != 0 {
		return nil, nil, 0, errno
	}
	// Drop the containing directory's listing, then retain the fresh child
	// attributes returned by create.
	n.root.cache.Invalidate(child)
	n.root.cache.PutAttr(child, node)
	attrFromNode(node, &out.Attr)
	out.SetEntryTimeout(n.root.cache.dentryTTL)
	out.SetAttrTimeout(n.root.cache.attrTTL)
	inode := n.root.newNode(child, node)
	h := &fileHandle{
		root:       n.root,
		path:       child,
		startTrunc: true,
	}
	return inode, h, 0, 0
}

// Unlink deletes a child (M4 write path): vfs/remove.
func (n *vfsNode) Unlink(ctx context.Context, name string) syscall.Errno {
	if n.root.ro {
		return syscall.EROFS
	}
	child := childPath(n.path, name)
	if errno := n.root.client.Remove(child); errno != 0 {
		return errno
	}
	n.root.cache.Invalidate(child)
	return 0
}

// Setattr supports file-size changes. Metadata mutations that the VFS wire
// protocol cannot represent fail explicitly instead of reporting false
// success. FATTR_FH and FATTR_LOCKOWNER are request metadata, not mutations.
func (n *vfsNode) Setattr(ctx context.Context, fh fs.FileHandle, in *fuse.SetAttrIn, out *fuse.AttrOut) syscall.Errno {
	allowed := uint32(fuse.FATTR_SIZE | fuse.FATTR_FH | fuse.FATTR_LOCKOWNER | fuse.FATTR_KILL_SUIDGID)
	if in.Valid & ^allowed != 0 {
		return syscall.EOPNOTSUPP
	}
	if in.Valid&fuse.FATTR_SIZE == 0 {
		return n.Getattr(ctx, fh, out)
	}
	if n.root.ro {
		return syscall.EROFS
	}

	node, errno := n.root.statCached(n.path)
	if errno != 0 {
		return errno
	}
	if node.Type == "dir" {
		return syscall.EISDIR
	}
	if !node.Writable {
		return syscall.EACCES
	}

	if fh != nil {
		h, ok := fh.(*fileHandle)
		if !ok {
			return syscall.EBADF
		}
		if errno := h.Truncate(in.Size); errno != 0 {
			return errno
		}
		if errno := h.Flush(ctx); errno != 0 {
			return errno
		}
	} else if errno := n.root.truncatePath(n.path, in.Size); errno != 0 {
		return errno
	}

	return n.Getattr(ctx, fh, out)
}

// ── fileHandle ────────────────────────────────────────────────────────────

// fileHandle buffers writes locally (M4 write path) and splices them into
// the server's content on Flush/Release/Fsync: read-modify-write with
// last-writer-wins semantics.
type fileHandle struct {
	root *vfsRoot
	path string

	mu         sync.Mutex
	ops        []fileOp
	startTrunc bool // apply this batch to empty content (O_TRUNC / fresh create)
	dirty      bool // unflushed writes or truncation exist
	flushed    bool // latest dirty batch was flushed
}

type fileOp struct {
	kind uint8
	off  int64
	data []byte
	size uint64
}

const (
	opWrite uint8 = iota
	opTruncate
)

var (
	_ fs.FileReader   = (*fileHandle)(nil)
	_ fs.FileWriter   = (*fileHandle)(nil)
	_ fs.FileFlusher  = (*fileHandle)(nil)
	_ fs.FileReleaser = (*fileHandle)(nil)
	_ fs.FileFsyncer  = (*fileHandle)(nil)
)

// Read serves file content from the versioned content cache / server.
func (h *fileHandle) Read(ctx context.Context, dest []byte, off int64) (fuse.ReadResult, syscall.Errno) {
	if off < 0 {
		return nil, syscall.EINVAL
	}

	h.mu.Lock()
	defer h.mu.Unlock()

	data, errno := h.materializeLocked()
	if errno != 0 {
		return nil, errno
	}
	if off >= int64(len(data)) {
		return fuse.ReadResultData([]byte{}), 0
	}
	end := int64(len(data))
	if off+int64(len(dest)) < end {
		end = off + int64(len(dest))
	}
	return fuse.ReadResultData(data[off:end]), 0
}

func (r *vfsRoot) contentReader(path string) ([]byte, syscall.Errno) {
	node, errno := r.statCached(path)
	if errno != 0 {
		return nil, errno
	}
	if data, ok := r.cache.GetContent(path, node.Version); ok {
		return data, 0
	}
	data, version, errno := r.client.Read(path)
	if errno != 0 {
		return nil, errno
	}
	r.cache.PutContent(path, version, data)
	return data, 0
}

// Write buffers the write locally; nothing hits the wire until Flush.
func (h *fileHandle) Write(ctx context.Context, data []byte, off int64) (uint32, syscall.Errno) {
	if h.root.ro {
		return 0, syscall.EROFS
	}
	if off < 0 {
		return 0, syscall.EINVAL
	}
	if uint64(off) > h.root.maxFileSize || uint64(len(data)) > h.root.maxFileSize-uint64(off) {
		return 0, syscall.EFBIG
	}
	buf := make([]byte, len(data))
	copy(buf, data)
	h.mu.Lock()
	h.ops = append(h.ops, fileOp{kind: opWrite, off: off, data: buf})
	h.dirty = true
	h.flushed = false
	h.mu.Unlock()
	return uint32(len(data)), 0
}

// Truncate queues a size change in call order with writes on this handle.
func (h *fileHandle) Truncate(size uint64) syscall.Errno {
	if size > h.root.maxFileSize {
		return syscall.EFBIG
	}
	h.mu.Lock()
	h.ops = append(h.ops, fileOp{kind: opTruncate, size: size})
	h.dirty = true
	h.flushed = false
	h.mu.Unlock()
	return 0
}

// Flush pushes buffered writes to the server: read current content (unless
// truncating), apply operations in call order, then vfs/write the full body.
func (h *fileHandle) Flush(ctx context.Context) syscall.Errno {
	h.mu.Lock()
	defer h.mu.Unlock()
	if !h.dirty || h.flushed {
		return 0
	}
	if h.root.ro {
		return syscall.EROFS
	}

	buf, errno := h.materializeLocked()
	if errno != 0 {
		return errno
	}

	node, errno := h.root.client.Write(h.path, buf)
	if errno != 0 {
		// Version conflict or server refusal: surface ESTALE/EACCES so the
		// caller knows its data did not land. Keep the buffer dirty so a
		// retry (e.g. fsync) can try again.
		if errno == syscall.ENOENT {
			return syscall.ESTALE
		}
		return errno
	}

	h.root.cache.PutAttr(h.path, node)
	h.root.cache.PutContent(h.path, node.Version, buf)
	h.ops = nil
	h.startTrunc = false
	h.dirty = false
	h.flushed = true
	return 0
}

func (h *fileHandle) materializeLocked() ([]byte, syscall.Errno) {
	if !h.dirty {
		return h.root.contentReader(h.path)
	}
	var base []byte
	if !h.startTrunc {
		data, errno := h.root.contentReader(h.path)
		if errno != 0 {
			return nil, errno
		}
		base = data
	}
	return applyFileOps(base, h.ops, h.root.maxFileSize)
}

func applyFileOps(base []byte, ops []fileOp, maxFileSize uint64) ([]byte, syscall.Errno) {
	var buf []byte
	start := 0
	if uint64(len(base)) > maxFileSize {
		// A pre-existing oversized file may only enter a write batch if its
		// first operation brings it under the configured ceiling. Do that
		// before copying the oversized base.
		if len(ops) == 0 || ops[0].kind != opTruncate {
			return nil, syscall.EFBIG
		}
		resized, errno := resizeContent(base, ops[0].size, maxFileSize)
		if errno != 0 {
			return nil, errno
		}
		buf = resized
		start = 1
	} else {
		buf = append([]byte(nil), base...)
	}

	for _, op := range ops[start:] {
		switch op.kind {
		case opTruncate:
			resized, errno := resizeContent(buf, op.size, maxFileSize)
			if errno != 0 {
				return nil, errno
			}
			buf = resized
		case opWrite:
			if uint64(len(buf)) > maxFileSize || op.off < 0 || uint64(op.off) > maxFileSize || uint64(len(op.data)) > maxFileSize-uint64(op.off) {
				return nil, syscall.EFBIG
			}
			end := int(op.off) + len(op.data)
			if end > len(buf) {
				grown := make([]byte, end)
				copy(grown, buf)
				buf = grown
			}
			copy(buf[int(op.off):end], op.data)
		default:
			return nil, syscall.EINVAL
		}
	}
	return buf, 0
}

const maxInt = int(^uint(0) >> 1)

func resizeContent(data []byte, size, maxFileSize uint64) ([]byte, syscall.Errno) {
	if size > maxFileSize || size > uint64(maxInt) {
		return nil, syscall.EFBIG
	}
	resized := make([]byte, int(size))
	copy(resized, data)
	return resized, 0
}

func (r *vfsRoot) truncatePath(path string, size uint64) syscall.Errno {
	data, errno := r.contentReader(path)
	if errno != 0 {
		return errno
	}
	resized, errno := resizeContent(data, size, r.maxFileSize)
	if errno != 0 {
		return errno
	}
	node, errno := r.client.Write(path, resized)
	if errno != 0 {
		return errno
	}
	r.cache.PutAttr(path, node)
	r.cache.PutContent(path, node.Version, resized)
	return 0
}

// Release flushes anything left (belt and braces: not every caller runs
// Flush) — idempotent with Flush via the flushed flag.
func (h *fileHandle) Release(ctx context.Context) syscall.Errno {
	h.mu.Lock()
	if !h.flushed {
		h.mu.Unlock()
		return h.Flush(ctx)
	}
	h.mu.Unlock()
	return 0
}

// Fsync behaves like Flush.
func (h *fileHandle) Fsync(ctx context.Context, flags uint32) syscall.Errno {
	return h.Flush(ctx)
}
