const std = @import("std");
const quickjs = @import("quickjs");
const Value = quickjs.Value;
const Context = quickjs.Context;
const c = quickjs.c;

/// Module-level pointer to the TimerQueue, set by `register`.
/// Required because QuickJS C callbacks don't carry userdata for simple functions.
var global_queue: ?*TimerQueue = null;

/// A single timer entry in the queue.
pub const Timer = struct {
    id: u32,
    fire_time_ns: i128,
    interval_ns: ?i128,
    callback: Value,
    cleared: bool,
};

/// Min-heap of Timer entries ordered by `fire_time_ns`.
pub const TimerQueue = struct {
    heap: std.PriorityQueue(Timer, void, compareTimers),
    next_id: u32,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) TimerQueue {
        return .{
            .heap = std.PriorityQueue(Timer, void, compareTimers).init(allocator, {}),
            .next_id = 1,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *TimerQueue, ctx: *Context) void {
        // Free all remaining callback values.
        while (self.heap.removeOrNull()) |timer| {
            timer.callback.deinit(ctx);
        }
        self.heap.deinit();
    }

    /// Adds a timer and returns its unique ID.
    pub fn addTimer(
        self: *TimerQueue,
        callback: Value,
        delay_ms: i64,
        interval: bool,
        ctx: *Context,
    ) !u32 {
        const id = self.next_id;
        self.next_id +%= 1;
        // Skip ID 0 — reserve it as a sentinel.
        if (self.next_id == 0) self.next_id = 1;

        const delay_ns: i128 = @as(i128, delay_ms) * 1_000_000;
        const now = std.time.nanoTimestamp();

        const duped_callback = callback.dup(ctx);

        try self.heap.add(.{
            .id = id,
            .fire_time_ns = now + delay_ns,
            .interval_ns = if (interval) delay_ns else null,
            .callback = duped_callback,
            .cleared = false,
        });

        return id;
    }

    /// Mark a timer as cleared by ID. It will be skipped and freed on next tick.
    pub fn clearTimer(self: *TimerQueue, id: u32) void {
        for (self.heap.items) |*item| {
            if (item.id == id) {
                item.cleared = true;
                return;
            }
        }
    }

    /// Process all timers whose fire time has arrived.
    /// Calls callbacks, re-inserts intervals, frees one-shots.
    pub fn tick(self: *TimerQueue, ctx: *Context) void {
        self.tickWithTime(ctx, std.time.nanoTimestamp());
    }

    /// Internal tick implementation that accepts a time parameter for testing.
    fn tickWithTime(self: *TimerQueue, ctx: *Context, now: i128) void {
        // Collect timers that are ready to fire into a temporary list
        // to avoid mutating the heap while iterating.
        var to_fire: std.ArrayListUnmanaged(Timer) = .empty;
        defer to_fire.deinit(self.allocator);

        while (self.heap.peek()) |top| {
            if (top.fire_time_ns > now) break;
            const timer = self.heap.remove();
            to_fire.append(self.allocator, timer) catch break;
        }

        // Fire collected timers.
        const global_this = ctx.getGlobalObject();
        defer global_this.deinit(ctx);

        for (to_fire.items) |timer| {
            if (timer.cleared) {
                // Free the callback and discard.
                timer.callback.deinit(ctx);
                continue;
            }

            // Call the callback with no arguments.
            const result = timer.callback.call(ctx, global_this, &.{});
            // Free the return value (we don't use it).
            result.deinit(ctx);

            if (timer.interval_ns) |interval| {
                // Re-insert interval timer with updated fire time.
                const duped = timer.callback.dup(ctx);
                self.heap.add(.{
                    .id = timer.id,
                    .fire_time_ns = timer.fire_time_ns + interval,
                    .interval_ns = timer.interval_ns,
                    .callback = duped,
                    .cleared = false,
                }) catch {};
                // Free the original ref (we duped a new one for the re-insert).
                timer.callback.deinit(ctx);
            } else {
                // One-shot: free the callback.
                timer.callback.deinit(ctx);
            }
        }
    }

    /// Returns the number of pending timers (including cleared ones not yet reaped).
    pub fn count(self: *const TimerQueue) usize {
        return self.heap.items.len;
    }

    fn compareTimers(_: void, a: Timer, b: Timer) std.math.Order {
        return std.math.order(a.fire_time_ns, b.fire_time_ns);
    }
};

