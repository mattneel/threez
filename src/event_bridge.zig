const std = @import("std");
const quickjs = @import("quickjs");
const Value = quickjs.Value;
const Context = quickjs.Context;

// =============================================================================
// GLFW constants (matching GLFW headers)
// =============================================================================

pub const GLFW_PRESS = 1;
pub const GLFW_RELEASE = 0;
pub const GLFW_REPEAT = 2;

pub const GLFW_MOUSE_BUTTON_LEFT = 0;
pub const GLFW_MOUSE_BUTTON_RIGHT = 1;
pub const GLFW_MOUSE_BUTTON_MIDDLE = 2;

pub const GLFW_MOD_SHIFT = 0x01;
pub const GLFW_MOD_CONTROL = 0x02;
pub const GLFW_MOD_ALT = 0x04;
pub const GLFW_MOD_SUPER = 0x08;

// =============================================================================
// GLFW key -> DOM key/code mapping
// =============================================================================

/// A mapping entry from GLFW key code to DOM `key` and `code` strings.
pub const KeyMapping = struct {
    key: []const u8,
    code: []const u8,
};

/// Comptime lookup table mapping GLFW key codes to DOM key/code strings.
/// Covers letters, digits, punctuation, function keys, arrow keys, modifiers,
/// and common editing keys.
const key_map = buildKeyMap();

fn buildKeyMap() [400]?KeyMapping {
    var map: [400]?KeyMapping = .{null} ** 400;

    // Letters A-Z (GLFW 65..90)
    map[65] = .{ .key = "a", .code = "KeyA" };
    map[66] = .{ .key = "b", .code = "KeyB" };
    map[67] = .{ .key = "c", .code = "KeyC" };
    map[68] = .{ .key = "d", .code = "KeyD" };
    map[69] = .{ .key = "e", .code = "KeyE" };
    map[70] = .{ .key = "f", .code = "KeyF" };
    map[71] = .{ .key = "g", .code = "KeyG" };
    map[72] = .{ .key = "h", .code = "KeyH" };
    map[73] = .{ .key = "i", .code = "KeyI" };
    map[74] = .{ .key = "j", .code = "KeyJ" };
    map[75] = .{ .key = "k", .code = "KeyK" };
    map[76] = .{ .key = "l", .code = "KeyL" };
    map[77] = .{ .key = "m", .code = "KeyM" };
    map[78] = .{ .key = "n", .code = "KeyN" };
    map[79] = .{ .key = "o", .code = "KeyO" };
    map[80] = .{ .key = "p", .code = "KeyP" };
    map[81] = .{ .key = "q", .code = "KeyQ" };
    map[82] = .{ .key = "r", .code = "KeyR" };
    map[83] = .{ .key = "s", .code = "KeyS" };
    map[84] = .{ .key = "t", .code = "KeyT" };
    map[85] = .{ .key = "u", .code = "KeyU" };
    map[86] = .{ .key = "v", .code = "KeyV" };
    map[87] = .{ .key = "w", .code = "KeyW" };
    map[88] = .{ .key = "x", .code = "KeyX" };
    map[89] = .{ .key = "y", .code = "KeyY" };
    map[90] = .{ .key = "z", .code = "KeyZ" };

    // Digits 0-9 (GLFW 48..57)
    map[48] = .{ .key = "0", .code = "Digit0" };
    map[49] = .{ .key = "1", .code = "Digit1" };
    map[50] = .{ .key = "2", .code = "Digit2" };
    map[51] = .{ .key = "3", .code = "Digit3" };
    map[52] = .{ .key = "4", .code = "Digit4" };
    map[53] = .{ .key = "5", .code = "Digit5" };
    map[54] = .{ .key = "6", .code = "Digit6" };
    map[55] = .{ .key = "7", .code = "Digit7" };
    map[56] = .{ .key = "8", .code = "Digit8" };
    map[57] = .{ .key = "9", .code = "Digit9" };

    // Punctuation / symbols
    map[32] = .{ .key = " ", .code = "Space" };
    map[39] = .{ .key = "'", .code = "Quote" };
    map[44] = .{ .key = ",", .code = "Comma" };
    map[45] = .{ .key = "-", .code = "Minus" };
    map[46] = .{ .key = ".", .code = "Period" };
    map[47] = .{ .key = "/", .code = "Slash" };

    // Special keys (GLFW 256+) — stored in the high_key_map below
    // These are handled separately since they exceed index 400.

    return map;
}

/// Mapping for GLFW key codes >= 256 (special keys).
/// Stored as a flat array of struct entries for linear scan (small set).
const HighKeyEntry = struct {
    glfw_key: i32,
    key: []const u8,
    code: []const u8,
};

const high_key_map = [_]HighKeyEntry{
    .{ .glfw_key = 256, .key = "Escape", .code = "Escape" },
    .{ .glfw_key = 257, .key = "Enter", .code = "Enter" },
    .{ .glfw_key = 258, .key = "Tab", .code = "Tab" },
    .{ .glfw_key = 259, .key = "Backspace", .code = "Backspace" },
    .{ .glfw_key = 260, .key = "Insert", .code = "Insert" },
    .{ .glfw_key = 261, .key = "Delete", .code = "Delete" },
    .{ .glfw_key = 262, .key = "ArrowRight", .code = "ArrowRight" },
    .{ .glfw_key = 263, .key = "ArrowLeft", .code = "ArrowLeft" },
    .{ .glfw_key = 264, .key = "ArrowDown", .code = "ArrowDown" },
    .{ .glfw_key = 265, .key = "ArrowUp", .code = "ArrowUp" },
    .{ .glfw_key = 266, .key = "PageUp", .code = "PageUp" },
    .{ .glfw_key = 267, .key = "PageDown", .code = "PageDown" },
    .{ .glfw_key = 268, .key = "Home", .code = "Home" },
    .{ .glfw_key = 269, .key = "End", .code = "End" },
    // F1..F12 (GLFW 290..301)
    .{ .glfw_key = 290, .key = "F1", .code = "F1" },
    .{ .glfw_key = 291, .key = "F2", .code = "F2" },
    .{ .glfw_key = 292, .key = "F3", .code = "F3" },
    .{ .glfw_key = 293, .key = "F4", .code = "F4" },
    .{ .glfw_key = 294, .key = "F5", .code = "F5" },
    .{ .glfw_key = 295, .key = "F6", .code = "F6" },
    .{ .glfw_key = 296, .key = "F7", .code = "F7" },
    .{ .glfw_key = 297, .key = "F8", .code = "F8" },
    .{ .glfw_key = 298, .key = "F9", .code = "F9" },
    .{ .glfw_key = 299, .key = "F10", .code = "F10" },
    .{ .glfw_key = 300, .key = "F11", .code = "F11" },
    .{ .glfw_key = 301, .key = "F12", .code = "F12" },
    // Modifier keys
    .{ .glfw_key = 340, .key = "Shift", .code = "ShiftLeft" },
    .{ .glfw_key = 341, .key = "Control", .code = "ControlLeft" },
    .{ .glfw_key = 342, .key = "Alt", .code = "AltLeft" },
    .{ .glfw_key = 343, .key = "Meta", .code = "MetaLeft" },
    .{ .glfw_key = 344, .key = "Shift", .code = "ShiftRight" },
    .{ .glfw_key = 345, .key = "Control", .code = "ControlRight" },
    .{ .glfw_key = 346, .key = "Alt", .code = "AltRight" },
    .{ .glfw_key = 347, .key = "Meta", .code = "MetaRight" },
};

