const std = @import("std");
const builtin = @import("builtin");

/// The type of async I/O operation.
pub const OpType = enum {
    read,
    write,
    connect,
    recv,
    send,
    accept,
};

/// Result of a completed async I/O operation.
/// This struct is backend-agnostic and is returned by all platform pollers.
pub const Completion = struct {
    /// Caller-provided context (e.g., pointer to PendingIO cast to u64).
    userdata: u64,
    /// Bytes transferred on success, or negative errno on failure.
    result: i32,
    /// Which operation completed.
    op_type: OpType,
};

/// Platform-specific async I/O poller.
/// On Linux, this is backed by io_uring.
/// Future backends: kqueue (macOS/FreeBSD), IOCP (Windows).
pub const IOPoll = switch (builtin.os.tag) {
    .linux => @import("io_uring.zig").IoUringPoll,
    // .macos, .freebsd => @import("kqueue.zig").KqueuePoll,   // T6b
    // .windows => @import("iocp.zig").IocpPoll,                // T6c
    else => @compileError("unsupported platform for async I/O"),
};

test {
    std.testing.refAllDecls(@This());
}
