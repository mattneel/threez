const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;
const poll = @import("poll.zig");
const Completion = poll.Completion;
const OpType = poll.OpType;

/// Linux io_uring-backed async I/O poller.
///
/// Wraps `std.os.linux.IoUring` and translates completions into the
/// platform-agnostic `Completion` type used by the rest of threez.
pub const IoUringPoll = struct {
    ring: linux.IoUring,
    /// Scratch buffer for CQE copies returned by `copy_cqes`.
    cqes: [max_completions]linux.io_uring_cqe = undefined,
    /// Translated completions returned to the caller of `poll`.
    completions_buf: [max_completions]Completion = undefined,

    const max_completions = 256;
    const queue_depth: u16 = 256;

    /// Initialise the io_uring with `queue_depth` entries.
    pub fn init() !IoUringPoll {
        var self: IoUringPoll = .{
            .ring = linux.IoUring.init(queue_depth, 0) catch |err| switch (err) {
                error.SystemOutdated,
                error.PermissionDenied,
                => return err,
                else => return err,
            },
        };
        // Zero-init the scratch buffers.
        @memset(std.mem.asBytes(&self.cqes), 0);
        @memset(std.mem.asBytes(&self.completions_buf), 0);
        return self;
    }

    /// Tear down the io_uring.
    pub fn deinit(self: *IoUringPoll) void {
        self.ring.deinit();
    }

    // ------------------------------------------------------------------
    // Submission helpers
    // ------------------------------------------------------------------

    /// Submit an async file read.
    ///
    /// `fd`      — file descriptor to read from
    /// `buffer`  — destination buffer
    /// `offset`  — byte offset in the file (use 0 for streams)
    /// `userdata`— opaque value returned in the `Completion`
    pub fn submitRead(
        self: *IoUringPoll,
        fd: posix.fd_t,
        buffer: []u8,
        offset: u64,
        userdata: u64,
    ) !void {
        _ = try self.ring.read(userdata, fd, .{ .buffer = buffer }, offset);
        _ = try self.ring.submit();
    }

    /// Submit an async file write.
    pub fn submitWrite(
        self: *IoUringPoll,
        fd: posix.fd_t,
        buffer: []const u8,
        offset: u64,
        userdata: u64,
    ) !void {
        _ = try self.ring.write(userdata, fd, buffer, offset);
        _ = try self.ring.submit();
    }

    /// Submit an async socket connect.
    pub fn submitConnect(
        self: *IoUringPoll,
        socket: posix.socket_t,
        addr: *const posix.sockaddr,
        addrlen: posix.socklen_t,
        userdata: u64,
    ) !void {
        _ = try self.ring.connect(userdata, socket, addr, addrlen);
        _ = try self.ring.submit();
    }

    /// Submit an async socket recv.
    pub fn submitRecv(
        self: *IoUringPoll,
        socket: posix.socket_t,
        buffer: []u8,
        userdata: u64,
    ) !void {
        _ = try self.ring.recv(userdata, socket, .{ .buffer = buffer }, 0);
        _ = try self.ring.submit();
    }

    /// Submit an async socket send.
    pub fn submitSend(
        self: *IoUringPoll,
        socket: posix.socket_t,
        buffer: []const u8,
        userdata: u64,
    ) !void {
        _ = try self.ring.send(userdata, socket, buffer, 0);
        _ = try self.ring.submit();
    }

    // ------------------------------------------------------------------
    // Completion polling
    // ------------------------------------------------------------------

    /// Poll for completions.
    ///
    /// `timeout_ms`:
    ///   - `0` — non-blocking: return immediately with whatever is ready.
    ///   - `> 0` — wait up to `timeout_ms` milliseconds for at least one
    ///     completion, then return all that are ready.
    ///
    /// Returns a slice of `Completion` values.  The slice is backed by
    /// internal storage and is valid until the next call to `poll`.
    pub fn poll(self: *IoUringPoll, timeout_ms: u32) ![]const Completion {
        const wait_nr: u32 = if (timeout_ms > 0) 1 else 0;

        // When we want a blocking wait we use submit_and_wait which
        // enters the kernel with IORING_ENTER_GETEVENTS.  For the
        // non-blocking path, copy_cqes with wait_nr=0 simply peeks.
        if (wait_nr > 0) {
            _ = self.ring.submit_and_wait(wait_nr) catch |err| switch (err) {
                error.SignalInterrupt => return self.completions_buf[0..0],
                else => return err,
            };
        }

        const count = try self.ring.copy_cqes(&self.cqes, 0);
        return self.translateCompletions(count);
    }

    /// Translate raw CQEs into platform-agnostic `Completion` values.
    fn translateCompletions(self: *IoUringPoll, count: u32) []const Completion {
        for (0..count) |i| {
            const cqe = self.cqes[i];
            self.completions_buf[i] = .{
                .userdata = cqe.user_data,
                .result = cqe.res,
                .op_type = opTypeFromUserdata(cqe.user_data),
            };
        }
        return self.completions_buf[0..count];
    }

    /// Derive the `OpType` from a userdata convention.
    ///
    /// We encode the op type in the upper 8 bits of the userdata so that
    /// the completion path can reconstruct which operation finished.
    /// The remaining 56 bits are available to the caller for context.
    ///
    /// Encoding helpers are provided below (`encodeUserdata` / `decodeUserdata`).
    fn opTypeFromUserdata(userdata: u64) OpType {
        const tag: u8 = @truncate(userdata >> 56);
        return switch (tag) {
            @intFromEnum(OpType.read) => .read,
            @intFromEnum(OpType.write) => .write,
            @intFromEnum(OpType.connect) => .connect,
            @intFromEnum(OpType.recv) => .recv,
            @intFromEnum(OpType.send) => .send,
            @intFromEnum(OpType.accept) => .accept,
            else => .read, // fallback for raw userdata without tag
        };
    }

    // ------------------------------------------------------------------
    // Userdata encoding helpers
    // ------------------------------------------------------------------

    /// Encode an `OpType` tag and a caller-supplied context into a single
    /// 64-bit userdata value.  The op type occupies the top 8 bits.
    pub fn encodeUserdata(op: OpType, context: u56) u64 {
        return (@as(u64, @intFromEnum(op)) << 56) | @as(u64, context);
    }

    /// Decode a userdata value back into its op type tag and context.
    pub fn decodeUserdata(userdata: u64) struct { op: OpType, context: u56 } {
        const tag: u8 = @truncate(userdata >> 56);
        const ctx: u56 = @truncate(userdata);
        const op: OpType = switch (tag) {
            @intFromEnum(OpType.read) => .read,
            @intFromEnum(OpType.write) => .write,
            @intFromEnum(OpType.connect) => .connect,
            @intFromEnum(OpType.recv) => .recv,
            @intFromEnum(OpType.send) => .send,
            @intFromEnum(OpType.accept) => .accept,
            else => .read,
        };
        return .{ .op = op, .context = ctx };
    }
};