/// Look up the DOM key and code strings for a GLFW key code.
/// Returns null for unknown key codes.
pub fn lookupKey(glfw_key: i32) ?KeyMapping {
    // Try the low table first (printable keys 0..99).
    if (glfw_key >= 0 and glfw_key < 400) {
        if (key_map[@intCast(glfw_key)]) |m| {
            return m;
        }
    }

    // Linear scan the high-key table for special/modifier keys (256+).
    for (high_key_map) |entry| {
        if (entry.glfw_key == glfw_key) {
            return .{ .key = entry.key, .code = entry.code };
        }
    }

    return null;
}

// =============================================================================
// EventBridge
// =============================================================================

/// Translates GLFW input callbacks into synthetic DOM events dispatched to
/// JavaScript EventTarget objects (window, document, canvas).
///
/// The bridge holds references to the JS context and the three main event
/// targets. Public methods like `onMouseMove`, `onMouseButton`, etc. are
/// designed to be called from GLFW callbacks.
pub const EventBridge = struct {
    ctx: *Context,
    /// JS `window` object (EventTarget)
    js_window: Value,
    /// JS `document` object (EventTarget)
    js_document: Value,
    /// JS canvas element (EventTarget) — primary target for pointer/wheel events
    js_canvas: Value,

    /// Previous cursor position for computing movementX/Y
    last_x: f64 = 0,
    last_y: f64 = 0,
    /// Whether we have received at least one cursor position
    has_last_pos: bool = false,

    /// Current window dimensions (updated on resize)
    width: i32 = 800,
    height: i32 = 600,

    /// Current modifier key state (GLFW mod bitmask)
    mods: i32 = 0,

    /// Create an EventBridge. The caller must ensure the JS values remain
    /// valid for the lifetime of the bridge.
    ///
    /// The provided values are *not* duplicated — the caller retains ownership
    /// and must keep them alive. If the caller wants the bridge to own them,
    /// pass duped values and call `deinit`.
    pub fn init(
        ctx: *Context,
        js_window: Value,
        js_document: Value,
        js_canvas: Value,
    ) EventBridge {
        return .{
            .ctx = ctx,
            .js_window = js_window,
            .js_document = js_document,
            .js_canvas = js_canvas,
        };
    }

    /// Release the JS value references held by this bridge.
    /// Only call this if you passed duped values to `init`.
    pub fn deinit(self: *EventBridge) void {
        self.js_canvas.deinit(self.ctx);
        self.js_document.deinit(self.ctx);
        self.js_window.deinit(self.ctx);
    }

    // -------------------------------------------------------------------------
    // Mouse / pointer events
    // -------------------------------------------------------------------------

    /// Called on GLFW cursor position callback.
    /// Dispatches a PointerEvent("pointermove") on the canvas.
    pub fn onMouseMove(self: *EventBridge, x: f64, y: f64) void {
        const mx: f64 = if (self.has_last_pos) x - self.last_x else 0;
        const my: f64 = if (self.has_last_pos) y - self.last_y else 0;
        self.last_x = x;
        self.last_y = y;
        self.has_last_pos = true;

        self.dispatchPointerEvent("pointermove", x, y, mx, my, 0, self.js_canvas);
        // Simulate bubbling: OrbitControls listens on ownerDocument for pointermove
        self.dispatchPointerEvent("pointermove", x, y, mx, my, 0, self.js_document);
    }

    /// Called on GLFW mouse button callback.
    /// Dispatches PointerEvent("pointerdown") or PointerEvent("pointerup") on the canvas.
    pub fn onMouseButton(self: *EventBridge, button: i32, action: i32, mods_val: i32) void {
        self.mods = mods_val;
        const event_type: []const u8 = if (action == GLFW_PRESS) "pointerdown" else "pointerup";
        // Map GLFW button to DOM button
        const dom_button: i32 = glfwButtonToDom(button);
        self.dispatchPointerEvent(event_type, self.last_x, self.last_y, 0, 0, dom_button, self.js_canvas);
        // Simulate bubbling: OrbitControls listens on ownerDocument for pointerup
        self.dispatchPointerEvent(event_type, self.last_x, self.last_y, 0, 0, dom_button, self.js_document);
    }

    /// Called on GLFW scroll callback.
    /// Dispatches WheelEvent("wheel") on the canvas.
    pub fn onScroll(self: *EventBridge, dx: f64, dy: f64) void {
        // GLFW scroll is typically in "lines"; browsers use pixels.
        // Multiply by a reasonable factor. The sign is also inverted:
        // GLFW positive Y = scroll up, DOM positive deltaY = scroll down.
        self.dispatchWheelEvent(dx, -dy * 100.0);
    }

    /// Called on GLFW key callback.
    /// Dispatches KeyboardEvent("keydown") or KeyboardEvent("keyup") on the document.
    pub fn onKey(self: *EventBridge, key: i32, _: i32, action: i32, mods_val: i32) void {
        self.mods = mods_val;
        const is_repeat = action == GLFW_REPEAT;
        const event_type: []const u8 = if (action == GLFW_RELEASE) "keyup" else "keydown";
        self.dispatchKeyboardEvent(event_type, key, mods_val, is_repeat);
    }

    /// Called on GLFW window resize / framebuffer size callback.
    /// Updates window.innerWidth/innerHeight, canvas.width/height,
    /// globalThis.innerWidth/innerHeight, and dispatches Event("resize") on window.
    pub fn onResize(self: *EventBridge, new_width: i32, new_height: i32) void {
        self.width = new_width;
        self.height = new_height;

        // Update window.innerWidth and window.innerHeight
        self.js_window.setPropertyStr(self.ctx, "innerWidth", Value.initInt32(new_width)) catch {};
        self.js_window.setPropertyStr(self.ctx, "innerHeight", Value.initInt32(new_height)) catch {};

        // Update canvas.width and canvas.height so Three.js sees the new size
        self.js_canvas.setPropertyStr(self.ctx, "width", Value.initInt32(new_width)) catch {};
        self.js_canvas.setPropertyStr(self.ctx, "height", Value.initInt32(new_height)) catch {};

        // Update globalThis.innerWidth/innerHeight (stale copies from bootstrap)
        const global = self.ctx.getGlobalObject();
        defer global.deinit(self.ctx);
        global.setPropertyStr(self.ctx, "innerWidth", Value.initInt32(new_width)) catch {};
        global.setPropertyStr(self.ctx, "innerHeight", Value.initInt32(new_height)) catch {};

        // Dispatch a plain Event("resize") on window
        self.dispatchSimpleEvent("resize", self.js_window);
    }

    /// Called on GLFW cursor enter/leave callback.
    /// Dispatches PointerEvent("pointerenter") or PointerEvent("pointerleave") on the canvas.
    pub fn onCursorEnter(self: *EventBridge, entered: bool) void {
        const event_type: []const u8 = if (entered) "pointerenter" else "pointerleave";
        self.dispatchPointerEvent(event_type, self.last_x, self.last_y, 0, 0, 0, self.js_canvas);
    }

    // -------------------------------------------------------------------------
    // Internal dispatch helpers
    // -------------------------------------------------------------------------

    /// Dispatch a PointerEvent on the given JS target.
    fn dispatchPointerEvent(
        self: *EventBridge,
        event_type: []const u8,
        client_x: f64,
        client_y: f64,
        movement_x: f64,
        movement_y: f64,
        button: i32,
        target: Value,
    ) void {
        const ctx = self.ctx;

        // Get the PointerEvent constructor from globalThis
        const global = ctx.getGlobalObject();
        defer global.deinit(ctx);
        const ctor = global.getPropertyStr(ctx, "PointerEvent");
        defer ctor.deinit(ctx);
        if (ctor.isUndefined()) return;

        // Build the init object: { clientX, clientY, movementX, movementY, button, pointerType: "mouse" }
        const init_obj = Value.initObject(ctx);
        defer init_obj.deinit(ctx);
        init_obj.setPropertyStr(ctx, "clientX", Value.initFloat64(client_x)) catch return;
        init_obj.setPropertyStr(ctx, "clientY", Value.initFloat64(client_y)) catch return;
        init_obj.setPropertyStr(ctx, "movementX", Value.initFloat64(movement_x)) catch return;
        init_obj.setPropertyStr(ctx, "movementY", Value.initFloat64(movement_y)) catch return;
        init_obj.setPropertyStr(ctx, "button", Value.initInt32(button)) catch return;
        init_obj.setPropertyStr(ctx, "pointerId", Value.initInt32(1)) catch return;
        init_obj.setPropertyStr(ctx, "pointerType", Value.initStringLen(ctx, "mouse")) catch return;
        init_obj.setPropertyStr(ctx, "bubbles", Value.initBool(true)) catch return;
        init_obj.setPropertyStr(ctx, "cancelable", Value.initBool(true)) catch return;

        // new PointerEvent(type, init)
        const type_val = Value.initStringLen(ctx, event_type);
        defer type_val.deinit(ctx);
        const event_obj = ctor.callConstructor(ctx, &.{ type_val, init_obj });
        defer event_obj.deinit(ctx);
        if (event_obj.isException()) {
            // Clear exception so it does not leak
            const exc = ctx.getException();
            exc.deinit(ctx);
            return;
        }

        // target.dispatchEvent(event)
        self.callDispatchEvent(target, event_obj);
    }

    /// Dispatch a WheelEvent on the canvas.
    fn dispatchWheelEvent(self: *EventBridge, delta_x: f64, delta_y: f64) void {
        const ctx = self.ctx;

        const global = ctx.getGlobalObject();
        defer global.deinit(ctx);
        const ctor = global.getPropertyStr(ctx, "WheelEvent");
        defer ctor.deinit(ctx);
        if (ctor.isUndefined()) return;

        // Build init: { deltaX, deltaY, deltaMode: 0, bubbles: true, cancelable: true }
        const init_obj = Value.initObject(ctx);
        defer init_obj.deinit(ctx);
        init_obj.setPropertyStr(ctx, "deltaX", Value.initFloat64(delta_x)) catch return;
        init_obj.setPropertyStr(ctx, "deltaY", Value.initFloat64(delta_y)) catch return;
        init_obj.setPropertyStr(ctx, "deltaMode", Value.initInt32(0)) catch return;
        init_obj.setPropertyStr(ctx, "bubbles", Value.initBool(true)) catch return;
        init_obj.setPropertyStr(ctx, "cancelable", Value.initBool(true)) catch return;

        const type_val = Value.initStringLen(ctx, "wheel");
        defer type_val.deinit(ctx);
        const event_obj = ctor.callConstructor(ctx, &.{ type_val, init_obj });
        defer event_obj.deinit(ctx);
        if (event_obj.isException()) {
            const exc = ctx.getException();
            exc.deinit(ctx);
            return;
        }

        self.callDispatchEvent(self.js_canvas, event_obj);
    }

    /// Dispatch a KeyboardEvent on the document.
    fn dispatchKeyboardEvent(
        self: *EventBridge,
        event_type: []const u8,
        glfw_key: i32,
        mods_val: i32,
        is_repeat: bool,
    ) void {
        const ctx = self.ctx;

        const mapping = lookupKey(glfw_key) orelse return;

        const global = ctx.getGlobalObject();
        defer global.deinit(ctx);
        const ctor = global.getPropertyStr(ctx, "KeyboardEvent");
        defer ctor.deinit(ctx);
        if (ctor.isUndefined()) return;

        // Build init: { key, code, shiftKey, ctrlKey, altKey, metaKey, repeat }
        const init_obj = Value.initObject(ctx);
        defer init_obj.deinit(ctx);
        init_obj.setPropertyStr(ctx, "key", Value.initStringLen(ctx, mapping.key)) catch return;
        init_obj.setPropertyStr(ctx, "code", Value.initStringLen(ctx, mapping.code)) catch return;
        init_obj.setPropertyStr(ctx, "shiftKey", Value.initBool(mods_val & GLFW_MOD_SHIFT != 0)) catch return;
        init_obj.setPropertyStr(ctx, "ctrlKey", Value.initBool(mods_val & GLFW_MOD_CONTROL != 0)) catch return;
        init_obj.setPropertyStr(ctx, "altKey", Value.initBool(mods_val & GLFW_MOD_ALT != 0)) catch return;
        init_obj.setPropertyStr(ctx, "metaKey", Value.initBool(mods_val & GLFW_MOD_SUPER != 0)) catch return;
        init_obj.setPropertyStr(ctx, "repeat", Value.initBool(is_repeat)) catch return;
        init_obj.setPropertyStr(ctx, "bubbles", Value.initBool(true)) catch return;
        init_obj.setPropertyStr(ctx, "cancelable", Value.initBool(true)) catch return;

        const type_val = Value.initStringLen(ctx, event_type);
        defer type_val.deinit(ctx);
        const event_obj = ctor.callConstructor(ctx, &.{ type_val, init_obj });
        defer event_obj.deinit(ctx);
        if (event_obj.isException()) {
            const exc = ctx.getException();
            exc.deinit(ctx);
            return;
        }

        // Keyboard events dispatch on document (like browsers)
        self.callDispatchEvent(self.js_document, event_obj);
    }

    /// Dispatch a plain Event (no extra properties) on the given target.
    fn dispatchSimpleEvent(self: *EventBridge, event_type: []const u8, target: Value) void {
        const ctx = self.ctx;

        const global = ctx.getGlobalObject();
        defer global.deinit(ctx);
        const ctor = global.getPropertyStr(ctx, "Event");
        defer ctor.deinit(ctx);
        if (ctor.isUndefined()) return;

        const type_val = Value.initStringLen(ctx, event_type);
        defer type_val.deinit(ctx);
        const event_obj = ctor.callConstructor(ctx, &.{type_val});
        defer event_obj.deinit(ctx);
        if (event_obj.isException()) {
            const exc = ctx.getException();
            exc.deinit(ctx);
            return;
        }

        self.callDispatchEvent(target, event_obj);
    }

    /// Call target.dispatchEvent(event) in JavaScript.
    fn callDispatchEvent(self: *EventBridge, target: Value, event_obj: Value) void {
        const ctx = self.ctx;
        const dispatch_fn = target.getPropertyStr(ctx, "dispatchEvent");
        defer dispatch_fn.deinit(ctx);
        if (dispatch_fn.isUndefined()) return;

        const result = dispatch_fn.call(ctx, target, &.{event_obj});
        defer result.deinit(ctx);
        // Ignore the return value; we just want the side-effect of dispatching.
        if (result.isException()) {
            const exc = ctx.getException();
            exc.deinit(ctx);
        }
    }
};

