package main

import (
	"testing"
	"time"
)

func TestAttrCacheTTLExpiry(t *testing.T) {
	c := NewCache(20*time.Millisecond, time.Second)
	node := &Node{Type: "file", Version: 1}
	c.PutAttr("/a", node)
	if got, ok := c.GetAttr("/a"); !ok || got != node {
		t.Fatal("fresh attr should hit")
	}
	time.Sleep(40 * time.Millisecond)
	if _, ok := c.GetAttr("/a"); ok {
		t.Fatal("expired attr should miss")
	}
}

func TestContentCacheVersionKeying(t *testing.T) {
	c := NewCache(time.Second, time.Second)
	c.PutContent("/a", 3, []byte("v3"))
	if data, ok := c.GetContent("/a", 3); !ok || string(data) != "v3" {
		t.Fatal("matching version should hit")
	}
	if _, ok := c.GetContent("/a", 4); ok {
		t.Fatal("version bump must invalidate content")
	}
}

func TestDentryCacheTTL(t *testing.T) {
	c := NewCache(time.Second, 20*time.Millisecond)
	c.PutDentries("/d", []Entry{{Name: "x", Type: "file"}})
	if e, ok := c.GetDentries("/d"); !ok || len(e) != 1 {
		t.Fatal("fresh dentries should hit")
	}
	time.Sleep(40 * time.Millisecond)
	if _, ok := c.GetDentries("/d"); ok {
		t.Fatal("expired dentries should miss")
	}
}

func TestInvalidateDropsPathAndParentListing(t *testing.T) {
	c := NewCache(time.Minute, time.Minute)
	c.PutAttr("/d/f", &Node{Type: "file"})
	c.PutContent("/d/f", 1, []byte("x"))
	c.PutDentries("/d", []Entry{{Name: "f", Type: "file"}})
	c.PutAttr("/other", &Node{Type: "file"})

	c.Invalidate("/d/f")

	if _, ok := c.GetAttr("/d/f"); ok {
		t.Fatal("Invalidate must drop attr for path")
	}
	if _, ok := c.GetContent("/d/f", 1); ok {
		t.Fatal("Invalidate must drop content for path")
	}
	if _, ok := c.GetDentries("/d"); ok {
		t.Fatal("Invalidate must drop parent dentry listing")
	}
	if _, ok := c.GetAttr("/other"); !ok {
		t.Fatal("Invalidate must not touch unrelated paths")
	}
}

func TestParentDir(t *testing.T) {
	cases := map[string]string{
		"/a":     "/",
		"/a/b":   "/a",
		"/a/b/c": "/a/b",
		"/":      "/",
	}
	for in, want := range cases {
		if got := parentDir(in); got != want {
			t.Errorf("parentDir(%q) = %q, want %q", in, got, want)
		}
	}
}
