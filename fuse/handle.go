package main

const defaultMaxFileSize = 8 << 20

const maxInt = int(^uint(0) >> 1)

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

func childPath(dir, name string) string {
	if dir == "/" {
		return "/" + name
	}
	return dir + "/" + name
}

func statCached(client *Client, cache *Cache, path string) (*Node, vfsErrno) {
	if node, ok := cache.GetAttr(path); ok {
		return node, 0
	}
	node, errno := client.Stat(path)
	if errno != 0 {
		return nil, errno
	}
	cache.PutAttr(path, node)
	return node, 0
}

func contentReader(client *Client, cache *Cache, path string) ([]byte, vfsErrno) {
	node, errno := statCached(client, cache, path)
	if errno != 0 {
		return nil, errno
	}
	if data, ok := cache.GetContent(path, node.Version); ok {
		return data, 0
	}
	data, version, errno := client.Read(path)
	if errno != 0 {
		return nil, errno
	}
	cache.PutContent(path, version, data)
	return data, 0
}

func listAll(client *Client, cache *Cache, path string) ([]Entry, vfsErrno) {
	if entries, ok := cache.GetDentries(path); ok {
		return entries, 0
	}
	var all []Entry
	cursor := ""
	for {
		page, next, errno := client.List(path, cursor)
		if errno != 0 {
			return nil, errno
		}
		all = append(all, page...)
		if next == "" {
			break
		}
		cursor = next
	}
	cache.PutDentries(path, all)
	return all, 0
}

func truncatePath(client *Client, cache *Cache, path string, size, maxFileSize uint64) vfsErrno {
	data, errno := contentReader(client, cache, path)
	if errno != 0 {
		return errno
	}
	resized, errno := resizeContent(data, size, maxFileSize)
	if errno != 0 {
		return errno
	}
	node, errno := client.Write(path, resized)
	if errno != 0 {
		return errno
	}
	cache.PutAttr(path, node)
	cache.PutContent(path, node.Version, resized)
	return 0
}

func applyFileOps(base []byte, ops []fileOp, maxFileSize uint64) ([]byte, vfsErrno) {
	var buf []byte
	start := 0
	if uint64(len(base)) > maxFileSize {
		// A pre-existing oversized file may only enter a write batch if its
		// first operation brings it under the configured ceiling. Do that
		// before copying the oversized base.
		if len(ops) == 0 || ops[0].kind != opTruncate {
			return nil, vfsEFBIG
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
				return nil, vfsEFBIG
			}
			end := int(op.off) + len(op.data)
			if end > len(buf) {
				grown := make([]byte, end)
				copy(grown, buf)
				buf = grown
			}
			copy(buf[int(op.off):end], op.data)
		default:
			return nil, vfsEINVAL
		}
	}
	return buf, 0
}

func resizeContent(data []byte, size, maxFileSize uint64) ([]byte, vfsErrno) {
	if size > maxFileSize || size > uint64(maxInt) {
		return nil, vfsEFBIG
	}
	resized := make([]byte, int(size))
	copy(resized, data)
	return resized, 0
}

func flushBuffer(client *Client, cache *Cache, path string, ro bool, maxFileSize uint64, startTrunc bool, ops []fileOp) ([]byte, *Node, vfsErrno) {
	if ro {
		return nil, nil, vfsEROFS
	}
	var base []byte
	if !startTrunc {
		data, errno := contentReader(client, cache, path)
		if errno != 0 {
			return nil, nil, errno
		}
		base = data
	}
	buf, errno := applyFileOps(base, ops, maxFileSize)
	if errno != 0 {
		return nil, nil, errno
	}
	node, errno := client.Write(path, buf)
	if errno != 0 {
		if errno == vfsENOENT {
			return nil, nil, vfsESTALE
		}
		return nil, nil, errno
	}
	cache.PutAttr(path, node)
	cache.PutContent(path, node.Version, buf)
	return buf, node, 0
}