/// Map GLFW mouse button constant to DOM button number.
/// GLFW: LEFT=0, RIGHT=1, MIDDLE=2
/// DOM:  LEFT=0, MIDDLE=1, RIGHT=2
fn glfwButtonToDom(glfw_button: i32) i32 {
    return switch (glfw_button) {
        GLFW_MOUSE_BUTTON_LEFT => 0,
        GLFW_MOUSE_BUTTON_RIGHT => 2,
        GLFW_MOUSE_BUTTON_MIDDLE => 1,
        else => glfw_button,
    };
}

// =============================================================================
// Tests
// =============================================================================

const JsEngine = @import("js_engine.zig").JsEngine;
const bootstrap = @import("bootstrap.zig");

// ---------------------------------------------------------------------------
// Unit tests: key mapping table
// ---------------------------------------------------------------------------

test "lookupKey: letter A" {
    const mapping = lookupKey(65).?;
    try std.testing.expectEqualStrings("a", mapping.key);
    try std.testing.expectEqualStrings("KeyA", mapping.code);
}

test "lookupKey: digit 0" {
    const mapping = lookupKey(48).?;
    try std.testing.expectEqualStrings("0", mapping.key);
    try std.testing.expectEqualStrings("Digit0", mapping.code);
}

test "lookupKey: space" {
    const mapping = lookupKey(32).?;
    try std.testing.expectEqualStrings(" ", mapping.key);
    try std.testing.expectEqualStrings("Space", mapping.code);
}

