package main

import (
	"sync"
	"time"
)

// Cache is the daemon-side caching layer: attribute entries with a short
// TTL, directory listings with a slightly longer TTL, and file content
// keyed by the server's node version so a write on the server side
// (version bump) invalidates stale content naturally.
type Cache struct {
	mu        sync.Mutex
	attrTTL   time.Duration
	dentryTTL time.Duration

	attrs    map[string]attrEntry
	dentries map[string]dentryEntry
	content  map[string]contentEntry
}

type attrEntry struct {
	node *Node
	exp  time.Time
}

type dentryEntry struct {
	entries []Entry
	exp     time.Time
}

type contentEntry struct {
	version int64
	data    []byte
}

func NewCache(attrTTL, dentryTTL time.Duration) *Cache {
	return &Cache{
		attrTTL:   attrTTL,
		dentryTTL: dentryTTL,
		attrs:     map[string]attrEntry{},
		dentries:  map[string]dentryEntry{},
		content:   map[string]contentEntry{},
	}
}

func (c *Cache) GetAttr(path string) (*Node, bool) {
	c.mu.Lock()
	defer c.mu.Unlock()
	e, ok := c.attrs[path]
	if !ok || time.Now().After(e.exp) {
		if ok {
			delete(c.attrs, path)
		}
		return nil, false
	}
	return e.node, true
}

func (c *Cache) PutAttr(path string, node *Node) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.attrs[path] = attrEntry{node: node, exp: time.Now().Add(c.attrTTL)}
}

// GetContent only hits when the cached version matches the node's current
// version (as reported by stat); a version bump is a natural invalidation.
func (c *Cache) GetContent(path string, version int64) ([]byte, bool) {
	c.mu.Lock()
	defer c.mu.Unlock()
	e, ok := c.content[path]
	if !ok || e.version != version {
		return nil, false
	}
	return e.data, true
}

func (c *Cache) PutContent(path string, version int64, data []byte) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.content[path] = contentEntry{version: version, data: data}
}

func (c *Cache) GetDentries(path string) ([]Entry, bool) {
	c.mu.Lock()
	defer c.mu.Unlock()
	e, ok := c.dentries[path]
	if !ok || time.Now().After(e.exp) {
		if ok {
			delete(c.dentries, path)
		}
		return nil, false
	}
	return e.entries, true
}

func (c *Cache) PutDentries(path string, entries []Entry) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.dentries[path] = dentryEntry{entries: entries, exp: time.Now().Add(c.dentryTTL)}
}

// Invalidate drops all cached state for path plus the parent directory's
// entry listing (a write/create/remove may have changed either).
func (c *Cache) Invalidate(path string) {
	c.mu.Lock()
	defer c.mu.Unlock()
	delete(c.attrs, path)
	delete(c.content, path)
	delete(c.dentries, parentDir(path))
}

func parentDir(path string) string {
	for i := len(path) - 1; i > 0; i-- {
		if path[i] == '/' {
			if i == 1 {
				return "/"
			}
			return path[:i]
		}
	}
	return "/"
}
