const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const poll = @import("poll.zig");
const Completion = poll.Completion;
const OpType = poll.OpType;

/// Whether we are on a kqueue-capable OS.
const is_kqueue_os = switch (builtin.os.tag) {
    .macos, .freebsd, .dragonfly, .openbsd, .netbsd => true,
    else => false,
};

/// Platform types — resolved at comptime so the file parses on any OS.
const system = posix.system;
const Kevent = if (is_kqueue_os) posix.Kevent else void;
const c = std.c;

/// macOS / BSD kqueue-backed async I/O poller.
///
/// Socket I/O uses EVFILT_READ / EVFILT_WRITE for true async notification.
/// Regular file I/O is performed synchronously with pread/pwrite (kqueue
/// cannot watch regular files for readiness) and returned as an immediate
/// completion.
pub const KqueuePoll = struct {
    kq_fd: posix.fd_t,
    /// Pending immediate completions (from synchronous file I/O).
    immediate_completions: [max_completions]Completion = undefined,
    immediate_count: u32 = 0,
    /// Scratch buffer for kevent results.
    events_buf: [max_completions]if (is_kqueue_os) Kevent else u8 = undefined,
    /// Translated completions returned to the caller of `poll`.
    completions_buf: [max_completions]Completion = undefined,

    const max_completions = 256;

    /// Initialise the kqueue poller.
    pub fn init() !KqueuePoll {
        if (!is_kqueue_os) {
            return error.SystemOutdated;
        }

        const kq_fd = c.kqueue();
        if (kq_fd == -1) {
            return error.SystemOutdated;
        }

        var self: KqueuePoll = .{
            .kq_fd = kq_fd,
        };
        // Zero-init the scratch buffers.
        @memset(std.mem.asBytes(&self.events_buf), 0);
        @memset(std.mem.asBytes(&self.completions_buf), 0);
        @memset(std.mem.asBytes(&self.immediate_completions), 0);
        return self;
    }

    /// Tear down the kqueue poller.
    pub fn deinit(self: *KqueuePoll) void {
        posix.close(self.kq_fd);
    }

    // ------------------------------------------------------------------
    // Submission helpers
    // ------------------------------------------------------------------

    /// Submit an async file read.
    ///
    /// kqueue cannot do async I/O on regular files, so we perform a
    /// synchronous pread and queue an immediate completion.
    ///
    /// `fd`      — file descriptor to read from
    /// `buffer`  — destination buffer
    /// `offset`  — byte offset in the file (use 0 for streams)
    /// `userdata`— opaque value returned in the `Completion`
    pub fn submitRead(
        self: *KqueuePoll,
        fd: posix.fd_t,
        buffer: []u8,
        offset: u64,
        userdata: u64,
    ) !void {
        if (!is_kqueue_os) return error.SystemOutdated;

        // Perform synchronous pread for regular file I/O.
        const signed_offset: i64 = @intCast(offset);
        const rc = c.pread(fd, buffer.ptr, buffer.len, signed_offset);
        const result: i32 = if (rc >= 0)
            @intCast(rc)
        else
            -@as(i32, @intCast(@intFromEnum(posix.errno(rc))));

        if (self.immediate_count < max_completions) {
            self.immediate_completions[self.immediate_count] = .{
                .userdata = userdata,
                .result = result,
                .op_type = opTypeFromUserdata(userdata),
            };
            self.immediate_count += 1;
        }
    }

    /// Submit an async file write.
    ///
    /// Like submitRead, regular file writes are performed synchronously.
    pub fn submitWrite(
        self: *KqueuePoll,
        fd: posix.fd_t,
        buffer: []const u8,
        offset: u64,
        userdata: u64,
    ) !void {
        if (!is_kqueue_os) return error.SystemOutdated;

        const signed_offset: i64 = @intCast(offset);
        const rc = c.pwrite(fd, buffer.ptr, buffer.len, signed_offset);
        const result: i32 = if (rc >= 0)
            @intCast(rc)
        else
            -@as(i32, @intCast(@intFromEnum(posix.errno(rc))));

        if (self.immediate_count < max_completions) {
            self.immediate_completions[self.immediate_count] = .{
                .userdata = userdata,
                .result = result,
                .op_type = opTypeFromUserdata(userdata),
            };
            self.immediate_count += 1;
        }
    }

    /// Submit an async socket connect.
    ///
    /// Initiates a non-blocking connect and registers EVFILT_WRITE to
    /// detect when the connection completes (or fails).
    pub fn submitConnect(
        self: *KqueuePoll,
        socket: posix.socket_t,
        addr: *const posix.sockaddr,
        addrlen: posix.socklen_t,
        userdata: u64,
    ) !void {
        if (!is_kqueue_os) return error.SystemOutdated;

        // Attempt non-blocking connect.
        const rc = system.connect(socket, addr, addrlen);
        const err = posix.errno(rc);

        if (err == .SUCCESS) {
            // Connected immediately — queue immediate completion.
            if (self.immediate_count < max_completions) {
                self.immediate_completions[self.immediate_count] = .{
                    .userdata = userdata,
                    .result = 0,
                    .op_type = .connect,
                };
                self.immediate_count += 1;
            }
            return;
        }

        if (err != .INPROGRESS) {
            // Real error — queue as immediate negative errno.
            if (self.immediate_count < max_completions) {
                self.immediate_completions[self.immediate_count] = .{
                    .userdata = userdata,
                    .result = -@as(i32, @intCast(@intFromEnum(err))),
                    .op_type = .connect,
                };
                self.immediate_count += 1;
            }
            return;
        }

        // EINPROGRESS — register EVFILT_WRITE to detect completion.
        try self.registerFilter(socket, c.EVFILT.WRITE, userdata);
    }

    /// Submit an async socket recv.
    ///
    /// Registers EVFILT_READ so we get notified when data is available,
    /// then the caller should recv() in the completion handler.
    /// For simplicity (matching io_uring semantics), we register the
    /// event and when it fires, perform the recv inline during poll().
    pub fn submitRecv(
        self: *KqueuePoll,
        socket: posix.socket_t,
        buffer: []u8,
        userdata: u64,
    ) !void {
        if (!is_kqueue_os) return error.SystemOutdated;

        // Store the buffer info in the pending ops tracker so we can
        // actually perform the recv when the event fires.
        try self.addPendingOp(.{
            .fd = socket,
            .userdata = userdata,
            .op = .recv,
            .buffer = buffer.ptr,
            .buffer_len = buffer.len,
        });

        try self.registerFilter(socket, c.EVFILT.READ, userdata);
    }

    /// Submit an async socket send.
    ///
    /// Registers EVFILT_WRITE so we get notified when the socket is
    /// writable, then performs the send inline during poll().
    pub fn submitSend(
        self: *KqueuePoll,
        socket: posix.socket_t,
        buffer: []const u8,
        userdata: u64,
    ) !void {
        if (!is_kqueue_os) return error.SystemOutdated;

        try self.addPendingOp(.{
            .fd = socket,
            .userdata = userdata,
            .op = .send,
            .buffer = @constCast(buffer.ptr),
            .buffer_len = buffer.len,
        });

        try self.registerFilter(socket, c.EVFILT.WRITE, userdata);
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
    /// Returns a slice of `Completion` values. The slice is backed by
    /// internal storage and is valid until the next call to `poll`.
    pub fn poll(self: *KqueuePoll, timeout_ms: u32) ![]const Completion {
        if (!is_kqueue_os) return error.SystemOutdated;

        var count: u32 = 0;

        // First, drain any immediate completions (from sync file I/O).
        const imm = self.immediate_count;
        for (0..imm) |i| {
            if (count < max_completions) {
                self.completions_buf[count] = self.immediate_completions[i];
                count += 1;
            }
        }
        self.immediate_count = 0;

        // If we already have immediate completions and timeout is 0, skip kevent.
        // But if timeout > 0 and we have immediates, still return them without blocking.
        if (count > 0) {
            // Non-blocking check for any additional socket events.
            const zero_ts: posix.timespec = .{ .sec = 0, .nsec = 0 };
            const n = self.keventCall(0, &zero_ts);
            count = self.translateKevents(n, count);
            return self.completions_buf[0..count];
        }

        // No immediate completions — call kevent with the requested timeout.
        if (timeout_ms == 0) {
            const zero_ts: posix.timespec = .{ .sec = 0, .nsec = 0 };
            const n = self.keventCall(0, &zero_ts);
            count = self.translateKevents(n, count);
        } else {
            const ts: posix.timespec = .{
                .sec = @intCast(timeout_ms / 1000),
                .nsec = @intCast((@as(u64, timeout_ms) % 1000) * 1_000_000),
            };
            const n = self.keventCall(0, &ts);
            count = self.translateKevents(n, count);
        }

        return self.completions_buf[0..count];
    }

    // ------------------------------------------------------------------
    // Internal helpers
    // ------------------------------------------------------------------

    /// Pending operation tracking — needed for recv/send where we must
    /// remember the buffer to use when the socket becomes ready.
    const PendingOp = struct {
        fd: posix.fd_t,
        userdata: u64,
        op: OpType,
        buffer: [*]u8,
        buffer_len: usize,
        active: bool = true,
    };

    /// Simple fixed-size pending operations array.
    var pending_ops: [max_completions]PendingOp = undefined;
    var pending_ops_count: u32 = 0;
    var pending_ops_initialized: bool = false;

    fn ensurePendingOpsInit() void {
        if (!pending_ops_initialized) {
            for (0..max_completions) |i| {
                pending_ops[i].active = false;
            }
            pending_ops_initialized = true;
        }
    }

    fn addPendingOp(self: *KqueuePoll, op: PendingOp) !void {
        _ = self;
        ensurePendingOpsInit();

        // Find a free slot.
        for (0..max_completions) |i| {
            if (!pending_ops[i].active) {
                pending_ops[i] = op;
                pending_ops_count += 1;
                return;
            }
        }
        return error.SystemResources;
    }

    fn findPendingOp(userdata: u64) ?*PendingOp {
        ensurePendingOpsInit();
        for (0..max_completions) |i| {
            if (pending_ops[i].active and pending_ops[i].userdata == userdata) {
                return &pending_ops[i];
            }
        }
        return null;
    }

    /// The filter field type differs across BSDs (i16 on macOS/FreeBSD, i32 on NetBSD).
    const FilterType = if (is_kqueue_os) std.meta.fieldInfo(Kevent, .filter).type else i16;

    /// Register a kqueue filter on a file descriptor.
    fn registerFilter(self: *KqueuePoll, fd: posix.fd_t, filter: FilterType, userdata: u64) !void {
        var changelist: [1]Kevent = .{.{
            .ident = @intCast(fd),
            .filter = filter,
            .flags = c.EV.ADD | c.EV.ONESHOT,
            .fflags = 0,
            .data = 0,
            .udata = userdata,
        }};

        var empty: [0]Kevent = undefined;
        const zero_ts: posix.timespec = .{ .sec = 0, .nsec = 0 };
        const rc = system.kevent(
            self.kq_fd,
            &changelist,
            1,
            &empty,
            0,
            &zero_ts,
        );

        if (rc == -1) {
            return error.SystemResources;
        }
    }

    /// Call kevent() to wait for events.
    fn keventCall(self: *KqueuePoll, wait_nr: u32, timeout: *const posix.timespec) u32 {
        _ = wait_nr;
        var empty_changelist: [0]Kevent = undefined;
        const rc = system.kevent(
            self.kq_fd,
            &empty_changelist,
            0,
            &self.events_buf,
            max_completions,
            timeout,
        );

        if (rc < 0) {
            return 0;
        }
        return @intCast(rc);
    }

    /// Translate raw kevent results into Completion values.
    /// Also performs the actual recv/send for socket operations.
    fn translateKevents(self: *KqueuePoll, event_count: u32, start_idx: u32) u32 {
        var count = start_idx;
        for (0..event_count) |i| {
            if (count >= max_completions) break;

            const ev = self.events_buf[i];
            const userdata: u64 = ev.udata;
            const op_type = opTypeFromUserdata(userdata);

            // Check for errors reported by kqueue.
            if (ev.flags & c.EV.ERROR != 0) {
                self.completions_buf[count] = .{
                    .userdata = userdata,
                    .result = -@as(i32, @intCast(ev.data)),
                    .op_type = op_type,
                };
                count += 1;
                continue;
            }

            // For recv/send operations, we need to actually perform the I/O.
            if (findPendingOp(userdata)) |pending| {
                const result: i32 = switch (pending.op) {
                    .recv => blk: {
                        const rc = system.recvfrom(
                            pending.fd,
                            pending.buffer,
                            pending.buffer_len,
                            0,
                            null,
                            null,
                        );
                        pending.active = false;
                        pending_ops_count -= 1;
                        break :blk if (rc >= 0)
                            @intCast(rc)
                        else
                            -@as(i32, @intCast(@intFromEnum(posix.errno(rc))));
                    },
                    .send => blk: {
                        const rc = system.sendto(
                            pending.fd,
                            pending.buffer,
                            pending.buffer_len,
                            0,
                            null,
                            0,
                        );
                        pending.active = false;
                        pending_ops_count -= 1;
                        break :blk if (rc >= 0)
                            @intCast(rc)
                        else
                            -@as(i32, @intCast(@intFromEnum(posix.errno(rc))));
                    },
                    else => 0,
                };

                self.completions_buf[count] = .{
                    .userdata = userdata,
                    .result = result,
                    .op_type = pending.op,
                };
                count += 1;
            } else {
                // Connect completion or other event without a pending op.
                self.completions_buf[count] = .{
                    .userdata = userdata,
                    .result = 0,
                    .op_type = op_type,
                };
                count += 1;
            }
        }
        return count;
    }

    /// Derive the `OpType` from a userdata convention.
    ///
    /// We encode the op type in the upper 8 bits of the userdata so that
    /// the completion path can reconstruct which operation finished.
    /// The remaining 56 bits are available to the caller for context.
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
    /// 64-bit userdata value. The op type occupies the top 8 bits.
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

/// Helper: create a KqueuePoll, skipping the test on non-kqueue platforms.
fn initTestKqueue() !KqueuePoll {
    if (!is_kqueue_os) return error.SkipZigTest;
    return KqueuePoll.init() catch |err| switch (err) {
        error.SystemOutdated => return error.SkipZigTest,
        else => return err,
    };
}

// 1. Init / deinit — create kqueue, destroy it, no leaks.
test "KqueuePoll: init and deinit" {
    var p = try initTestKqueue();
    defer p.deinit();
}

// 2. File read — write known content with std, then submitRead + poll.
test "KqueuePoll: file read" {
    var p = try initTestKqueue();
    defer p.deinit();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const content = "hello kqueue";
    const file = try tmp.dir.createFile("read_test", .{ .read = true, .truncate = true });
    defer file.close();
    try file.writeAll(content);

    var buf: [64]u8 = undefined;
    const userdata = KqueuePoll.encodeUserdata(.read, 0xAB);
    try p.submitRead(file.handle, &buf, 0, userdata);

    const completions = try p.poll(1000);
    try testing.expect(completions.len >= 1);

    const comp = completions[0];
    // Check result is the number of bytes read.
    try testing.expectEqual(@as(i32, @intCast(content.len)), comp.result);
    // Check op type came back correctly.
    try testing.expectEqual(OpType.read, comp.op_type);
    // Check userdata round-tripped.
    try testing.expectEqual(userdata, comp.userdata);
    // Check actual bytes.
    try testing.expectEqualSlices(u8, content, buf[0..@intCast(comp.result)]);
}

// 3. File write + read round-trip.
test "KqueuePoll: file write then read" {
    var p = try initTestKqueue();
    defer p.deinit();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const file = try tmp.dir.createFile("write_read_test", .{ .read = true, .truncate = true });
    defer file.close();

    const payload = "round-trip test data!";
    const write_ud = KqueuePoll.encodeUserdata(.write, 1);
    try p.submitWrite(file.handle, payload, 0, write_ud);

    const wc = try p.poll(1000);
    try testing.expect(wc.len >= 1);
    try testing.expectEqual(@as(i32, @intCast(payload.len)), wc[0].result);
    try testing.expectEqual(OpType.write, wc[0].op_type);

    // Now read back.
    var buf: [64]u8 = undefined;
    const read_ud = KqueuePoll.encodeUserdata(.read, 2);
    try p.submitRead(file.handle, &buf, 0, read_ud);

    const rc = try p.poll(1000);
    try testing.expect(rc.len >= 1);
    try testing.expectEqual(@as(i32, @intCast(payload.len)), rc[0].result);
    try testing.expectEqualSlices(u8, payload, buf[0..@intCast(rc[0].result)]);
}

// 4. Multiple concurrent reads.
test "KqueuePoll: multiple concurrent reads" {
    var p = try initTestKqueue();
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

    // Submit all 3 reads.
    var bufs: [3][32]u8 = undefined;
    for (0..3) |i| {
        const ud = KqueuePoll.encodeUserdata(.read, @intCast(i));
        try p.submitRead(files[i].handle, &bufs[i], 0, ud);
    }

    // Collect all 3 completions (they are immediate for file I/O).
    const cs = try p.poll(1000);
    try testing.expect(cs.len >= 3);

    var seen: [3]bool = .{ false, false, false };
    for (cs[0..3]) |comp| {
        const decoded = KqueuePoll.decodeUserdata(comp.userdata);
        const idx: usize = @intCast(decoded.context);
        try testing.expect(idx < 3);
        try testing.expect(!seen[idx]);
        seen[idx] = true;
        try testing.expectEqual(@as(i32, @intCast(contents[idx].len)), comp.result);
        try testing.expectEqualSlices(u8, contents[idx], bufs[idx][0..@intCast(comp.result)]);
    }

    for (seen) |s| try testing.expect(s);
}

// 5. Non-blocking poll when no ops are pending returns empty slice.
test "KqueuePoll: non-blocking poll returns empty" {
    var p = try initTestKqueue();
    defer p.deinit();

    const completions = try p.poll(0);
    try testing.expectEqual(@as(usize, 0), completions.len);
}

// 6. Userdata round-trip: submit with specific userdata, verify on completion.
test "KqueuePoll: userdata round-trip" {
    var p = try initTestKqueue();
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

// 7. Encode / decode userdata helpers.
test "KqueuePoll: encode and decode userdata" {
    const ctx: u56 = 0x00_1234_5678_9ABC;
    const encoded = KqueuePoll.encodeUserdata(.send, ctx);
    const decoded = KqueuePoll.decodeUserdata(encoded);
    try testing.expectEqual(OpType.send, decoded.op);
    try testing.expectEqual(ctx, decoded.context);
}
