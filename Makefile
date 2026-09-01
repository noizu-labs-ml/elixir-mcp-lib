# Go FUSE daemon (fuse/) — build with: make fuse-build
.PHONY: fuse-build

fuse-build:
	cd fuse && go build -o ../bin/mcp-fuse .
