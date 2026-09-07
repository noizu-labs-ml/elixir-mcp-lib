package main

import "fmt"

// vfsErrno is a POSIX errno using Linux ABI numbers so client.go can run on
// every GOOS (Windows syscall.Errno is a Win32 code and lacks EROFS/EISDIR/
// ENOSYS/ESTALE/EFBIG/EOPNOTSUPP). Unix FUSE converts these to syscall.Errno;
// Windows cgofuse maps them to WinFsp codes and returns -int(code).
type vfsErrno uintptr

const (
	vfsOK         vfsErrno = 0
	vfsEPERM      vfsErrno = 1
	vfsENOENT     vfsErrno = 2
	vfsEIO        vfsErrno = 5
	vfsEBADF      vfsErrno = 9
	vfsEACCES     vfsErrno = 13
	vfsEEXIST     vfsErrno = 17
	vfsENOTDIR    vfsErrno = 20
	vfsEISDIR     vfsErrno = 21
	vfsEINVAL     vfsErrno = 22
	vfsEFBIG      vfsErrno = 27
	vfsEROFS      vfsErrno = 30
	vfsENOSYS     vfsErrno = 38
	vfsENOTEMPTY  vfsErrno = 39
	vfsEOPNOTSUPP vfsErrno = 95
	vfsECONNRESET vfsErrno = 104
	vfsESTALE     vfsErrno = 116
)

var vfsErrnoNames = map[vfsErrno]string{
	vfsEPERM:      "eperm",
	vfsENOENT:     "enoent",
	vfsEIO:        "eio",
	vfsEBADF:      "ebadf",
	vfsEACCES:     "eacces",
	vfsEEXIST:     "eexist",
	vfsENOTDIR:    "enotdir",
	vfsEISDIR:     "eisdir",
	vfsEINVAL:     "einval",
	vfsEFBIG:      "efbig",
	vfsEROFS:      "erofs",
	vfsENOSYS:     "enosys",
	vfsENOTEMPTY:  "enotempty",
	vfsEOPNOTSUPP: "eopnotsupp",
	vfsECONNRESET: "econnreset",
	vfsESTALE:     "estale",
}

func (e vfsErrno) Error() string {
	if e == 0 {
		return "ok"
	}
	if name, ok := vfsErrnoNames[e]; ok {
		return name
	}
	return fmt.Sprintf("errno %d", int(e))
}

func (e vfsErrno) String() string { return e.Error() }