// =============================================================================
// QuickJS Global Function Registration
// =============================================================================

/// Registers setTimeout, setInterval, clearTimeout, clearInterval as
/// global functions on the given QuickJS context.
pub fn register(ctx: *Context, queue: *TimerQueue) !void {
    global_queue = queue;

    const global = ctx.getGlobalObject();
    defer global.deinit(ctx);

    const set_timeout_fn = Value.initCFunction(ctx, &jsSetTimeout, "setTimeout", 2);
    global.setPropertyStr(ctx, "setTimeout", set_timeout_fn) catch return error.JSError;

    const set_interval_fn = Value.initCFunction(ctx, &jsSetInterval, "setInterval", 2);
    global.setPropertyStr(ctx, "setInterval", set_interval_fn) catch return error.JSError;

    const clear_timeout_fn = Value.initCFunction(ctx, &jsClearTimeout, "clearTimeout", 1);
    global.setPropertyStr(ctx, "clearTimeout", clear_timeout_fn) catch return error.JSError;

    const clear_interval_fn = Value.initCFunction(ctx, &jsClearInterval, "clearInterval", 1);
    global.setPropertyStr(ctx, "clearInterval", clear_interval_fn) catch return error.JSError;
}

/// setTimeout(callback, delay_ms) -> timer_id
fn jsSetTimeout(
    ctx_opt: ?*Context,
    _: Value,
    argv: []const c.JSValue,
) Value {
    return jsSetTimerImpl(ctx_opt, argv, false);
}

/// setInterval(callback, delay_ms) -> timer_id
fn jsSetInterval(
    ctx_opt: ?*Context,
    _: Value,
    argv: []const c.JSValue,
) Value {
    return jsSetTimerImpl(ctx_opt, argv, true);
}

/// Shared implementation for setTimeout/setInterval.
fn jsSetTimerImpl(
    ctx_opt: ?*Context,
    argv: []const c.JSValue,
    interval: bool,
) Value {
    const ctx = ctx_opt orelse return Value.undefined;
    const queue = global_queue orelse return Value.undefined;

    if (argv.len < 1) return Value.undefined;

    const callback: Value = @bitCast(argv[0]);

    // Verify argument is a function.
    if (!callback.isFunction(ctx)) return Value.undefined;

    // Parse delay_ms (default to 0).
    var delay_ms: i64 = 0;
    if (argv.len >= 2) {
        const delay_val: Value = @bitCast(argv[1]);
        const delay_f64 = delay_val.toFloat64(ctx) catch 0.0;
        // Clamp negative values to 0.
        if (delay_f64 > 0.0) {
            delay_ms = @intFromFloat(delay_f64);
        }
    }

    const id = queue.addTimer(callback, delay_ms, interval, ctx) catch {
        return Value.undefined;
    };

    return Value.initInt32(@intCast(id));
}

/// clearTimeout(id) — marks the timer as cleared
fn jsClearTimeout(
    ctx_opt: ?*Context,
    _: Value,
    argv: []const c.JSValue,
) Value {
    return jsClearTimerImpl(ctx_opt, argv);
}

/// clearInterval(id) — same as clearTimeout
fn jsClearInterval(
    ctx_opt: ?*Context,
    _: Value,
    argv: []const c.JSValue,
) Value {
    return jsClearTimerImpl(ctx_opt, argv);
}

