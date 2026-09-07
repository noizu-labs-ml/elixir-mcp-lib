//go:build unix

package main

import "syscall"

// toSyscall maps a portable POSIX vfsErrno onto this platform's syscall.Errno.
func toSyscall(e vfsErrno) syscall.Errno {
	if e == 0 {
		return 0
	}
	switch e {
	case vfsEPERM:
		return syscall.EPERM
	case vfsENOENT:
		return syscall.ENOENT
	case vfsEIO:
		return syscall.EIO
	case vfsEBADF:
		return syscall.EBADF
	case vfsEACCES:
		return syscall.EACCES
	case vfsEEXIST:
		return syscall.EEXIST
	case vfsENOTDIR:
		return syscall.ENOTDIR
	case vfsEISDIR:
		return syscall.EISDIR
	case vfsEINVAL:
		return syscall.EINVAL
	case vfsEFBIG:
		return syscall.EFBIG
	case vfsEROFS:
		return syscall.EROFS
	case vfsENOSYS:
		return syscall.ENOSYS
	case vfsENOTEMPTY:
		return syscall.ENOTEMPTY
	case vfsEOPNOTSUPP:
		return syscall.EOPNOTSUPP
	case vfsECONNRESET:
		return syscall.ECONNRESET
	case vfsESTALE:
		return syscall.ESTALE
	default:
		return syscall.EIO
	}
}