test "lookupKey: Escape" {
    const mapping = lookupKey(256).?;
    try std.testing.expectEqualStrings("Escape", mapping.key);
    try std.testing.expectEqualStrings("Escape", mapping.code);
}

test "lookupKey: Enter" {
    const mapping = lookupKey(257).?;
    try std.testing.expectEqualStrings("Enter", mapping.key);
    try std.testing.expectEqualStrings("Enter", mapping.code);
}

test "lookupKey: ArrowUp" {
    const mapping = lookupKey(265).?;
    try std.testing.expectEqualStrings("ArrowUp", mapping.key);
    try std.testing.expectEqualStrings("ArrowUp", mapping.code);
}

test "lookupKey: ArrowDown" {
    const mapping = lookupKey(264).?;
    try std.testing.expectEqualStrings("ArrowDown", mapping.key);
    try std.testing.expectEqualStrings("ArrowDown", mapping.code);
}

test "lookupKey: ArrowLeft" {
    const mapping = lookupKey(263).?;
    try std.testing.expectEqualStrings("ArrowLeft", mapping.key);
    try std.testing.expectEqualStrings("ArrowLeft", mapping.code);
}

test "lookupKey: ArrowRight" {
    const mapping = lookupKey(262).?;
    try std.testing.expectEqualStrings("ArrowRight", mapping.key);
    try std.testing.expectEqualStrings("ArrowRight", mapping.code);
}

test "lookupKey: ShiftLeft" {
    const mapping = lookupKey(340).?;
    try std.testing.expectEqualStrings("Shift", mapping.key);
    try std.testing.expectEqualStrings("ShiftLeft", mapping.code);
}

test "lookupKey: ControlLeft" {
    const mapping = lookupKey(341).?;
    try std.testing.expectEqualStrings("Control", mapping.key);
    try std.testing.expectEqualStrings("ControlLeft", mapping.code);
}

test "lookupKey: AltLeft" {
    const mapping = lookupKey(342).?;
    try std.testing.expectEqualStrings("Alt", mapping.key);
    try std.testing.expectEqualStrings("AltLeft", mapping.code);
}

