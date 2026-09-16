# Go FUSE daemon (fuse/) — build with: make fuse-build
.PHONY: fuse-build fuse-build-linux

fuse-build:
	cd fuse && go build -o ../bin/mcp-fuse .

# Cross-compiled Linux binaries (amd64 + arm64). hanwen/go-fuse is pure Go,
# so CGO can stay disabled; fusermount3 is required at runtime on the target.
fuse-build-linux:
	cd fuse && CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -trimpath -ldflags="-s -w" -o ../bin/mcp-fuse-linux-amd64 .
	cd fuse && CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go build -trimpath -ldflags="-s -w" -o ../bin/mcp-fuse-linux-arm64 .