/// Shared implementation for clearTimeout/clearInterval.
fn jsClearTimerImpl(
    ctx_opt: ?*Context,
    argv: []const c.JSValue,
) Value {
    const ctx = ctx_opt orelse return Value.undefined;
    const queue = global_queue orelse return Value.undefined;

    if (argv.len < 1) return Value.undefined;

    const id_val: Value = @bitCast(argv[0]);
    const id = id_val.toInt32(ctx) catch return Value.undefined;
    if (id <= 0) return Value.undefined;

    queue.clearTimer(@intCast(id));
    return Value.undefined;
}

// =============================================================================
// Tests
// =============================================================================

const JsEngine = @import("../js_engine.zig").JsEngine;
const testing = std.testing;

test "setTimeout fires callback" {
    var engine = try JsEngine.init(testing.allocator);
    defer engine.deinit();
    var queue = TimerQueue.init(testing.allocator);
    defer queue.deinit(engine.context);
    try register(engine.context, &queue);

    var r1 = try engine.eval("var fired = false; setTimeout(function() { fired = true; }, 0);", "<test>");
    r1.deinit();

    // Tick the queue — delay 0 means fire on next tick.
    queue.tick(engine.context);

    var r2 = try engine.eval("fired", "<test>");
    defer r2.deinit();
    try testing.expectEqual(@as(i32, 1), try r2.toInt32());
}

test "setTimeout fires only once" {
    var engine = try JsEngine.init(testing.allocator);
    defer engine.deinit();
    var queue = TimerQueue.init(testing.allocator);
    defer queue.deinit(engine.context);
    try register(engine.context, &queue);

    var r1 = try engine.eval("var count = 0; setTimeout(function() { count++; }, 0);", "<test>");
    r1.deinit();

    queue.tick(engine.context);
    queue.tick(engine.context);
    queue.tick(engine.context);

    var r2 = try engine.eval("count", "<test>");
    defer r2.deinit();
    try testing.expectEqual(@as(i32, 1), try r2.toInt32());
}

test "setInterval fires repeatedly" {
    var engine = try JsEngine.init(testing.allocator);
    defer engine.deinit();
    var queue = TimerQueue.init(testing.allocator);
    defer queue.deinit(engine.context);
    try register(engine.context, &queue);

    var r1 = try engine.eval("var count = 0; setInterval(function() { count++; }, 0);", "<test>");
    r1.deinit();

    queue.tick(engine.context);
    queue.tick(engine.context);
    queue.tick(engine.context);

    var r2 = try engine.eval("count", "<test>");
    defer r2.deinit();
    // Should have fired at least 3 times (once per tick with delay 0).
    try testing.expect((try r2.toInt32()) >= 3);
}

test "clearTimeout prevents firing" {
    var engine = try JsEngine.init(testing.allocator);
    defer engine.deinit();
    var queue = TimerQueue.init(testing.allocator);
    defer queue.deinit(engine.context);
    try register(engine.context, &queue);

    var r1 = try engine.eval(
        \\var fired = false;
        \\var id = setTimeout(function() { fired = true; }, 0);
        \\clearTimeout(id);
    , "<test>");
    r1.deinit();

    queue.tick(engine.context);

    var r2 = try engine.eval("fired", "<test>");
    defer r2.deinit();
    // fired should still be false.
    try testing.expectEqual(@as(i32, 0), try r2.toInt32());
}

test "clearInterval stops interval" {
    var engine = try JsEngine.init(testing.allocator);
    defer engine.deinit();
    var queue = TimerQueue.init(testing.allocator);
    defer queue.deinit(engine.context);
    try register(engine.context, &queue);

    var r1 = try engine.eval(
        \\var count = 0;
        \\var id = setInterval(function() { count++; }, 0);
    , "<test>");
    r1.deinit();

    // Fire once.
    queue.tick(engine.context);

    var r_clear = try engine.eval("clearInterval(id);", "<test>");
    r_clear.deinit();

    // Tick again — should not fire.
    queue.tick(engine.context);
    queue.tick(engine.context);

    var r2 = try engine.eval("count", "<test>");
    defer r2.deinit();
    try testing.expectEqual(@as(i32, 1), try r2.toInt32());
}