test "lookupKey: MetaLeft" {
    const mapping = lookupKey(343).?;
    try std.testing.expectEqualStrings("Meta", mapping.key);
    try std.testing.expectEqualStrings("MetaLeft", mapping.code);
}

test "lookupKey: ShiftRight" {
    const mapping = lookupKey(344).?;
    try std.testing.expectEqualStrings("Shift", mapping.key);
    try std.testing.expectEqualStrings("ShiftRight", mapping.code);
}

test "lookupKey: F1" {
    const mapping = lookupKey(290).?;
    try std.testing.expectEqualStrings("F1", mapping.key);
    try std.testing.expectEqualStrings("F1", mapping.code);
}

test "lookupKey: F12" {
    const mapping = lookupKey(301).?;
    try std.testing.expectEqualStrings("F12", mapping.key);
    try std.testing.expectEqualStrings("F12", mapping.code);
}

test "lookupKey: Tab" {
    const mapping = lookupKey(258).?;
    try std.testing.expectEqualStrings("Tab", mapping.key);
    try std.testing.expectEqualStrings("Tab", mapping.code);
}

test "lookupKey: Backspace" {
    const mapping = lookupKey(259).?;
    try std.testing.expectEqualStrings("Backspace", mapping.key);
    try std.testing.expectEqualStrings("Backspace", mapping.code);
}

test "lookupKey: Delete" {
    const mapping = lookupKey(261).?;
    try std.testing.expectEqualStrings("Delete", mapping.key);
    try std.testing.expectEqualStrings("Delete", mapping.code);
}

test "lookupKey: Home" {
    const mapping = lookupKey(268).?;
    try std.testing.expectEqualStrings("Home", mapping.key);
    try std.testing.expectEqualStrings("Home", mapping.code);
}

test "lookupKey: End" {
    const mapping = lookupKey(269).?;
    try std.testing.expectEqualStrings("End", mapping.key);
    try std.testing.expectEqualStrings("End", mapping.code);
}

test "lookupKey: PageUp" {
    const mapping = lookupKey(266).?;
    try std.testing.expectEqualStrings("PageUp", mapping.key);
    try std.testing.expectEqualStrings("PageUp", mapping.code);
}

test "lookupKey: PageDown" {
    const mapping = lookupKey(267).?;
    try std.testing.expectEqualStrings("PageDown", mapping.key);
    try std.testing.expectEqualStrings("PageDown", mapping.code);
}

test "lookupKey: unknown key returns null" {
    try std.testing.expect(lookupKey(-1) == null);
    try std.testing.expect(lookupKey(999) == null);
}

// ---------------------------------------------------------------------------
// Unit test: GLFW -> DOM button mapping
// ---------------------------------------------------------------------------

test "glfwButtonToDom maps correctly" {
    try std.testing.expectEqual(@as(i32, 0), glfwButtonToDom(GLFW_MOUSE_BUTTON_LEFT));
    try std.testing.expectEqual(@as(i32, 2), glfwButtonToDom(GLFW_MOUSE_BUTTON_RIGHT));
    try std.testing.expectEqual(@as(i32, 1), glfwButtonToDom(GLFW_MOUSE_BUTTON_MIDDLE));
}

// ---------------------------------------------------------------------------
// Integration tests: EventBridge with bootstrap JS
// ---------------------------------------------------------------------------

test "EventBridge init and deinit" {
    var engine = try JsEngine.init(std.testing.allocator);
    defer engine.deinit();

    try bootstrap.init(&engine);

    const ctx = engine.context;
    const global = ctx.getGlobalObject();
    defer global.deinit(ctx);

    const js_window = global.getPropertyStr(ctx, "window");
    defer js_window.deinit(ctx);
    const js_document = global.getPropertyStr(ctx, "document");
    defer js_document.deinit(ctx);

    // Get canvas via document.createElement('canvas')
    var canvas_result = try engine.eval("document.createElement('canvas')", "<test>");
    defer canvas_result.deinit();

    var bridge = EventBridge.init(ctx, js_window, js_document, canvas_result.value);
    // Don't deinit bridge since we didn't dup — the values are owned by the defers above
    _ = &bridge;
}

test "EventBridge dispatches pointermove with clientX, clientY" {
    var engine = try JsEngine.init(std.testing.allocator);
    defer engine.deinit();

    try bootstrap.init(&engine);

    // Set up a listener that captures the event
    var setup_result = try engine.eval(
        \\var __lastPointerEvent = null;
        \\var __canvas = document.createElement('canvas');
        \\__canvas.addEventListener('pointermove', function(e) {
        \\  __lastPointerEvent = e;
        \\});
    , "<test>");
    setup_result.deinit();

    const ctx = engine.context;
    const global = ctx.getGlobalObject();
    defer global.deinit(ctx);

    const js_window = global.getPropertyStr(ctx, "window");
    defer js_window.deinit(ctx);
    const js_document = global.getPropertyStr(ctx, "document");
    defer js_document.deinit(ctx);
    const js_canvas = global.getPropertyStr(ctx, "__canvas");
    defer js_canvas.deinit(ctx);

    var bridge = EventBridge.init(ctx, js_window, js_document, js_canvas);
    _ = &bridge;

    // Simulate a mouse move
    bridge.onMouseMove(100.0, 200.0);

    // Verify the event was received
    var r1 = try engine.eval("__lastPointerEvent !== null ? 1 : 0", "<test>");
    defer r1.deinit();
    try std.testing.expectEqual(@as(i32, 1), try r1.toInt32());

    var r2 = try engine.eval("__lastPointerEvent.clientX", "<test>");
    defer r2.deinit();
    try std.testing.expectEqual(@as(f64, 100.0), try r2.toFloat64());

    var r3 = try engine.eval("__lastPointerEvent.clientY", "<test>");
    defer r3.deinit();
    try std.testing.expectEqual(@as(f64, 200.0), try r3.toFloat64());

    var r4 = try engine.eval("__lastPointerEvent.type", "<test>");
    defer r4.deinit();
    const type_str = try r4.toCString();
    defer r4.freeCString(type_str);
    try std.testing.expectEqualStrings("pointermove", type_str);
}

