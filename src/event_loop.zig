const std = @import("std");
const builtin = @import("builtin");
const quickjs = @import("quickjs");
const Value = quickjs.Value;
const Context = quickjs.Context;
const c = quickjs.c;

const JsEngine = @import("js_engine.zig").JsEngine;
const TimerQueue = @import("polyfills/timers.zig").TimerQueue;
const Window = @import("window.zig").Window;

const log = std.log.scoped(.event_loop);

/// Module-level pointer to the EventLoop, set by `register`.
/// Required because QuickJS C callbacks don't carry userdata for simple functions.
var global_loop: ?*EventLoop = null;

/// The main frame loop that Zig owns.
///
/// Each frame tick:
/// 1. Poll GLFW events (window input) — handled by caller via `run()`
/// 2. Fire expired timers (TimerQueue.tick)
/// 3. Drain QuickJS microtask/job queue
/// 4. Call requestAnimationFrame callbacks with monotonic timestamp
/// 5. Drain QuickJS microtask/job queue again (rAF may have queued promises)
pub const EventLoop = struct {
    engine: *JsEngine,
    timer_queue: *TimerQueue,
    allocator: std.mem.Allocator,
    raf_callbacks: std.ArrayList(RafEntry),
    frame_count: u64,
    start_time_ns: i128,
    running: bool,
    fail_fast: bool,
    fatal_error: bool,
    next_raf_id: u32,

    /// A single requestAnimationFrame entry.
    pub const RafEntry = struct {
        id: u32,
        callback: Value,
        cancelled: bool,
    };

    /// Initializes a new EventLoop.
    ///
    /// The EventLoop does not own the engine or timer_queue — the caller is
    /// responsible for their lifetimes.
    pub fn init(allocator: std.mem.Allocator, engine: *JsEngine, timer_queue: *TimerQueue) EventLoop {
        return .{
            .engine = engine,
            .timer_queue = timer_queue,
            .allocator = allocator,
            .raf_callbacks = .empty,
            .frame_count = 0,
            .start_time_ns = std.time.nanoTimestamp(),
            .running = true,
            .fail_fast = false,
            .fatal_error = false,
            .next_raf_id = 1,
        };
    }

    /// Tears down the EventLoop, freeing any pending rAF callback references.
    pub fn deinit(self: *EventLoop) void {
        const ctx = self.engine.context;
        for (self.raf_callbacks.items) |entry| {
            entry.callback.deinit(ctx);
        }
        self.raf_callbacks.deinit(self.allocator);
    }

    /// Register a rAF callback, return its ID.
    ///
    /// The callback Value is dup'd (ref-counted) on store; the caller retains
    /// ownership of the original.
    pub fn requestAnimationFrame(self: *EventLoop, callback: Value) u32 {
        const ctx = self.engine.context;
        const id = self.next_raf_id;
        self.next_raf_id +%= 1;
        // Skip ID 0 — reserve it as a sentinel.
        if (self.next_raf_id == 0) self.next_raf_id = 1;

        const duped = callback.dup(ctx);
        self.raf_callbacks.append(self.allocator, .{
            .id = id,
            .callback = duped,
            .cancelled = false,
        }) catch {
            // If append fails, free the duped value.
            duped.deinit(ctx);
            return 0;
        };

        return id;
    }

    /// Cancel a pending rAF callback by ID.
    pub fn cancelAnimationFrame(self: *EventLoop, id: u32) void {
        for (self.raf_callbacks.items) |*entry| {
            if (entry.id == id) {
                entry.cancelled = true;
                return;
            }
        }
    }

    /// Run the main loop until the window requests close or `running` is false.
    ///
    /// This is the top-level game/render loop. Each iteration polls GLFW events,
    /// then calls `tick()` for timers, microtasks, and rAF.
    pub fn run(self: *EventLoop, window: *Window) void {
        while (!window.shouldClose() and self.running) {
            window.pollEvents();
            self.tick();
        }
    }

    /// Single frame tick (usable without a window for testing).
    ///
    /// 1. Fire expired timers
    /// 2. Drain QJS job queue
    /// 3. Fire rAF callbacks
    /// 4. Drain QJS job queue again (rAF may have queued promises)
    /// 5. Increment frame counter
    pub fn tick(self: *EventLoop) void {
        // 1. Fire timers
        self.timer_queue.tick(self.engine.context);
        if (self.fatal_error and self.fail_fast) return;

        // 2. Drain microtasks (promise jobs)
        self.drainMicrotasks();
        if (self.fatal_error and self.fail_fast) return;

        // 3. Fire rAF callbacks
        self.fireRafCallbacks();
        if (self.fatal_error and self.fail_fast) return;

        // 4. Drain microtasks again (rAF callbacks may have queued promises)
        self.drainMicrotasks();
        if (self.fatal_error and self.fail_fast) return;

        // 5. Advance frame count
        self.frame_count += 1;
    }

    /// Keep ticking (processing timers + microtasks) until at least one rAF
    /// callback is registered, meaning the app's async init is done and it's
    /// ready to render.
    pub fn pumpUntilReady(self: *EventLoop) void {
        var max_ticks: u32 = 10_000; // safety limit
        while (self.raf_callbacks.items.len == 0 and max_ticks > 0 and !self.fatal_error) : (max_ticks -= 1) {
            self.timer_queue.tick(self.engine.context);
            self.drainMicrotasks();
        }
    }

    /// Stop the event loop (causes `run()` to exit at next iteration).
    pub fn stop(self: *EventLoop) void {
        self.running = false;
    }

    pub fn setFailFast(self: *EventLoop, enabled: bool) void {
        self.fail_fast = enabled;
    }

    pub fn hasFatalError(self: *const EventLoop) bool {
        return self.fatal_error;
    }

    /// Compute the current DOMHighResTimeStamp (f64 ms since EventLoop init),
    /// matching the semantics of `performance.now()`.
    pub fn nowMs(self: *const EventLoop) f64 {
        const elapsed_ns = std.time.nanoTimestamp() - self.start_time_ns;
        return @as(f64, @floatFromInt(elapsed_ns)) / 1_000_000.0;
    }

    // =========================================================================
    // Internal helpers
    // =========================================================================

    /// Drain the QuickJS microtask/job queue (promise continuations, etc.).
    fn drainMicrotasks(self: *EventLoop) void {
        const runtime = self.engine.runtime;
        while (runtime.isJobPending()) {
            _ = runtime.executePendingJob() catch |err| {
                if (builtin.is_test) {
                    log.warn("microtask exception: {}", .{err});
                } else {
                    log.err("microtask exception: {}", .{err});
                }
                if (self.fail_fast) {
                    self.fatal_error = true;
                    self.stop();
                }
                break;
            };
        }
    }

    /// Fire all pending rAF callbacks, then clear the list.
    ///
    /// rAF callbacks are one-shot: they must be re-registered each frame.
    /// Cancelled callbacks are skipped and freed.
    fn fireRafCallbacks(self: *EventLoop) void {
        const ctx = self.engine.context;
        const allocator = self.allocator;

        // If no callbacks, nothing to do.
        if (self.raf_callbacks.items.len == 0) return;

        // Swap the list so that rAF calls inside callbacks don't fire
        // until the *next* frame (matching browser semantics).
        var current = self.raf_callbacks;
        self.raf_callbacks = .empty;

        defer {
            // Free all entries from the current batch.
            for (current.items) |entry| {
                entry.callback.deinit(ctx);
            }
            current.deinit(allocator);
        }

        const global_this = ctx.getGlobalObject();
        defer global_this.deinit(ctx);

        // Compute DOMHighResTimeStamp (ms since start).
        const timestamp = self.nowMs();
        const ts_val = Value.initFloat64(timestamp);

        for (current.items) |entry| {
            if (entry.cancelled) continue;

            const result = entry.callback.call(ctx, global_this, &.{ts_val});
            if (result.isException()) {
                const exc = ctx.getException();
                if (exc.toCString(ctx)) |msg| {
                    if (builtin.is_test) {
                        log.warn("rAF callback exception: {s}", .{std.mem.span(msg)});
                    } else {
                        log.err("rAF callback exception: {s}", .{std.mem.span(msg)});
                    }
                    ctx.freeCString(msg);
                }
                exc.deinit(ctx);
                result.deinit(ctx);
                if (self.fail_fast) {
                    self.fatal_error = true;
                    self.stop();
                    return;
                }
                continue;
            }
            result.deinit(ctx);
        }
    }
};

