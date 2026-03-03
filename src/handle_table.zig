const std = @import("std");

// ---- Public types ----------------------------------------------------------

pub const HandleType = enum {
    adapter,
    device,
    queue,
    buffer,
    texture,
    texture_view,
    sampler,
    shader_module,
    bind_group_layout,
    bind_group,
    pipeline_layout,
    render_pipeline,
    compute_pipeline,
    command_encoder,
    render_pass_encoder,
    compute_pass_encoder,
    command_buffer,
    query_set,
};

/// Placeholder tagged union — the real Dawn opaque pointers will be filled in
/// once we integrate zgpu.
pub const DawnHandle = union(HandleType) {
    adapter: void,
    device: void,
    queue: void,
    buffer: void,
    texture: void,
    texture_view: void,
    sampler: void,
    shader_module: void,
    bind_group_layout: void,
    bind_group: void,
    pipeline_layout: void,
    render_pipeline: void,
    compute_pipeline: void,
    command_encoder: void,
    render_pass_encoder: void,
    compute_pass_encoder: void,
    command_buffer: void,
    query_set: void,
};

pub const HandleId = struct {
    index: u32,
    generation: u16,
};

pub const HandleEntry = struct {
    handle: DawnHandle,
    handle_type: HandleType,
    generation: u16,
    alive: bool,
    destroyed: bool,
    next_free: ?u32,
};

pub const HandleError = error{
    InvalidIndex,
    StaleGeneration,
    HandleNotAlive,
    HandleAlreadyDestroyed,
    OutOfHandles,
};

// ---- HandleTable -----------------------------------------------------------

pub const HandleTable = struct {
    entries: []HandleEntry,
    free_head: ?u32,
    count: u32,
    capacity: u32,

    pub const default_capacity: u32 = 65536;

    /// Create a new handle table with `capacity` slots, all initially free.
    pub fn init(allocator: std.mem.Allocator, capacity: u32) !HandleTable {
        const entries = try allocator.alloc(HandleEntry, capacity);

        // Build the intrusive free list: 0 -> 1 -> 2 -> ... -> (capacity-1) -> null
        for (entries, 0..) |*entry, i| {
            entry.* = .{
                .handle = .{ .adapter = {} },
                .handle_type = .adapter,
                .generation = 0,
                .alive = false,
                .destroyed = false,
                .next_free = if (i + 1 < capacity) @intCast(i + 1) else null,
            };
        }

        return .{
            .entries = entries,
            .free_head = if (capacity > 0) 0 else null,
            .count = 0,
            .capacity = capacity,
        };
    }

    /// Release the backing memory.
    pub fn deinit(self: *HandleTable, allocator: std.mem.Allocator) void {
        allocator.free(self.entries);
        self.* = undefined;
    }

    /// Allocate a new slot, store `handle`, and return a HandleId that can be
    /// used to retrieve it later.
    pub fn alloc(self: *HandleTable, handle: DawnHandle) HandleError!HandleId {
        const idx = self.free_head orelse return HandleError.OutOfHandles;
        const entry = &self.entries[idx];

        // Pop from free list.
        self.free_head = entry.next_free;

        entry.* = .{
            .handle = handle,
            .handle_type = handle,
            .generation = entry.generation, // keep the current generation
            .alive = true,
            .destroyed = false,
            .next_free = null,
        };

        self.count += 1;

        return .{
            .index = idx,
            .generation = entry.generation,
        };
    }

    /// Look up a live entry by its HandleId.  Returns a pointer to the entry so
    /// callers can read or mutate the stored DawnHandle.
    pub fn get(self: *const HandleTable, id: HandleId) HandleError!*HandleEntry {
        if (id.index >= self.capacity) return HandleError.InvalidIndex;

        const entry = &self.entries[id.index];

        if (id.generation != entry.generation) return HandleError.StaleGeneration;
        if (!entry.alive) return HandleError.HandleNotAlive;

        return entry;
    }

    /// Release a slot back to the free list.  The generation is bumped so that
    /// any outstanding HandleIds referring to this slot become stale.
    pub fn free(self: *HandleTable, id: HandleId) HandleError!void {
        if (id.index >= self.capacity) return HandleError.InvalidIndex;

        const entry = &self.entries[id.index];

        if (id.generation != entry.generation) return HandleError.StaleGeneration;
        if (!entry.alive) return HandleError.HandleNotAlive;

        // Bump generation for ABA protection.
        entry.generation +%= 1;
        entry.alive = false;
        entry.destroyed = false;

        // Push onto free list head (LIFO).
        entry.next_free = self.free_head;
        self.free_head = id.index;

        self.count -= 1;
    }

    /// Mark a handle as explicitly destroyed (e.g. from JS `.destroy()`).
    /// The slot stays alive so that subsequent accesses can distinguish
    /// "destroyed" from "freed / stale".
    pub fn destroy(self: *HandleTable, id: HandleId) HandleError!void {
        if (id.index >= self.capacity) return HandleError.InvalidIndex;

        const entry = &self.entries[id.index];

        if (id.generation != entry.generation) return HandleError.StaleGeneration;
        if (!entry.alive) return HandleError.HandleNotAlive;
        if (entry.destroyed) return HandleError.HandleAlreadyDestroyed;

        entry.destroyed = true;
    }

    /// Check whether `id` refers to a currently live entry.
    pub fn isValid(self: *const HandleTable, id: HandleId) bool {
        if (id.index >= self.capacity) return false;
        const entry = &self.entries[id.index];
        return entry.alive and id.generation == entry.generation;
    }

    /// Number of currently live (allocated) handles.
    pub fn activeCount(self: *const HandleTable) u32 {
        return self.count;
    }
};

