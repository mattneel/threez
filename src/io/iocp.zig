const std = @import("std");
const builtin = @import("builtin");
const poll = @import("poll.zig");
const Completion = poll.Completion;
const OpType = poll.OpType;

/// Windows IOCP-backed async I/O poller.
///
/// Wraps the Windows I/O Completion Port API and translates completions
/// into the platform-agnostic `Completion` type used by the rest of threez.
///
/// IOCP supports true async I/O for both files and sockets, making it the
/// most capable backend across all platforms.
pub const IocpPoll = struct {
    iocp_handle: windows.HANDLE,
    /// Pool of OverlappedExtra wrappers for in-flight operations.
    overlapped_pool: []OverlappedExtra,
    /// Free-list indices: stack of available pool slots.
    free_list: []u32,
    /// Number of currently free slots (top of stack).
    free_count: u32,
    /// Raw OVERLAPPED_ENTRY buffer for GetQueuedCompletionStatusEx.
    entries_buf: [max_completions]windows.OVERLAPPED_ENTRY = undefined,
    /// Translated completions returned to the caller of `poll`.
    completions_buf: [max_completions]Completion = undefined,

    allocator: std.mem.Allocator,

    const windows = std.os.windows;
    const kernel32 = windows.kernel32;
    const ws2_32 = windows.ws2_32;

    const max_completions = 256;
    const pool_size: u32 = 256;

    /// Extended OVERLAPPED that carries the operation type and caller userdata.
    ///
    /// Because IOCP returns a pointer to the OVERLAPPED that was submitted, we
    /// embed the OVERLAPPED as the first field so we can recover the wrapper
    /// via `@fieldParentPtr`.
    pub const OverlappedExtra = struct {
        overlapped: windows.OVERLAPPED,
        op_type: OpType,
        userdata: u64,
        /// Index into the pool so we can return it to the free-list.
        pool_index: u32,
        /// WSABUF for socket operations (WSARecv/WSASend need a pointer that
        /// outlives the call).
        wsabuf: ws2_32.WSABUF,
        /// Storage for WSARecv flags (must be valid for the duration of the I/O).
        recv_flags: u32,

        /// Recover the `OverlappedExtra` from a raw `*OVERLAPPED` pointer
        /// returned by the completion port.
        pub fn fromOverlapped(ov: *windows.OVERLAPPED) *OverlappedExtra {
            return @fieldParentPtr("overlapped", ov);
        }
    };

    /// Initialise the IOCP poller.
    ///
    /// Creates the I/O Completion Port and allocates the OVERLAPPED pool.
    pub fn init(allocator: std.mem.Allocator) !IocpPoll {
        // Create a new I/O Completion Port (not associated with a file yet).
        // Passing INVALID_HANDLE_VALUE with null existing port creates a new port.
        const iocp = try windows.CreateIoCompletionPort(
            windows.INVALID_HANDLE_VALUE,
            null,
            0,
            0,
        );

        // Allocate the OVERLAPPED pool.
        const overlapped_pool = try allocator.alloc(OverlappedExtra, pool_size);
        const free_list = try allocator.alloc(u32, pool_size);

        // Initialize the pool entries and free-list.
        for (0..pool_size) |i| {
            overlapped_pool[i] = std.mem.zeroes(OverlappedExtra);
            overlapped_pool[i].pool_index = @intCast(i);
            free_list[i] = @intCast(i);
        }

        var self: IocpPoll = .{
            .iocp_handle = iocp,
            .overlapped_pool = overlapped_pool,
            .free_list = free_list,
            .free_count = pool_size,
            .allocator = allocator,
        };

        // Zero-init the scratch buffers.
        @memset(std.mem.asBytes(&self.entries_buf), 0);
        @memset(std.mem.asBytes(&self.completions_buf), 0);

        return self;
    }

    /// Tear down the IOCP handle and free all pool memory.
    pub fn deinit(self: *IocpPoll) void {
        windows.CloseHandle(self.iocp_handle);
        self.allocator.free(self.overlapped_pool);
        self.allocator.free(self.free_list);
    }

    /// Associate a file or socket handle with this I/O Completion Port.
    ///
    /// Any handle used with submitRead/submitWrite must be associated first.
    /// Sockets used with submitRecv/submitSend/submitConnect must also be
    /// associated.  The completion key is set to 0; we use the OVERLAPPED
    /// pointer to identify operations instead.
    pub fn associate(self: *IocpPoll, handle: windows.HANDLE) !void {
        const associated = kernel32.CreateIoCompletionPort(handle, self.iocp_handle, 0, 0);
        if (associated == null) {
            const err = windows.GetLastError();
            switch (err) {
                .INVALID_PARAMETER => return error.InvalidIocpAssociation,
                else => return windows.unexpectedError(err),
            }
        }
    }

    // ------------------------------------------------------------------
    // Pool management
    // ------------------------------------------------------------------

    /// Acquire an OverlappedExtra from the pool, returning a pointer.
    fn acquireOverlapped(self: *IocpPoll) !*OverlappedExtra {
        if (self.free_count == 0) return error.OutOfOverlappedSlots;
        self.free_count -= 1;
        const idx = self.free_list[self.free_count];
        const ov = &self.overlapped_pool[idx];
        // Zero the OVERLAPPED portion for reuse.
        ov.overlapped = std.mem.zeroes(windows.OVERLAPPED);
        ov.recv_flags = 0;
        return ov;
    }

    /// Return an OverlappedExtra to the pool.
    fn releaseOverlapped(self: *IocpPoll, ov: *OverlappedExtra) void {
        self.free_list[self.free_count] = ov.pool_index;
        self.free_count += 1;
    }

    // ------------------------------------------------------------------
    // Submission helpers
    // ------------------------------------------------------------------

    /// Submit an async file read.
    ///
    /// `fd`       — file HANDLE to read from (must be opened with FILE_FLAG_OVERLAPPED)
    /// `buffer`   — destination buffer
    /// `offset`   — byte offset in the file
    /// `userdata` — opaque value returned in the `Completion`
    pub fn submitRead(
        self: *IocpPoll,
        fd: windows.HANDLE,
        buffer: []u8,
        offset: u64,
        userdata: u64,
    ) !void {
        const ov = try self.acquireOverlapped();
        ov.op_type = .read;
        ov.userdata = userdata;

        // Set the file offset in the OVERLAPPED structure.
        ov.overlapped.DUMMYUNIONNAME.DUMMYSTRUCTNAME.Offset = @as(u32, @truncate(offset));
        ov.overlapped.DUMMYUNIONNAME.DUMMYSTRUCTNAME.OffsetHigh = @as(u32, @truncate(offset >> 32));

        const want_read: windows.DWORD = @intCast(@min(buffer.len, std.math.maxInt(windows.DWORD)));
        if (kernel32.ReadFile(fd, buffer.ptr, want_read, null, &ov.overlapped) == 0) {
            const err = windows.GetLastError();
            switch (err) {
                .IO_PENDING => {}, // Expected for async I/O — completion will arrive on the port.
                else => {
                    self.releaseOverlapped(ov);
                    return windows.unexpectedError(err);
                },
            }
        }
        // If ReadFile returned TRUE, the completion is already queued to the port.
    }

    /// Submit an async file write.
    pub fn submitWrite(
        self: *IocpPoll,
        fd: windows.HANDLE,
        buffer: []const u8,
        offset: u64,
        userdata: u64,
    ) !void {
        const ov = try self.acquireOverlapped();
        ov.op_type = .write;
        ov.userdata = userdata;

        ov.overlapped.DUMMYUNIONNAME.DUMMYSTRUCTNAME.Offset = @as(u32, @truncate(offset));
        ov.overlapped.DUMMYUNIONNAME.DUMMYSTRUCTNAME.OffsetHigh = @as(u32, @truncate(offset >> 32));

        const adjusted_len: windows.DWORD = @intCast(@min(buffer.len, std.math.maxInt(windows.DWORD)));
        if (kernel32.WriteFile(fd, buffer.ptr, adjusted_len, null, &ov.overlapped) == 0) {
            const err = windows.GetLastError();
            switch (err) {
                .IO_PENDING => {},
                else => {
                    self.releaseOverlapped(ov);
                    return windows.unexpectedError(err);
                },
            }
        }
    }

    /// Submit an async socket connect via ConnectEx.
    ///
    /// Note: The socket must be bound before calling ConnectEx (Windows requirement).
    /// ConnectEx is obtained at runtime via WSAIoctl + SIO_GET_EXTENSION_FUNCTION_POINTER.
    pub fn submitConnect(
        self: *IocpPoll,
        socket: ws2_32.SOCKET,
        addr: *const ws2_32.sockaddr,
        addrlen: i32,
        userdata: u64,
    ) !void {
        const ov = try self.acquireOverlapped();
        ov.op_type = .connect;
        ov.userdata = userdata;

        // Obtain ConnectEx function pointer via WSAIoctl.
        const connectex_fn = try getConnectEx(socket);
        const result = connectex_fn(
            socket,
            addr,
            addrlen,
            null, // no send buffer with connect
            0, // send data length
            null, // bytes sent (not needed for async)
            &ov.overlapped,
        );

        if (result == 0) {
            const wsa_err = ws2_32.WSAGetLastError();
            switch (wsa_err) {
                .WSA_IO_PENDING => {}, // Expected — async connect in progress.
                else => {
                    self.releaseOverlapped(ov);
                    return windows.unexpectedError(@enumFromInt(@intFromEnum(wsa_err)));
                },
            }
        }
    }

    /// Submit an async socket recv.
    pub fn submitRecv(
        self: *IocpPoll,
        socket: windows.ws2_32.SOCKET,
        buffer: []u8,
        userdata: u64,
    ) !void {
        const ov = try self.acquireOverlapped();
        ov.op_type = .recv;
        ov.userdata = userdata;

        // Set up the WSABUF — we store it in the OverlappedExtra so it stays
        // valid for the entire async operation.
        ov.wsabuf = .{
            .len = @intCast(buffer.len),
            .buf = buffer.ptr,
        };
        ov.recv_flags = 0;

        const result = ws2_32.WSARecv(
            socket,
            @as([*]ws2_32.WSABUF, @ptrCast(&ov.wsabuf)),
            1, // buffer count
            null, // bytes received (not used for async)
            &ov.recv_flags,
            &ov.overlapped,
            null, // completion routine (we use IOCP instead)
        );

        if (result == ws2_32.SOCKET_ERROR) {
            const wsa_err = ws2_32.WSAGetLastError();
            switch (wsa_err) {
                .WSA_IO_PENDING => {},
                else => {
                    self.releaseOverlapped(ov);
                    return windows.unexpectedError(@enumFromInt(@intFromEnum(wsa_err)));
                },
            }
        }
    }

    /// Submit an async socket send.
    pub fn submitSend(
        self: *IocpPoll,
        socket: windows.ws2_32.SOCKET,
        buffer: []const u8,
        userdata: u64,
    ) !void {
        const ov = try self.acquireOverlapped();
        ov.op_type = .send;
        ov.userdata = userdata;

        ov.wsabuf = .{
            .len = @intCast(buffer.len),
            .buf = @constCast(buffer.ptr),
        };

        const result = ws2_32.WSASend(
            socket,
            @as([*]ws2_32.WSABUF, @ptrCast(&ov.wsabuf)),
            1,
            null, // bytes sent
            0, // flags
            &ov.overlapped,
            null,
        );

        if (result == ws2_32.SOCKET_ERROR) {
            const wsa_err = ws2_32.WSAGetLastError();
            switch (wsa_err) {
                .WSA_IO_PENDING => {},
                else => {
                    self.releaseOverlapped(ov);
                    return windows.unexpectedError(@enumFromInt(@intFromEnum(wsa_err)));
                },
            }
        }
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
    pub fn poll(self: *IocpPoll, timeout_ms: u32) ![]const Completion {
        const timeout: ?windows.DWORD = if (timeout_ms > 0) timeout_ms else 0;

        const count = windows.GetQueuedCompletionStatusEx(
            self.iocp_handle,
            &self.entries_buf,
            timeout,
            false, // not alertable
        ) catch |err| switch (err) {
            error.Timeout => return self.completions_buf[0..0],
            error.Aborted => return self.completions_buf[0..0],
            else => return err,
        };

        return self.translateCompletions(count);
    }

    /// Translate raw OVERLAPPED_ENTRY results into platform-agnostic `Completion` values.
    fn translateCompletions(self: *IocpPoll, count: u32) []const Completion {
        for (0..count) |i| {
            const entry = self.entries_buf[i];
            const ov_extra = OverlappedExtra.fromOverlapped(entry.lpOverlapped);

            // The result is the number of bytes transferred.  If the
            // Internal field of the OVERLAPPED indicates an error, we
            // translate the NTSTATUS to a negative errno-style value.
            const bytes: i32 = @intCast(entry.dwNumberOfBytesTransferred);
            const ntstatus: u32 = @intCast(ov_extra.overlapped.Internal);
            const result: i32 = if (ntstatus == 0) bytes else -mapNtStatusToErrno(ntstatus);

            self.completions_buf[i] = .{
                .userdata = ov_extra.userdata,
                .result = result,
                .op_type = ov_extra.op_type,
            };

            // Return the OVERLAPPED slot to the pool.
            self.releaseOverlapped(ov_extra);
        }
        return self.completions_buf[0..count];
    }

    /// Map an NTSTATUS code to a POSIX-style errno value.
    /// Only the most common I/O error codes are covered; others become EIO.
    fn mapNtStatusToErrno(ntstatus: u32) i32 {
        return switch (ntstatus) {
            0x00000000 => 0, // STATUS_SUCCESS
            0xC0000008 => 22, // STATUS_INVALID_HANDLE → EINVAL
            0xC0000005 => 14, // STATUS_ACCESS_VIOLATION → EFAULT
            0xC000000F => 2, // STATUS_NO_SUCH_FILE → ENOENT
            0xC0000034 => 2, // STATUS_OBJECT_NAME_NOT_FOUND → ENOENT
            0xC00000BA => 24, // STATUS_FILE_IS_A_DIRECTORY → EISDIR
            0xC0000022 => 13, // STATUS_ACCESS_DENIED → EACCES
            0xC000009A => 12, // STATUS_INSUFFICIENT_RESOURCES → ENOMEM
            0xC0000120 => 89, // STATUS_CANCELLED → ECANCELED (Linux)
            0xC00000B5 => 5, // STATUS_IO_TIMEOUT → EIO
            0xC000020C => 104, // STATUS_CONNECTION_DISCONNECTED → ECONNRESET
            0xC0000236 => 111, // STATUS_CONNECTION_REFUSED → ECONNREFUSED
            0xC0000241 => 113, // STATUS_CONNECTION_ABORTED → (mapped to generic)
            else => 5, // EIO — generic I/O error
        };
    }

    // ------------------------------------------------------------------
    // ConnectEx loader
    // ------------------------------------------------------------------

    /// ConnectEx function pointer type (Windows extension function).
    const LPFN_CONNECTEX = *const fn (
        s: ws2_32.SOCKET,
        name: *const ws2_32.sockaddr,
        namelen: i32,
        lpSendBuffer: ?*const anyopaque,
        dwSendDataLength: windows.DWORD,
        lpdwBytesSent: ?*windows.DWORD,
        lpOverlapped: *windows.OVERLAPPED,
    ) callconv(.winapi) windows.BOOL;

    /// Obtain the ConnectEx function pointer for a given socket via WSAIoctl.
    fn getConnectEx(socket: ws2_32.SOCKET) !LPFN_CONNECTEX {
        var connectex_fn: LPFN_CONNECTEX = undefined;
        var bytes_returned: windows.DWORD = 0;
        var guid = ws2_32.WSAID_CONNECTEX;

        // Use the raw ws2_32 extern directly — the Zig wrapper uses slice
        // types that are less convenient for this particular call.
        const result = ws2_32.WSAIoctl(
            socket,
            @as(u32, @intCast(ws2_32.SIO_GET_EXTENSION_FUNCTION_POINTER)),
            @as(?*const anyopaque, @ptrCast(&guid)),
            @sizeOf(@TypeOf(guid)),
            @as(?*anyopaque, @ptrCast(&connectex_fn)),
            @sizeOf(@TypeOf(connectex_fn)),
            &bytes_returned,
            null,
            null,
        );

        if (result == ws2_32.SOCKET_ERROR) {
            return error.ConnectExNotAvailable;
        }

        return connectex_fn;
    }

    // ------------------------------------------------------------------
    // Userdata encoding helpers
    // ------------------------------------------------------------------

    /// Encode an `OpType` tag and a caller-supplied context into a single
    /// 64-bit userdata value.  The op type occupies the top 8 bits.
    ///
    /// This matches the encoding used by `IoUringPoll` so that callers can
    /// use the same convention across backends.
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

// Tests are guarded by a comptime OS check.  On non-Windows platforms they
// compile (ensuring the module is syntactically valid) but immediately skip.

/// Helper: create an IocpPoll, skipping the test when not on Windows.
fn initTestPoller() !IocpPoll {
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;
    return IocpPoll.init(testing.allocator);
}

/// Open a temporary test file with FILE_FLAG_OVERLAPPED so it can be used
/// with IOCP file I/O.
fn openOverlappedTmpFile(tmp: *testing.TmpDir, name: []const u8, creation: std.os.windows.DWORD) !std.os.windows.HANDLE {
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;
    const windows = std.os.windows;
    const kernel32 = windows.kernel32;

    const rel_path = try std.fs.path.join(testing.allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..], name });
    defer testing.allocator.free(rel_path);

    const cwd_path = try std.process.getCwdAlloc(testing.allocator);
    defer testing.allocator.free(cwd_path);

    const abs_path = try std.fs.path.join(testing.allocator, &.{ cwd_path, rel_path });
    defer testing.allocator.free(abs_path);

    const path_w = try std.unicode.wtf8ToWtf16LeAllocZ(testing.allocator, abs_path);
    defer testing.allocator.free(path_w);

    const handle = kernel32.CreateFileW(
        path_w.ptr,
        windows.GENERIC_READ | windows.GENERIC_WRITE,
        windows.FILE_SHARE_READ | windows.FILE_SHARE_WRITE | windows.FILE_SHARE_DELETE,
        null,
        creation,
        windows.FILE_ATTRIBUTE_NORMAL | windows.FILE_FLAG_OVERLAPPED,
        null,
    );
    if (handle == windows.INVALID_HANDLE_VALUE) {
        return windows.unexpectedError(windows.GetLastError());
    }
    return handle;
}