test "EventBridge dispatches pointermove with movementX/Y" {
    var engine = try JsEngine.init(std.testing.allocator);
    defer engine.deinit();

    try bootstrap.init(&engine);

    var setup_result = try engine.eval(
        \\var __lastPointerEvent = null;
        \\var __canvas = document.createElement('canvas');
        \\__canvas.addEventListener('pointermove', function(e) {
        \\  __lastPointerEvent = e;
        \\});
    , "<test>");
    setup_result.deinit();

    const ctx = engine.context;
    const global = ctx.getGlobalObject();
    defer global.deinit(ctx);

    const js_window = global.getPropertyStr(ctx, "window");
    defer js_window.deinit(ctx);
    const js_document = global.getPropertyStr(ctx, "document");
    defer js_document.deinit(ctx);
    const js_canvas = global.getPropertyStr(ctx, "__canvas");
    defer js_canvas.deinit(ctx);

    var bridge = EventBridge.init(ctx, js_window, js_document, js_canvas);
    _ = &bridge;

    // First move — no previous position, movement should be 0
    bridge.onMouseMove(50.0, 50.0);

    var r1 = try engine.eval("__lastPointerEvent.movementX", "<test>");
    defer r1.deinit();
    try std.testing.expectEqual(@as(f64, 0.0), try r1.toFloat64());

    // Second move — should have movement relative to first position
    bridge.onMouseMove(70.0, 60.0);

    var r2 = try engine.eval("__lastPointerEvent.movementX", "<test>");
    defer r2.deinit();
    try std.testing.expectEqual(@as(f64, 20.0), try r2.toFloat64());

    var r3 = try engine.eval("__lastPointerEvent.movementY", "<test>");
    defer r3.deinit();
    try std.testing.expectEqual(@as(f64, 10.0), try r3.toFloat64());
}

test "EventBridge dispatches pointerdown/pointerup with button" {
    var engine = try JsEngine.init(std.testing.allocator);
    defer engine.deinit();

    try bootstrap.init(&engine);

    var setup_result = try engine.eval(
        \\var __pointerEvents = [];
        \\var __canvas = document.createElement('canvas');
        \\__canvas.addEventListener('pointerdown', function(e) {
        \\  __pointerEvents.push({ type: e.type, button: e.button });
        \\});
        \\__canvas.addEventListener('pointerup', function(e) {
        \\  __pointerEvents.push({ type: e.type, button: e.button });
        \\});
    , "<test>");
    setup_result.deinit();

    const ctx = engine.context;
    const global = ctx.getGlobalObject();
    defer global.deinit(ctx);

    const js_window = global.getPropertyStr(ctx, "window");
    defer js_window.deinit(ctx);
    const js_document = global.getPropertyStr(ctx, "document");
    defer js_document.deinit(ctx);
    const js_canvas = global.getPropertyStr(ctx, "__canvas");
    defer js_canvas.deinit(ctx);

    var bridge = EventBridge.init(ctx, js_window, js_document, js_canvas);
    _ = &bridge;

    // Simulate left mouse button press and release
    bridge.onMouseButton(GLFW_MOUSE_BUTTON_LEFT, GLFW_PRESS, 0);
    bridge.onMouseButton(GLFW_MOUSE_BUTTON_LEFT, GLFW_RELEASE, 0);

    var r1 = try engine.eval("__pointerEvents.length", "<test>");
    defer r1.deinit();
    try std.testing.expectEqual(@as(i32, 2), try r1.toInt32());

    var r2 = try engine.eval("__pointerEvents[0].type", "<test>");
    defer r2.deinit();
    const s2 = try r2.toCString();
    defer r2.freeCString(s2);
    try std.testing.expectEqualStrings("pointerdown", s2);

    var r3 = try engine.eval("__pointerEvents[0].button", "<test>");
    defer r3.deinit();
    try std.testing.expectEqual(@as(i32, 0), try r3.toInt32());

    var r4 = try engine.eval("__pointerEvents[1].type", "<test>");
    defer r4.deinit();
    const s4 = try r4.toCString();
    defer r4.freeCString(s4);
    try std.testing.expectEqualStrings("pointerup", s4);
}

test "EventBridge dispatches pointerdown with right button mapped correctly" {
    var engine = try JsEngine.init(std.testing.allocator);
    defer engine.deinit();

    try bootstrap.init(&engine);

    var setup_result = try engine.eval(
        \\var __lastButton = -1;
        \\var __canvas = document.createElement('canvas');
        \\__canvas.addEventListener('pointerdown', function(e) {
        \\  __lastButton = e.button;
        \\});
    , "<test>");
    setup_result.deinit();

    const ctx = engine.context;
    const global = ctx.getGlobalObject();
    defer global.deinit(ctx);

    const js_window = global.getPropertyStr(ctx, "window");
    defer js_window.deinit(ctx);
    const js_document = global.getPropertyStr(ctx, "document");
    defer js_document.deinit(ctx);
    const js_canvas = global.getPropertyStr(ctx, "__canvas");
    defer js_canvas.deinit(ctx);

    var bridge = EventBridge.init(ctx, js_window, js_document, js_canvas);
    _ = &bridge;

    // GLFW right button (1) should map to DOM button 2
    bridge.onMouseButton(GLFW_MOUSE_BUTTON_RIGHT, GLFW_PRESS, 0);

    var r = try engine.eval("__lastButton", "<test>");
    defer r.deinit();
    try std.testing.expectEqual(@as(i32, 2), try r.toInt32());
}

test "EventBridge dispatches wheel event with deltaY" {
    var engine = try JsEngine.init(std.testing.allocator);
    defer engine.deinit();

    try bootstrap.init(&engine);

    var setup_result = try engine.eval(
        \\var __lastWheelEvent = null;
        \\var __canvas = document.createElement('canvas');
        \\__canvas.addEventListener('wheel', function(e) {
        \\  __lastWheelEvent = e;
        \\});
    , "<test>");
    setup_result.deinit();

    const ctx = engine.context;
    const global = ctx.getGlobalObject();
    defer global.deinit(ctx);

    const js_window = global.getPropertyStr(ctx, "window");
    defer js_window.deinit(ctx);
    const js_document = global.getPropertyStr(ctx, "document");
    defer js_document.deinit(ctx);
    const js_canvas = global.getPropertyStr(ctx, "__canvas");
    defer js_canvas.deinit(ctx);

    var bridge = EventBridge.init(ctx, js_window, js_document, js_canvas);
    _ = &bridge;

    // Simulate scroll: GLFW +1 on Y (scroll up) => DOM deltaY should be -100
    bridge.onScroll(0, 1.0);

    var r1 = try engine.eval("__lastWheelEvent !== null ? 1 : 0", "<test>");
    defer r1.deinit();
    try std.testing.expectEqual(@as(i32, 1), try r1.toInt32());

    var r2 = try engine.eval("__lastWheelEvent.type", "<test>");
    defer r2.deinit();
    const s2 = try r2.toCString();
    defer r2.freeCString(s2);
    try std.testing.expectEqualStrings("wheel", s2);

    var r3 = try engine.eval("__lastWheelEvent.deltaY", "<test>");
    defer r3.deinit();
    try std.testing.expectEqual(@as(f64, -100.0), try r3.toFloat64());
}