// ---- Tests -----------------------------------------------------------------

const testing = std.testing;

// 1. Alloc + get round-trip
test "alloc and get round-trip" {
    var table = try HandleTable.init(testing.allocator, 8);
    defer table.deinit(testing.allocator);

    const id = try table.alloc(.{ .device = {} });
    const entry = try table.get(id);

    try testing.expectEqual(HandleType.device, entry.handle_type);
    try testing.expect(entry.alive);
    try testing.expect(!entry.destroyed);
}

// 2. Free + realloc: same slot, new generation
test "free and realloc reuses slot with bumped generation" {
    var table = try HandleTable.init(testing.allocator, 8);
    defer table.deinit(testing.allocator);

    const id1 = try table.alloc(.{ .buffer = {} });
    const gen1 = id1.generation;
    const idx1 = id1.index;

    try table.free(id1);

    const id2 = try table.alloc(.{ .texture = {} });

    // LIFO free list: should get the same slot back.
    try testing.expectEqual(idx1, id2.index);
    // Generation must have been bumped.
    try testing.expectEqual(gen1 +% 1, id2.generation);

    const entry = try table.get(id2);
    try testing.expectEqual(HandleType.texture, entry.handle_type);
}

// 3. Stale handle detection
test "stale handle returns StaleGeneration" {
    var table = try HandleTable.init(testing.allocator, 8);
    defer table.deinit(testing.allocator);

    const id = try table.alloc(.{ .adapter = {} });
    try table.free(id);

    // Re-allocate so the slot is alive again but with a new generation.
    _ = try table.alloc(.{ .queue = {} });

    const result = table.get(id);
    try testing.expectError(HandleError.StaleGeneration, result);
}

// 4. Double-free detection
test "double free returns HandleNotAlive" {
    var table = try HandleTable.init(testing.allocator, 8);
    defer table.deinit(testing.allocator);

    const id = try table.alloc(.{ .sampler = {} });
    try table.free(id);

    // The generation was bumped on free, so the old id has a stale generation.
    const result = table.free(id);
    try testing.expectError(HandleError.StaleGeneration, result);
}

// 5. Destroy semantics: marks destroyed=true, handle still alive
test "destroy marks destroyed flag but keeps handle alive" {
    var table = try HandleTable.init(testing.allocator, 8);
    defer table.deinit(testing.allocator);

    const id = try table.alloc(.{ .shader_module = {} });
    try table.destroy(id);

    const entry = try table.get(id);
    try testing.expect(entry.destroyed);
    try testing.expect(entry.alive);
    try testing.expect(table.isValid(id));
}

// 6. Destroy then free
test "destroy then free releases slot" {
    var table = try HandleTable.init(testing.allocator, 8);
    defer table.deinit(testing.allocator);

    const id = try table.alloc(.{ .bind_group = {} });
    try testing.expectEqual(@as(u32, 1), table.activeCount());

    try table.destroy(id);
    try testing.expectEqual(@as(u32, 1), table.activeCount()); // still alive

    try table.free(id);
    try testing.expectEqual(@as(u32, 0), table.activeCount()); // now freed
    try testing.expect(!table.isValid(id));
}

