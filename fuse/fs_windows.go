//go:build windows

package main

import (
	"strings"
	"sync"
	"time"

	"github.com/winfsp/cgofuse/fuse"
)

// winFS is a path-style cgofuse adapter over the shared Client/Cache.
// Built with CGO_ENABLED=0: WinFsp is demand-loaded at mount time, so the
// binary does not need WinFsp headers to compile.
type winFS struct {
	fuse.FileSystemBase
	client      *Client
	cache       *Cache
	ro          bool
	maxFileSize uint64

	mu    sync.Mutex
	next  uint64
	files map[uint64]*winHandle
}

type winHandle struct {
	path       string
	mu         sync.Mutex
	ops        []fileOp
	startTrunc bool
	dirty      bool
	flushed    bool
}

func newWinFS(client *Client, cache *Cache, ro bool, maxFile uint64) *winFS {
	return &winFS{
		client:      client,
		cache:       cache,
		ro:          ro,
		maxFileSize: maxFile,
		files:       map[uint64]*winHandle{},
	}
}

func fusePath(p string) string {
	p = strings.ReplaceAll(p, "\\", "/")
	if p == "" {
		return "/"
	}
	return p
}

// fuseErr returns 0 or the negative WinFsp/cgofuse errno. WinFsp's table
// diverges from Linux for ENOSYS/ENOTEMPTY/EOPNOTSUPP/ECONNRESET, so we map
// through fuse.E* rather than negating the Linux vfsErrno number blindly.
func fuseErr(e vfsErrno) int {
	if e == 0 {
		return 0
	}
	return -winErrno(e)
}

func winErrno(e vfsErrno) int {
	switch e {
	case vfsEPERM:
		return fuse.EPERM
	case vfsENOENT:
		return fuse.ENOENT
	case vfsEIO:
		return fuse.EIO
	case vfsEBADF:
		return fuse.EBADF
	case vfsEACCES:
		return fuse.EACCES
	case vfsEEXIST:
		return fuse.EEXIST
	case vfsENOTDIR:
		return fuse.ENOTDIR
	case vfsEISDIR:
		return fuse.EISDIR
	case vfsEINVAL:
		return fuse.EINVAL
	case vfsEFBIG:
		return fuse.EFBIG
	case vfsEROFS:
		return fuse.EROFS
	case vfsENOSYS:
		return fuse.ENOSYS
	case vfsENOTEMPTY:
		return fuse.ENOTEMPTY
	case vfsEOPNOTSUPP:
		return fuse.EOPNOTSUPP
	case vfsECONNRESET:
		return fuse.ECONNRESET
	case vfsESTALE:
		return fuse.ETIMEDOUT
	default:
		return fuse.EIO
	}
}

func winMode(node *Node) uint32 {
	switch node.Type {
	case "dir":
		m := uint32(fuse.S_IFDIR | 0555)
		if node.Writable {
			m |= 0200
		}
		return m
	default:
		m := uint32(fuse.S_IFREG | 0444)
		if node.Writable {
			m |= 0200
		}
		if node.Executable {
			m |= 0111
		}
		return m
	}
}

func fillStat(node *Node, stat *fuse.Stat_t) {
	stat.Mode = winMode(node)
	stat.Size = node.Size
	ts := fuse.NewTimespec(time.UnixMilli(node.Mtime))
	stat.Atim = ts
	stat.Mtim = ts
	stat.Ctim = ts
	stat.Birthtim = ts
	stat.Nlink = 1
	stat.Blksize = 4096
	stat.Blocks = (node.Size + 511) / 512
}

func (fs *winFS) alloc(h *winHandle) uint64 {
	fs.mu.Lock()
	defer fs.mu.Unlock()
	fs.next++
	fs.files[fs.next] = h
	return fs.next
}

func (fs *winFS) get(fh uint64) *winHandle {
	fs.mu.Lock()
	defer fs.mu.Unlock()
	return fs.files[fh]
}

func (fs *winFS) take(fh uint64) *winHandle {
	fs.mu.Lock()
	defer fs.mu.Unlock()
	h := fs.files[fh]
	delete(fs.files, fh)
	return h
}

func (fs *winFS) Getattr(path string, stat *fuse.Stat_t, fh uint64) int {
	path = fusePath(path)
	node, errno := statCached(fs.client, fs.cache, path)
	if errno != 0 {
		return fuseErr(errno)
	}
	fillStat(node, stat)
	return 0
}

func (fs *winFS) Readdir(path string, fill func(name string, stat *fuse.Stat_t, ofst int64) bool, ofst int64, fh uint64) int {
	path = fusePath(path)
	entries, errno := listAll(fs.client, fs.cache, path)
	if errno != 0 {
		return fuseErr(errno)
	}
	fill(".", nil, 0)
	fill("..", nil, 0)
	for _, e := range entries {
		st := fuse.Stat_t{}
		fillStat(&Node{Type: e.Type, Size: e.Size, Mtime: e.Mtime, Writable: true}, &st)
		if !fill(e.Name, &st, 0) {
			break
		}
	}
	return 0
}

func (fs *winFS) Open(path string, flags int) (int, uint64) {
	path = fusePath(path)
	accmode := flags & fuse.O_ACCMODE
	truncate := flags&fuse.O_TRUNC != 0
	if accmode == fuse.O_WRONLY || accmode == fuse.O_RDWR || truncate {
		if fs.ro {
			return fuseErr(vfsEROFS), ^uint64(0)
		}
		node, errno := statCached(fs.client, fs.cache, path)
		if errno != 0 {
			return fuseErr(errno), ^uint64(0)
		}
		if !node.Writable {
			return fuseErr(vfsEACCES), ^uint64(0)
		}
	}
	return 0, fs.alloc(&winHandle{path: path, startTrunc: truncate, dirty: truncate})
}