test "EventBridge dispatches keydown/keyup events" {
    var engine = try JsEngine.init(std.testing.allocator);
    defer engine.deinit();

    try bootstrap.init(&engine);

    var setup_result = try engine.eval(
        \\var __keyEvents = [];
        \\document.addEventListener('keydown', function(e) {
        \\  __keyEvents.push({ type: e.type, key: e.key, code: e.code });
        \\});
        \\document.addEventListener('keyup', function(e) {
        \\  __keyEvents.push({ type: e.type, key: e.key, code: e.code });
        \\});
    , "<test>");
    setup_result.deinit();

    const ctx = engine.context;
    const global = ctx.getGlobalObject();
    defer global.deinit(ctx);

    const js_window = global.getPropertyStr(ctx, "window");
    defer js_window.deinit(ctx);
    const js_document = global.getPropertyStr(ctx, "document");
    defer js_document.deinit(ctx);

    // Canvas is not needed for keyboard events, but the bridge requires it
    var canvas_result = try engine.eval("document.createElement('canvas')", "<test>");
    defer canvas_result.deinit();

    var bridge = EventBridge.init(ctx, js_window, js_document, canvas_result.value);
    _ = &bridge;

    // Press and release 'A' key (GLFW key 65)
    bridge.onKey(65, 0, GLFW_PRESS, 0);
    bridge.onKey(65, 0, GLFW_RELEASE, 0);

    var r1 = try engine.eval("__keyEvents.length", "<test>");
    defer r1.deinit();
    try std.testing.expectEqual(@as(i32, 2), try r1.toInt32());

    var r2 = try engine.eval("__keyEvents[0].type", "<test>");
    defer r2.deinit();
    const s2 = try r2.toCString();
    defer r2.freeCString(s2);
    try std.testing.expectEqualStrings("keydown", s2);

    var r3 = try engine.eval("__keyEvents[0].key", "<test>");
    defer r3.deinit();
    const s3 = try r3.toCString();
    defer r3.freeCString(s3);
    try std.testing.expectEqualStrings("a", s3);

    var r4 = try engine.eval("__keyEvents[0].code", "<test>");
    defer r4.deinit();
    const s4 = try r4.toCString();
    defer r4.freeCString(s4);
    try std.testing.expectEqualStrings("KeyA", s4);

    var r5 = try engine.eval("__keyEvents[1].type", "<test>");
    defer r5.deinit();
    const s5 = try r5.toCString();
    defer r5.freeCString(s5);
    try std.testing.expectEqualStrings("keyup", s5);
}

test "EventBridge dispatches keydown with modifier keys" {
    var engine = try JsEngine.init(std.testing.allocator);
    defer engine.deinit();

    try bootstrap.init(&engine);

    var setup_result = try engine.eval(
        \\var __lastKeyEvent = null;
        \\document.addEventListener('keydown', function(e) {
        \\  __lastKeyEvent = e;
        \\});
    , "<test>");
    setup_result.deinit();

    const ctx = engine.context;
    const global = ctx.getGlobalObject();
    defer global.deinit(ctx);

    const js_window = global.getPropertyStr(ctx, "window");
    defer js_window.deinit(ctx);
    const js_document = global.getPropertyStr(ctx, "document");
    defer js_document.deinit(ctx);

    var canvas_result = try engine.eval("document.createElement('canvas')", "<test>");
    defer canvas_result.deinit();

    var bridge = EventBridge.init(ctx, js_window, js_document, canvas_result.value);
    _ = &bridge;

    // Press 'A' with Shift+Ctrl
    bridge.onKey(65, 0, GLFW_PRESS, GLFW_MOD_SHIFT | GLFW_MOD_CONTROL);

    var r1 = try engine.eval("__lastKeyEvent.shiftKey ? 1 : 0", "<test>");
    defer r1.deinit();
    try std.testing.expectEqual(@as(i32, 1), try r1.toInt32());

    var r2 = try engine.eval("__lastKeyEvent.ctrlKey ? 1 : 0", "<test>");
    defer r2.deinit();
    try std.testing.expectEqual(@as(i32, 1), try r2.toInt32());

    var r3 = try engine.eval("__lastKeyEvent.altKey ? 1 : 0", "<test>");
    defer r3.deinit();
    try std.testing.expectEqual(@as(i32, 0), try r3.toInt32());

    var r4 = try engine.eval("__lastKeyEvent.metaKey ? 1 : 0", "<test>");
    defer r4.deinit();
    try std.testing.expectEqual(@as(i32, 0), try r4.toInt32());
}

test "EventBridge dispatches resize event and updates innerWidth/Height" {
    var engine = try JsEngine.init(std.testing.allocator);
    defer engine.deinit();

    try bootstrap.init(&engine);

    var setup_result = try engine.eval(
        \\var __resized = false;
        \\window.addEventListener('resize', function(e) {
        \\  __resized = true;
        \\});
    , "<test>");
    setup_result.deinit();

    const ctx = engine.context;
    const global = ctx.getGlobalObject();
    defer global.deinit(ctx);

    const js_window = global.getPropertyStr(ctx, "window");
    defer js_window.deinit(ctx);
    const js_document = global.getPropertyStr(ctx, "document");
    defer js_document.deinit(ctx);

    var canvas_result = try engine.eval("document.createElement('canvas')", "<test>");
    defer canvas_result.deinit();

    var bridge = EventBridge.init(ctx, js_window, js_document, canvas_result.value);
    _ = &bridge;

    // Simulate resize
    bridge.onResize(1920, 1080);

    var r1 = try engine.eval("__resized ? 1 : 0", "<test>");
    defer r1.deinit();
    try std.testing.expectEqual(@as(i32, 1), try r1.toInt32());

    var r2 = try engine.eval("window.innerWidth", "<test>");
    defer r2.deinit();
    try std.testing.expectEqual(@as(i32, 1920), try r2.toInt32());

    var r3 = try engine.eval("window.innerHeight", "<test>");
    defer r3.deinit();
    try std.testing.expectEqual(@as(i32, 1080), try r3.toInt32());
}