// 7. Double-destroy
test "double destroy returns HandleAlreadyDestroyed" {
    var table = try HandleTable.init(testing.allocator, 8);
    defer table.deinit(testing.allocator);

    const id = try table.alloc(.{ .render_pipeline = {} });
    try table.destroy(id);

    const result = table.destroy(id);
    try testing.expectError(HandleError.HandleAlreadyDestroyed, result);
}

// 8. Capacity exhaustion
test "alloc beyond capacity returns OutOfHandles" {
    var table = try HandleTable.init(testing.allocator, 2);
    defer table.deinit(testing.allocator);

    _ = try table.alloc(.{ .adapter = {} });
    _ = try table.alloc(.{ .device = {} });

    const result = table.alloc(.{ .queue = {} });
    try testing.expectError(HandleError.OutOfHandles, result);
}

// 9. Multiple handles: alloc several, verify each get returns correct data
test "multiple handles are independent" {
    var table = try HandleTable.init(testing.allocator, 8);
    defer table.deinit(testing.allocator);

    const id_a = try table.alloc(.{ .adapter = {} });
    const id_b = try table.alloc(.{ .buffer = {} });
    const id_c = try table.alloc(.{ .command_encoder = {} });

    try testing.expectEqual(HandleType.adapter, (try table.get(id_a)).handle_type);
    try testing.expectEqual(HandleType.buffer, (try table.get(id_b)).handle_type);
    try testing.expectEqual(HandleType.command_encoder, (try table.get(id_c)).handle_type);
    try testing.expectEqual(@as(u32, 3), table.activeCount());
}

// 10. Free list ordering: alloc 3, free middle, alloc new -> gets middle slot
test "free list ordering returns most recently freed slot" {
    var table = try HandleTable.init(testing.allocator, 8);
    defer table.deinit(testing.allocator);

    const id0 = try table.alloc(.{ .adapter = {} });
    const id1 = try table.alloc(.{ .device = {} });
    const id2 = try table.alloc(.{ .queue = {} });
    _ = id0;
    _ = id2;

    // Free the middle slot.
    try table.free(id1);

    // Allocate — LIFO should return the middle slot (index 1).
    const id_new = try table.alloc(.{ .texture = {} });
    try testing.expectEqual(id1.index, id_new.index);
    try testing.expectEqual(id1.generation +% 1, id_new.generation);
}

// Extra: InvalidIndex error
test "get with out-of-range index returns InvalidIndex" {
    var table = try HandleTable.init(testing.allocator, 4);
    defer table.deinit(testing.allocator);

    const bad_id = HandleId{ .index = 999, .generation = 0 };
    try testing.expectError(HandleError.InvalidIndex, table.get(bad_id));
}

// Extra: isValid returns false for freed handle
test "isValid returns false after free" {
    var table = try HandleTable.init(testing.allocator, 4);
    defer table.deinit(testing.allocator);

    const id = try table.alloc(.{ .texture_view = {} });
    try testing.expect(table.isValid(id));

    try table.free(id);
    try testing.expect(!table.isValid(id));
}

// Extra: generation wraps around on u16 overflow
test "generation wraps around on overflow" {
    var table = try HandleTable.init(testing.allocator, 4);
    defer table.deinit(testing.allocator);

    // Artificially set generation close to max.
    table.entries[0].generation = std.math.maxInt(u16);

    const id = try table.alloc(.{ .adapter = {} });
    try testing.expectEqual(std.math.maxInt(u16), id.generation);

    try table.free(id);

    // Next alloc on same slot should have wrapped generation (0).
    const id2 = try table.alloc(.{ .adapter = {} });
    try testing.expectEqual(id.index, id2.index);
    try testing.expectEqual(@as(u16, 0), id2.generation);
}

// Extra: zero-capacity table
test "zero capacity table returns OutOfHandles immediately" {
    var table = try HandleTable.init(testing.allocator, 0);
    defer table.deinit(testing.allocator);

    try testing.expectEqual(@as(u32, 0), table.activeCount());
    try testing.expectError(HandleError.OutOfHandles, table.alloc(.{ .adapter = {} }));
}
