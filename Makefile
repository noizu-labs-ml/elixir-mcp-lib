# Go FUSE daemon (fuse/) — build with: make fuse-build
# Cross companions: make fuse-cross  (linux/amd64 linux/arm64 darwin/arm64 windows/amd64 windows/arm64)
.PHONY: fuse-build fuse-cross fuse-linux-amd64 fuse-linux-arm64 fuse-darwin-arm64 fuse-windows-amd64 fuse-windows-arm64

fuse-build:
	cd fuse && go build -o ../bin/mcp-fuse .

fuse-linux-amd64:
	cd fuse && GOOS=linux GOARCH=amd64 CGO_ENABLED=0 go build -o ../bin/mcp-fuse-linux-amd64 .

fuse-linux-arm64:
	cd fuse && GOOS=linux GOARCH=arm64 CGO_ENABLED=0 go build -o ../bin/mcp-fuse-linux-arm64 .

fuse-darwin-arm64:
	cd fuse && GOOS=darwin GOARCH=arm64 CGO_ENABLED=0 go build -o ../bin/mcp-fuse-darwin-arm64 .

# Windows uses CGO_ENABLED=0 (cgofuse nocgo): WinFsp is demand-loaded at mount
# time, so the binary does not need WinFsp headers to compile.
fuse-windows-amd64:
	cd fuse && GOOS=windows GOARCH=amd64 CGO_ENABLED=0 go build -o ../bin/mcp-fuse-windows-amd64.exe .

fuse-windows-arm64:
	cd fuse && GOOS=windows GOARCH=arm64 CGO_ENABLED=0 go build -o ../bin/mcp-fuse-windows-arm64.exe .

fuse-cross: fuse-linux-amd64 fuse-linux-arm64 fuse-darwin-arm64 fuse-windows-amd64 fuse-windows-arm64