// 1. Init / deinit — create IOCP, destroy it, no leaks.
test "IocpPoll: init and deinit" {
    var p = try initTestPoller();
    defer p.deinit();
}

// 2. Non-blocking poll when no ops are pending returns empty slice.
test "IocpPoll: non-blocking poll returns empty" {
    var p = try initTestPoller();
    defer p.deinit();

    const completions = try p.poll(0);
    try testing.expectEqual(@as(usize, 0), completions.len);
}

// 3. Encode / decode userdata helpers.
test "IocpPoll: encode and decode userdata" {
    // This test runs on all platforms since it's pure computation.
    const ctx: u56 = 0x00_1234_5678_9ABC;
    const encoded = IocpPoll.encodeUserdata(.send, ctx);
    const decoded = IocpPoll.decodeUserdata(encoded);
    try testing.expectEqual(OpType.send, decoded.op);
    try testing.expectEqual(ctx, decoded.context);
}

// 4. All OpType values round-trip through encode/decode.
test "IocpPoll: all OpType values round-trip" {
    const ops = [_]OpType{ .read, .write, .connect, .recv, .send, .accept };
    for (ops) |op| {
        const encoded = IocpPoll.encodeUserdata(op, 42);
        const decoded = IocpPoll.decodeUserdata(encoded);
        try testing.expectEqual(op, decoded.op);
        try testing.expectEqual(@as(u56, 42), decoded.context);
    }
}