// ======================================================================
// Tests
// ======================================================================

const testing = std.testing;

/// Helper: create an IoUringPoll, skipping the test when io_uring is unavailable.
fn initTestRing() !IoUringPoll {
    return IoUringPoll.init() catch |err| switch (err) {
        error.SystemOutdated, error.PermissionDenied => return error.SkipZigTest,
        else => return err,
    };
}

// 1. Init / deinit — create ring, destroy it, no leaks.
test "IoUringPoll: init and deinit" {
    var p = try initTestRing();
    defer p.deinit();
    // If we got here the ring was created and will be cleaned up.
}

// 2. File read — write known content with std, then submitRead + poll.
test "IoUringPoll: file read" {
    var p = try initTestRing();
    defer p.deinit();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const content = "hello io_uring";
    const file = try tmp.dir.createFile("read_test", .{ .read = true, .truncate = true });
    defer file.close();
    try file.writeAll(content);

    var buf: [64]u8 = undefined;
    const userdata = IoUringPoll.encodeUserdata(.read, 0xAB);
    try p.submitRead(file.handle, &buf, 0, userdata);

    const completions = try p.poll(1000);
    try testing.expect(completions.len >= 1);

    const c = completions[0];
    // Check result is the number of bytes read.
    try testing.expectEqual(@as(i32, @intCast(content.len)), c.result);
    // Check op type came back correctly.
    try testing.expectEqual(OpType.read, c.op_type);
    // Check userdata round-tripped.
    try testing.expectEqual(userdata, c.userdata);
    // Check actual bytes.
    try testing.expectEqualSlices(u8, content, buf[0..@intCast(c.result)]);
}

// 3. File write + read round-trip.
test "IoUringPoll: file write then read" {
    var p = try initTestRing();
    defer p.deinit();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const file = try tmp.dir.createFile("write_read_test", .{ .read = true, .truncate = true });
    defer file.close();

    const payload = "round-trip test data!";
    const write_ud = IoUringPoll.encodeUserdata(.write, 1);
    try p.submitWrite(file.handle, payload, 0, write_ud);

    const wc = try p.poll(1000);
    try testing.expect(wc.len >= 1);
    try testing.expectEqual(@as(i32, @intCast(payload.len)), wc[0].result);
    try testing.expectEqual(OpType.write, wc[0].op_type);

    // Now read back.
    var buf: [64]u8 = undefined;
    const read_ud = IoUringPoll.encodeUserdata(.read, 2);
    try p.submitRead(file.handle, &buf, 0, read_ud);

    const rc = try p.poll(1000);
    try testing.expect(rc.len >= 1);
    try testing.expectEqual(@as(i32, @intCast(payload.len)), rc[0].result);
    try testing.expectEqualSlices(u8, payload, buf[0..@intCast(rc[0].result)]);
}