func (fs *winFS) Create(path string, flags int, mode uint32) (int, uint64) {
	path = fusePath(path)
	if fs.ro {
		return fuseErr(vfsEROFS), ^uint64(0)
	}
	node, errno := fs.client.Create(path, nil)
	if errno != 0 {
		return fuseErr(errno), ^uint64(0)
	}
	fs.cache.Invalidate(path)
	fs.cache.PutAttr(path, node)
	return 0, fs.alloc(&winHandle{path: path, startTrunc: true})
}

func (fs *winFS) Unlink(path string) int {
	if fs.ro {
		return fuseErr(vfsEROFS)
	}
	path = fusePath(path)
	if errno := fs.client.Remove(path); errno != 0 {
		return fuseErr(errno)
	}
	fs.cache.Invalidate(path)
	return 0
}

func (fs *winFS) Truncate(path string, size int64, fh uint64) int {
	if size < 0 {
		return fuseErr(vfsEINVAL)
	}
	if fs.ro {
		return fuseErr(vfsEROFS)
	}
	if uint64(size) > fs.maxFileSize {
		return fuseErr(vfsEFBIG)
	}
	path = fusePath(path)
	if h := fs.get(fh); h != nil {
		h.mu.Lock()
		h.ops = append(h.ops, fileOp{kind: opTruncate, size: uint64(size)})
		h.dirty = true
		h.flushed = false
		h.mu.Unlock()
		return fuseErr(fs.flushHandle(h))
	}
	node, errno := statCached(fs.client, fs.cache, path)
	if errno != 0 {
		return fuseErr(errno)
	}
	if node.Type == "dir" {
		return fuseErr(vfsEISDIR)
	}
	if !node.Writable {
		return fuseErr(vfsEACCES)
	}
	return fuseErr(truncatePath(fs.client, fs.cache, path, uint64(size), fs.maxFileSize))
}

func (fs *winFS) Read(path string, buff []byte, ofst int64, fh uint64) int {
	if h := fs.get(fh); h != nil {
		h.mu.Lock()
		defer h.mu.Unlock()
		data, errno := fs.materializeLocked(h)
		if errno != 0 {
			return fuseErr(errno)
		}
		return copyAt(data, buff, ofst)
	}
	data, errno := contentReader(fs.client, fs.cache, fusePath(path))
	if errno != 0 {
		return fuseErr(errno)
	}
	return copyAt(data, buff, ofst)
}

func copyAt(data, buff []byte, ofst int64) int {
	if ofst < 0 {
		return fuseErr(vfsEINVAL)
	}
	if ofst >= int64(len(data)) {
		return 0
	}
	return copy(buff, data[ofst:])
}

func (fs *winFS) Write(path string, buff []byte, ofst int64, fh uint64) int {
	if fs.ro {
		return fuseErr(vfsEROFS)
	}
	h := fs.get(fh)
	if h == nil {
		return fuseErr(vfsEBADF)
	}
	if ofst < 0 {
		return fuseErr(vfsEINVAL)
	}
	if uint64(ofst) > fs.maxFileSize || uint64(len(buff)) > fs.maxFileSize-uint64(ofst) {
		return fuseErr(vfsEFBIG)
	}
	buf := make([]byte, len(buff))
	copy(buf, buff)
	h.mu.Lock()
	h.ops = append(h.ops, fileOp{kind: opWrite, off: ofst, data: buf})
	h.dirty = true
	h.flushed = false
	h.mu.Unlock()
	return len(buff)
}

func (fs *winFS) Flush(path string, fh uint64) int {
	h := fs.get(fh)
	if h == nil {
		return 0
	}
	return fuseErr(fs.flushHandle(h))
}

func (fs *winFS) Release(path string, fh uint64) int {
	h := fs.take(fh)
	if h == nil {
		return 0
	}
	return fuseErr(fs.flushHandle(h))
}

func (fs *winFS) Fsync(path string, datasync bool, fh uint64) int {
	return fs.Flush(path, fh)
}

func (fs *winFS) Chmod(path string, mode uint32) int { return fuseErr(vfsEOPNOTSUPP) }

func (fs *winFS) Chown(path string, uid uint32, gid uint32) int { return fuseErr(vfsEOPNOTSUPP) }

func (fs *winFS) Utimens(path string, tmsp []fuse.Timespec) int { return fuseErr(vfsEOPNOTSUPP) }

func (fs *winFS) flushHandle(h *winHandle) vfsErrno {
	h.mu.Lock()
	defer h.mu.Unlock()
	if !h.dirty || h.flushed {
		return 0
	}
	_, _, errno := flushBuffer(fs.client, fs.cache, h.path, fs.ro, fs.maxFileSize, h.startTrunc, h.ops)
	if errno != 0 {
		return errno
	}
	h.ops = nil
	h.startTrunc = false
	h.dirty = false
	h.flushed = true
	return 0
}

func (fs *winFS) materializeLocked(h *winHandle) ([]byte, vfsErrno) {
	if !h.dirty {
		return contentReader(fs.client, fs.cache, h.path)
	}
	var base []byte
	if !h.startTrunc {
		data, errno := contentReader(fs.client, fs.cache, h.path)
		if errno != 0 {
			return nil, errno
		}
		base = data
	}
	return applyFileOps(base, h.ops, fs.maxFileSize)
}