// =============================================================================
// QuickJS Global Function Registration
// =============================================================================

/// Registers requestAnimationFrame and cancelAnimationFrame as global
/// functions on the given QuickJS context.
///
/// Follows the same pattern as timers.zig: module-level global pointer
/// because QuickJS C callbacks don't carry userdata.
pub fn register(ctx: *Context, loop: *EventLoop) !void {
    global_loop = loop;

    const global = ctx.getGlobalObject();
    defer global.deinit(ctx);

    const raf_fn = Value.initCFunction(ctx, &jsRequestAnimationFrame, "requestAnimationFrame", 1);
    global.setPropertyStr(ctx, "requestAnimationFrame", raf_fn) catch return error.JSError;

    const caf_fn = Value.initCFunction(ctx, &jsCancelAnimationFrame, "cancelAnimationFrame", 1);
    global.setPropertyStr(ctx, "cancelAnimationFrame", caf_fn) catch return error.JSError;
}

/// requestAnimationFrame(callback) -> id
fn jsRequestAnimationFrame(
    ctx_opt: ?*Context,
    _: Value,
    argv: []const c.JSValue,
) Value {
    const ctx = ctx_opt orelse return Value.undefined;
    const loop = global_loop orelse return Value.undefined;

    if (argv.len < 1) return Value.undefined;

    const callback: Value = @bitCast(argv[0]);

    // Verify argument is a function.
    if (!callback.isFunction(ctx)) return Value.undefined;

    const id = loop.requestAnimationFrame(callback);
    return Value.initInt32(@intCast(id));
}

