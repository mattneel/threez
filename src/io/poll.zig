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
/// Compile-time dispatched — zero overhead abstraction.
pub const IOPoll = switch (builtin.os.tag) {
    .linux => @import("io_uring.zig").IoUringPoll,
    .macos, .freebsd, .netbsd => @import("kqueue.zig").KqueuePoll,
    .windows => @import("iocp.zig").IocpPoll,
    else => @compileError("unsupported platform for async I/O"),
};

test {
    std.testing.refAllDecls(@This());
}