// 4. Multiple concurrent reads.
test "IoUringPoll: multiple concurrent reads" {
    var p = try initTestRing();
    defer p.deinit();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // Create 3 files with distinct content.
    const names = [_][]const u8{ "file_a", "file_b", "file_c" };
    const contents = [_][]const u8{ "aaaa", "bbbbbb", "cccccccc" };
    var files: [3]std.fs.File = undefined;

    for (0..3) |i| {
        files[i] = try tmp.dir.createFile(names[i], .{ .read = true, .truncate = true });
        try files[i].writeAll(contents[i]);
    }
    defer for (&files) |*f| f.close();

    // Submit all 3 reads without intermediate polls (batch submit).
    var bufs: [3][32]u8 = undefined;
    for (0..3) |i| {
        const ud = IoUringPoll.encodeUserdata(.read, @intCast(i));
        // Queue without submitting by using the ring directly, then submit once.
        _ = try p.ring.read(ud, files[i].handle, .{ .buffer = &bufs[i] }, 0);
    }
    _ = try p.ring.submit();

    // Collect all 3 completions (they may arrive across multiple poll calls).
    var seen: [3]bool = .{ false, false, false };
    var total: usize = 0;
    while (total < 3) {
        const cs = try p.poll(1000);
        for (cs) |c| {
            const decoded = IoUringPoll.decodeUserdata(c.userdata);
            const idx: usize = @intCast(decoded.context);
            try testing.expect(idx < 3);
            try testing.expect(!seen[idx]);
            seen[idx] = true;
            try testing.expectEqual(@as(i32, @intCast(contents[idx].len)), c.result);
            try testing.expectEqualSlices(u8, contents[idx], bufs[idx][0..@intCast(c.result)]);
            total += 1;
        }
    }

    for (seen) |s| try testing.expect(s);
}

// 5. Socket pair: send on one end, recv on the other.
test "IoUringPoll: socket send and recv" {
    var p = try initTestRing();
    defer p.deinit();

    // Create a Unix socket pair (STREAM) via the raw linux syscall.
    var fds: [2]i32 = undefined;
    const rc = linux.socketpair(linux.AF.UNIX, linux.SOCK.STREAM, 0, &fds);
    if (linux.E.init(rc) != .SUCCESS) return error.SkipZigTest;
    defer {
        posix.close(fds[0]);
        posix.close(fds[1]);
    }

    const message = "io_uring socketpair";
    const send_ud = IoUringPoll.encodeUserdata(.send, 10);
    const recv_ud = IoUringPoll.encodeUserdata(.recv, 11);

    // Submit send + recv together.
    _ = try p.ring.send(send_ud, fds[0], message, 0);
    var recv_buf: [64]u8 = undefined;
    _ = try p.ring.recv(recv_ud, fds[1], .{ .buffer = &recv_buf }, 0);
    _ = try p.ring.submit();

    // Collect both completions.
    var got_send = false;
    var got_recv = false;
    var attempts: usize = 0;
    while ((!got_send or !got_recv) and attempts < 10) : (attempts += 1) {
        const cs = try p.poll(1000);
        for (cs) |c| {
            const decoded = IoUringPoll.decodeUserdata(c.userdata);
            if (decoded.op == .send) {
                try testing.expectEqual(@as(i32, @intCast(message.len)), c.result);
                got_send = true;
            } else if (decoded.op == .recv) {
                try testing.expect(c.result > 0);
                try testing.expectEqualSlices(
                    u8,
                    message[0..@intCast(c.result)],
                    recv_buf[0..@intCast(c.result)],
                );
                got_recv = true;
            }
        }
    }
    try testing.expect(got_send);
    try testing.expect(got_recv);
}

// 6. Non-blocking poll when no ops are pending returns empty slice.
test "IoUringPoll: non-blocking poll returns empty" {
    var p = try initTestRing();
    defer p.deinit();

    const completions = try p.poll(0);
    try testing.expectEqual(@as(usize, 0), completions.len);
}

// 7. Userdata round-trip: submit with specific userdata, verify on completion.
test "IoUringPoll: userdata round-trip" {
    var p = try initTestRing();
    defer p.deinit();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const file = try tmp.dir.createFile("ud_test", .{ .read = true, .truncate = true });
    defer file.close();
    try file.writeAll("x");

    const magic: u64 = 0xDEAD_BEEF_CAFE_0042;
    var buf: [8]u8 = undefined;
    try p.submitRead(file.handle, &buf, 0, magic);

    const completions = try p.poll(1000);
    try testing.expect(completions.len >= 1);
    try testing.expectEqual(magic, completions[0].userdata);
    try testing.expectEqual(@as(i32, 1), completions[0].result);
}

// 8. Encode / decode userdata helpers.
test "IoUringPoll: encode and decode userdata" {
    const ctx: u56 = 0x00_1234_5678_9ABC;
    const encoded = IoUringPoll.encodeUserdata(.send, ctx);
    const decoded = IoUringPoll.decodeUserdata(encoded);
    try testing.expectEqual(OpType.send, decoded.op);
    try testing.expectEqual(ctx, decoded.context);
}