/// cancelAnimationFrame(id)
fn jsCancelAnimationFrame(
    ctx_opt: ?*Context,
    _: Value,
    argv: []const c.JSValue,
) Value {
    const ctx = ctx_opt orelse return Value.undefined;
    const loop = global_loop orelse return Value.undefined;

    if (argv.len < 1) return Value.undefined;

    const id_val: Value = @bitCast(argv[0]);
    const id = id_val.toInt32(ctx) catch return Value.undefined;
    if (id <= 0) return Value.undefined;

    loop.cancelAnimationFrame(@intCast(id));
    return Value.undefined;
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

test "tick increments frame_count" {
    var engine = try JsEngine.init(testing.allocator);
    defer engine.deinit();
    var queue = TimerQueue.init(testing.allocator);
    defer queue.deinit(engine.context);

    var loop = EventLoop.init(testing.allocator, &engine, &queue);
    defer loop.deinit();

    try testing.expectEqual(@as(u64, 0), loop.frame_count);

    loop.tick();
    try testing.expectEqual(@as(u64, 1), loop.frame_count);

    loop.tick();
    try testing.expectEqual(@as(u64, 2), loop.frame_count);

    loop.tick();
    try testing.expectEqual(@as(u64, 3), loop.frame_count);
}

test "rAF callback fires on tick with timestamp" {
    var engine = try JsEngine.init(testing.allocator);
    defer engine.deinit();
    var queue = TimerQueue.init(testing.allocator);
    defer queue.deinit(engine.context);
    const timers = @import("polyfills/timers.zig");
    try timers.register(engine.context, &queue);

    var loop = EventLoop.init(testing.allocator, &engine, &queue);
    defer loop.deinit();
    try register(engine.context, &loop);

    // Register rAF from JS and verify callback is called with a numeric timestamp.
    var r1 = try engine.eval(
        \\var rafCalled = false;
        \\var rafTimestamp = -1;
        \\requestAnimationFrame(function(ts) {
        \\  rafCalled = true;
        \\  rafTimestamp = ts;
        \\});
    , "<test>");
    r1.deinit();

    loop.tick();

    var r2 = try engine.eval("rafCalled", "<test>");
    defer r2.deinit();
    try testing.expectEqual(@as(i32, 1), try r2.toInt32());

    var r3 = try engine.eval("rafTimestamp >= 0", "<test>");
    defer r3.deinit();
    try testing.expectEqual(@as(i32, 1), try r3.toInt32());
}

test "cancelAnimationFrame prevents callback from firing" {
    var engine = try JsEngine.init(testing.allocator);
    defer engine.deinit();
    var queue = TimerQueue.init(testing.allocator);
    defer queue.deinit(engine.context);
    const timers = @import("polyfills/timers.zig");
    try timers.register(engine.context, &queue);

    var loop = EventLoop.init(testing.allocator, &engine, &queue);
    defer loop.deinit();
    try register(engine.context, &loop);

    var r1 = try engine.eval(
        \\var cancelled_fired = false;
        \\var id = requestAnimationFrame(function() { cancelled_fired = true; });
        \\cancelAnimationFrame(id);
    , "<test>");
    r1.deinit();

    loop.tick();

    var r2 = try engine.eval("cancelled_fired", "<test>");
    defer r2.deinit();
    // Should still be false (0).
    try testing.expectEqual(@as(i32, 0), try r2.toInt32());
}

test "rAF callbacks are one-shot" {
    var engine = try JsEngine.init(testing.allocator);
    defer engine.deinit();
    var queue = TimerQueue.init(testing.allocator);
    defer queue.deinit(engine.context);
    const timers = @import("polyfills/timers.zig");
    try timers.register(engine.context, &queue);

    var loop = EventLoop.init(testing.allocator, &engine, &queue);
    defer loop.deinit();
    try register(engine.context, &loop);

    var r1 = try engine.eval(
        \\var raf_count = 0;
        \\requestAnimationFrame(function() { raf_count++; });
    , "<test>");
    r1.deinit();

    // Tick three times — callback should only fire once.
    loop.tick();
    loop.tick();
    loop.tick();

    var r2 = try engine.eval("raf_count", "<test>");
    defer r2.deinit();
    try testing.expectEqual(@as(i32, 1), try r2.toInt32());
}

test "timers fire during tick" {
    var engine = try JsEngine.init(testing.allocator);
    defer engine.deinit();
    var queue = TimerQueue.init(testing.allocator);
    defer queue.deinit(engine.context);
    const timers = @import("polyfills/timers.zig");
    try timers.register(engine.context, &queue);

    var loop = EventLoop.init(testing.allocator, &engine, &queue);
    defer loop.deinit();
    try register(engine.context, &loop);

    var r1 = try engine.eval(
        \\var timer_fired = false;
        \\setTimeout(function() { timer_fired = true; }, 0);
    , "<test>");
    r1.deinit();

    loop.tick();

    var r2 = try engine.eval("timer_fired", "<test>");
    defer r2.deinit();
    try testing.expectEqual(@as(i32, 1), try r2.toInt32());
}

test "microtask drain: Promise.then runs during tick" {
    var engine = try JsEngine.init(testing.allocator);
    defer engine.deinit();
    var queue = TimerQueue.init(testing.allocator);
    defer queue.deinit(engine.context);

    var loop = EventLoop.init(testing.allocator, &engine, &queue);
    defer loop.deinit();

    // Create a resolved promise — the .then() should run when microtasks drain.
    var r1 = try engine.eval(
        \\var promise_result = 0;
        \\Promise.resolve(42).then(function(x) { promise_result = x; });
    , "<test>");
    r1.deinit();

    loop.tick();

    var r2 = try engine.eval("promise_result", "<test>");
    defer r2.deinit();
    try testing.expectEqual(@as(i32, 42), try r2.toInt32());
}

test "pumpUntilReady completes when rAF is registered" {
    var engine = try JsEngine.init(testing.allocator);
    defer engine.deinit();
    var queue = TimerQueue.init(testing.allocator);
    defer queue.deinit(engine.context);
    const timers = @import("polyfills/timers.zig");
    try timers.register(engine.context, &queue);

    var loop = EventLoop.init(testing.allocator, &engine, &queue);
    defer loop.deinit();
    try register(engine.context, &loop);

    // Simulate async init: a setTimeout(0) that registers a rAF when it fires.
    var r1 = try engine.eval(
        \\setTimeout(function() {
        \\  requestAnimationFrame(function() {});
        \\}, 0);
    , "<test>");
    r1.deinit();

    // No rAF registered yet.
    try testing.expectEqual(@as(usize, 0), loop.raf_callbacks.items.len);

    // Pump should process the timer and eventually see the rAF.
    loop.pumpUntilReady();

    try testing.expect(loop.raf_callbacks.items.len > 0);
}

test "requestAnimationFrame returns unique IDs" {
    var engine = try JsEngine.init(testing.allocator);
    defer engine.deinit();
    var queue = TimerQueue.init(testing.allocator);
    defer queue.deinit(engine.context);
    const timers = @import("polyfills/timers.zig");
    try timers.register(engine.context, &queue);

    var loop = EventLoop.init(testing.allocator, &engine, &queue);
    defer loop.deinit();
    try register(engine.context, &loop);

    var r = try engine.eval(
        \\var id1 = requestAnimationFrame(function(){});
        \\var id2 = requestAnimationFrame(function(){});
        \\var id3 = requestAnimationFrame(function(){});
        \\(id1 !== id2 && id2 !== id3 && id1 !== id3 &&
        \\ typeof id1 === 'number' && typeof id2 === 'number')
    , "<test>");
    defer r.deinit();
    try testing.expectEqual(@as(i32, 1), try r.toInt32());
}

test "rAF functions exist as globals" {
    var engine = try JsEngine.init(testing.allocator);
    defer engine.deinit();
    var queue = TimerQueue.init(testing.allocator);
    defer queue.deinit(engine.context);

    var loop = EventLoop.init(testing.allocator, &engine, &queue);
    defer loop.deinit();
    try register(engine.context, &loop);

    var r = try engine.eval(
        \\typeof requestAnimationFrame === 'function' &&
        \\typeof cancelAnimationFrame === 'function'
    , "<test>");
    defer r.deinit();
    try testing.expectEqual(@as(i32, 1), try r.toInt32());
}

test "rAF callback registered inside rAF fires on next tick, not same tick" {
    var engine = try JsEngine.init(testing.allocator);
    defer engine.deinit();
    var queue = TimerQueue.init(testing.allocator);
    defer queue.deinit(engine.context);
    const timers = @import("polyfills/timers.zig");
    try timers.register(engine.context, &queue);

    var loop = EventLoop.init(testing.allocator, &engine, &queue);
    defer loop.deinit();
    try register(engine.context, &loop);

    // Register a rAF that registers another rAF inside it.
    var r1 = try engine.eval(
        \\var call_order = [];
        \\requestAnimationFrame(function() {
        \\  call_order.push('first');
        \\  requestAnimationFrame(function() {
        \\    call_order.push('second');
        \\  });
        \\});
    , "<test>");
    r1.deinit();

    // First tick: only 'first' should fire.
    loop.tick();

    var r2 = try engine.eval("call_order.length", "<test>");
    defer r2.deinit();
    try testing.expectEqual(@as(i32, 1), try r2.toInt32());

    // Second tick: 'second' should fire.
    loop.tick();

    var r3 = try engine.eval("call_order.length", "<test>");
    defer r3.deinit();
    try testing.expectEqual(@as(i32, 2), try r3.toInt32());
}

test "fail-fast mode stops loop on rAF exception" {
    var engine = try JsEngine.init(testing.allocator);
    defer engine.deinit();
    var queue = TimerQueue.init(testing.allocator);
    defer queue.deinit(engine.context);
    const timers = @import("polyfills/timers.zig");
    try timers.register(engine.context, &queue);

    var loop = EventLoop.init(testing.allocator, &engine, &queue);
    defer loop.deinit();
    try register(engine.context, &loop);
    loop.setFailFast(true);

    var r = try engine.eval(
        \\requestAnimationFrame(function() {
        \\  throw new Error("boom");
        \\});
    , "<test>");
    r.deinit();

    loop.tick();

    try testing.expect(loop.hasFatalError());
    try testing.expect(!loop.running);
}

test "resilient mode continues after rAF exception" {
    var engine = try JsEngine.init(testing.allocator);
    defer engine.deinit();
    var queue = TimerQueue.init(testing.allocator);
    defer queue.deinit(engine.context);
    const timers = @import("polyfills/timers.zig");
    try timers.register(engine.context, &queue);

    var loop = EventLoop.init(testing.allocator, &engine, &queue);
    defer loop.deinit();
    try register(engine.context, &loop);

    var r = try engine.eval(
        \\requestAnimationFrame(function() {
        \\  throw new Error("boom");
        \\});
    , "<test>");
    r.deinit();

    loop.tick();

    try testing.expect(!loop.hasFatalError());
    try testing.expect(loop.running);
}