// 5. Pool exhaustion and recovery (Windows-only).
test "IocpPoll: pool acquire and release" {
    var p = try initTestPoller();
    defer p.deinit();

    // The pool should start fully free.
    try testing.expectEqual(@as(u32, IocpPoll.pool_size), p.free_count);

    // Acquire one slot.
    const ov = try p.acquireOverlapped();
    try testing.expectEqual(@as(u32, IocpPoll.pool_size - 1), p.free_count);

    // Return it.
    p.releaseOverlapped(ov);
    try testing.expectEqual(@as(u32, IocpPoll.pool_size), p.free_count);
}

// 6. File read via IOCP (Windows-only).
test "IocpPoll: file read" {
    var p = try initTestPoller();
    defer p.deinit();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const content = "hello iocp";
    const file = try tmp.dir.createFile("read_test", .{ .read = true, .truncate = true });
    try file.writeAll(content);
    file.close();

    const read_handle = try openOverlappedTmpFile(&tmp, "read_test", std.os.windows.OPEN_EXISTING);
    defer std.os.windows.CloseHandle(read_handle);

    // Associate the file handle with the IOCP.
    try p.associate(read_handle);

    var buf: [64]u8 = undefined;
    const userdata = IocpPoll.encodeUserdata(.read, 0xAB);
    try p.submitRead(read_handle, &buf, 0, userdata);

    const completions = try p.poll(1000);
    try testing.expect(completions.len >= 1);

    const c = completions[0];
    try testing.expectEqual(@as(i32, @intCast(content.len)), c.result);
    try testing.expectEqual(OpType.read, c.op_type);
    try testing.expectEqual(userdata, c.userdata);
    try testing.expectEqualSlices(u8, content, buf[0..@intCast(c.result)]);
}