test "EventBridge dispatches pointerenter/pointerleave" {
    var engine = try JsEngine.init(std.testing.allocator);
    defer engine.deinit();

    try bootstrap.init(&engine);

    var setup_result = try engine.eval(
        \\var __enterLeave = [];
        \\var __canvas = document.createElement('canvas');
        \\__canvas.addEventListener('pointerenter', function(e) {
        \\  __enterLeave.push(e.type);
        \\});
        \\__canvas.addEventListener('pointerleave', function(e) {
        \\  __enterLeave.push(e.type);
        \\});
    , "<test>");
    setup_result.deinit();

    const ctx = engine.context;
    const global = ctx.getGlobalObject();
    defer global.deinit(ctx);

    const js_window = global.getPropertyStr(ctx, "window");
    defer js_window.deinit(ctx);
    const js_document = global.getPropertyStr(ctx, "document");
    defer js_document.deinit(ctx);
    const js_canvas = global.getPropertyStr(ctx, "__canvas");
    defer js_canvas.deinit(ctx);

    var bridge = EventBridge.init(ctx, js_window, js_document, js_canvas);
    _ = &bridge;

    bridge.onCursorEnter(true);
    bridge.onCursorEnter(false);

    var r1 = try engine.eval("__enterLeave.length", "<test>");
    defer r1.deinit();
    try std.testing.expectEqual(@as(i32, 2), try r1.toInt32());

    var r2 = try engine.eval("__enterLeave[0]", "<test>");
    defer r2.deinit();
    const s2 = try r2.toCString();
    defer r2.freeCString(s2);
    try std.testing.expectEqualStrings("pointerenter", s2);

    var r3 = try engine.eval("__enterLeave[1]", "<test>");
    defer r3.deinit();
    const s3 = try r3.toCString();
    defer r3.freeCString(s3);
    try std.testing.expectEqualStrings("pointerleave", s3);
}

test "EventBridge dispatches special key (Escape)" {
    var engine = try JsEngine.init(std.testing.allocator);
    defer engine.deinit();

    try bootstrap.init(&engine);

    var setup_result = try engine.eval(
        \\var __lastKeyEvent = null;
        \\document.addEventListener('keydown', function(e) {
        \\  __lastKeyEvent = e;
        \\});
    , "<test>");
    setup_result.deinit();

    const ctx = engine.context;
    const global = ctx.getGlobalObject();
    defer global.deinit(ctx);

    const js_window = global.getPropertyStr(ctx, "window");
    defer js_window.deinit(ctx);
    const js_document = global.getPropertyStr(ctx, "document");
    defer js_document.deinit(ctx);

    var canvas_result = try engine.eval("document.createElement('canvas')", "<test>");
    defer canvas_result.deinit();

    var bridge = EventBridge.init(ctx, js_window, js_document, canvas_result.value);
    _ = &bridge;

    // Press Escape (GLFW key 256)
    bridge.onKey(256, 0, GLFW_PRESS, 0);

    var r1 = try engine.eval("__lastKeyEvent.key", "<test>");
    defer r1.deinit();
    const s1 = try r1.toCString();
    defer r1.freeCString(s1);
    try std.testing.expectEqualStrings("Escape", s1);

    var r2 = try engine.eval("__lastKeyEvent.code", "<test>");
    defer r2.deinit();
    const s2 = try r2.toCString();
    defer r2.freeCString(s2);
    try std.testing.expectEqualStrings("Escape", s2);
}

test "EventBridge dispatches arrow key (ArrowUp)" {
    var engine = try JsEngine.init(std.testing.allocator);
    defer engine.deinit();

    try bootstrap.init(&engine);

    var setup_result = try engine.eval(
        \\var __lastKeyEvent = null;
        \\document.addEventListener('keydown', function(e) {
        \\  __lastKeyEvent = e;
        \\});
    , "<test>");
    setup_result.deinit();

    const ctx = engine.context;
    const global = ctx.getGlobalObject();
    defer global.deinit(ctx);

    const js_window = global.getPropertyStr(ctx, "window");
    defer js_window.deinit(ctx);
    const js_document = global.getPropertyStr(ctx, "document");
    defer js_document.deinit(ctx);

    var canvas_result = try engine.eval("document.createElement('canvas')", "<test>");
    defer canvas_result.deinit();

    var bridge = EventBridge.init(ctx, js_window, js_document, canvas_result.value);
    _ = &bridge;

    // Press ArrowUp (GLFW key 265)
    bridge.onKey(265, 0, GLFW_PRESS, 0);

    var r1 = try engine.eval("__lastKeyEvent.key", "<test>");
    defer r1.deinit();
    const s1 = try r1.toCString();
    defer r1.freeCString(s1);
    try std.testing.expectEqualStrings("ArrowUp", s1);

    var r2 = try engine.eval("__lastKeyEvent.code", "<test>");
    defer r2.deinit();
    const s2 = try r2.toCString();
    defer r2.freeCString(s2);
    try std.testing.expectEqualStrings("ArrowUp", s2);
}

test "EventBridge pointer events include pointerType mouse" {
    var engine = try JsEngine.init(std.testing.allocator);
    defer engine.deinit();

    try bootstrap.init(&engine);

    var setup_result = try engine.eval(
        \\var __lastPointerType = null;
        \\var __canvas = document.createElement('canvas');
        \\__canvas.addEventListener('pointermove', function(e) {
        \\  __lastPointerType = e.pointerType;
        \\});
    , "<test>");
    setup_result.deinit();

    const ctx = engine.context;
    const global = ctx.getGlobalObject();
    defer global.deinit(ctx);

    const js_window = global.getPropertyStr(ctx, "window");
    defer js_window.deinit(ctx);
    const js_document = global.getPropertyStr(ctx, "document");
    defer js_document.deinit(ctx);
    const js_canvas = global.getPropertyStr(ctx, "__canvas");
    defer js_canvas.deinit(ctx);

    var bridge = EventBridge.init(ctx, js_window, js_document, js_canvas);
    _ = &bridge;

    bridge.onMouseMove(10.0, 20.0);

    var r = try engine.eval("__lastPointerType", "<test>");
    defer r.deinit();
    const s = try r.toCString();
    defer r.freeCString(s);
    try std.testing.expectEqualStrings("mouse", s);
}