test "delay 0 fires on next tick, not immediately" {
    var engine = try JsEngine.init(testing.allocator);
    defer engine.deinit();
    var queue = TimerQueue.init(testing.allocator);
    defer queue.deinit(engine.context);
    try register(engine.context, &queue);

    // Set timer and check fired immediately — should be false before tick.
    var r1 = try engine.eval(
        \\var fired = false;
        \\setTimeout(function() { fired = true; }, 0);
        \\fired
    , "<test>");
    defer r1.deinit();
    try testing.expectEqual(@as(i32, 0), try r1.toInt32());

    // Now tick — should fire.
    queue.tick(engine.context);

    var r2 = try engine.eval("fired", "<test>");
    defer r2.deinit();
    try testing.expectEqual(@as(i32, 1), try r2.toInt32());
}

test "setTimeout returns unique integer IDs" {
    var engine = try JsEngine.init(testing.allocator);
    defer engine.deinit();
    var queue = TimerQueue.init(testing.allocator);
    defer queue.deinit(engine.context);
    try register(engine.context, &queue);

    var r1 = try engine.eval(
        \\var id1 = setTimeout(function(){}, 100);
        \\var id2 = setTimeout(function(){}, 100);
        \\var id3 = setTimeout(function(){}, 100);
        \\(id1 !== id2 && id2 !== id3 && id1 !== id3 &&
        \\ typeof id1 === 'number' && typeof id2 === 'number')
    , "<test>");
    defer r1.deinit();
    try testing.expectEqual(@as(i32, 1), try r1.toInt32());
}

test "queue orders by fire time" {
    var engine = try JsEngine.init(testing.allocator);
    defer engine.deinit();
    var queue = TimerQueue.init(testing.allocator);
    defer queue.deinit(engine.context);
    try register(engine.context, &queue);

    // Set timers with different delays — the one with delay 0 should fire first.
    var r1 = try engine.eval(
        \\var order = [];
        \\setTimeout(function() { order.push('c'); }, 200);
        \\setTimeout(function() { order.push('a'); }, 0);
        \\setTimeout(function() { order.push('b'); }, 100);
    , "<test>");
    r1.deinit();

    // Tick three times to fire all (with real time, the 0-delay should fire first).
    queue.tick(engine.context);

    var r2 = try engine.eval("order[0]", "<test>");
    defer r2.deinit();
    const s = try r2.toCString();
    defer r2.freeCString(s);
    try testing.expectEqualStrings("a", s);
}

test "timer functions exist as globals" {
    var engine = try JsEngine.init(testing.allocator);
    defer engine.deinit();
    var queue = TimerQueue.init(testing.allocator);
    defer queue.deinit(engine.context);
    try register(engine.context, &queue);

    var r = try engine.eval(
        \\typeof setTimeout === 'function' &&
        \\typeof setInterval === 'function' &&
        \\typeof clearTimeout === 'function' &&
        \\typeof clearInterval === 'function'
    , "<test>");
    defer r.deinit();
    try testing.expectEqual(@as(i32, 1), try r.toInt32());
}

test "TimerQueue.count tracks pending timers" {
    var engine = try JsEngine.init(testing.allocator);
    defer engine.deinit();
    var queue = TimerQueue.init(testing.allocator);
    defer queue.deinit(engine.context);
    try register(engine.context, &queue);

    try testing.expectEqual(@as(usize, 0), queue.count());

    var r1 = try engine.eval("setTimeout(function(){}, 0);", "<test>");
    r1.deinit();
    try testing.expectEqual(@as(usize, 1), queue.count());

    var r2 = try engine.eval("setTimeout(function(){}, 0);", "<test>");
    r2.deinit();
    try testing.expectEqual(@as(usize, 2), queue.count());

    // Tick should drain both (one-shot timers with delay 0).
    queue.tick(engine.context);
    try testing.expectEqual(@as(usize, 0), queue.count());
}