// 7. File write then read round-trip (Windows-only).
test "IocpPoll: file write then read" {
    var p = try initTestPoller();
    defer p.deinit();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const file_handle = try openOverlappedTmpFile(&tmp, "write_read_test", std.os.windows.CREATE_ALWAYS);
    defer std.os.windows.CloseHandle(file_handle);

    try p.associate(file_handle);

    const payload = "round-trip test data!";
    const write_ud = IocpPoll.encodeUserdata(.write, 1);
    try p.submitWrite(file_handle, payload, 0, write_ud);

    const wc = try p.poll(1000);
    try testing.expect(wc.len >= 1);
    try testing.expectEqual(@as(i32, @intCast(payload.len)), wc[0].result);
    try testing.expectEqual(OpType.write, wc[0].op_type);

    // Now read back.
    var buf: [64]u8 = undefined;
    const read_ud = IocpPoll.encodeUserdata(.read, 2);
    try p.submitRead(file_handle, &buf, 0, read_ud);

    const rc = try p.poll(1000);
    try testing.expect(rc.len >= 1);
    try testing.expectEqual(@as(i32, @intCast(payload.len)), rc[0].result);
    try testing.expectEqualSlices(u8, payload, buf[0..@intCast(rc[0].result)]);
}

// 8. Userdata round-trip (Windows-only).
test "IocpPoll: userdata round-trip" {
    var p = try initTestPoller();
    defer p.deinit();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const file = try tmp.dir.createFile("ud_test", .{ .read = true, .truncate = true });
    try file.writeAll("x");
    file.close();

    const read_handle = try openOverlappedTmpFile(&tmp, "ud_test", std.os.windows.OPEN_EXISTING);
    defer std.os.windows.CloseHandle(read_handle);

    try p.associate(read_handle);

    const magic: u64 = 0xDEAD_BEEF_CAFE_0042;
    var buf: [8]u8 = undefined;
    try p.submitRead(read_handle, &buf, 0, magic);

    const completions = try p.poll(1000);
    try testing.expect(completions.len >= 1);
    try testing.expectEqual(magic, completions[0].userdata);
    try testing.expectEqual(@as(i32, 1), completions[0].result);
}
