const std = @import("std");

pub const c = @cImport({
    @cInclude("dawn/webgpu.h");
});

const log = std.log.scoped(.dawn_raw);

pub const WaitError = error{
    WaitFailed,
    AdapterRequestFailed,
    DeviceRequestFailed,
};

pub fn stringViewToSlice(view: c.WGPUStringView) []const u8 {
    if (view.data == null) return "";
    return view.data[0..view.length];
}

pub fn waitFuture(instance: c.WGPUInstance, future: c.WGPUFuture) WaitError!void {
    var wait_info = c.WGPUFutureWaitInfo{
        .future = future,
        .completed = c.WGPU_FALSE,
    };

    while (true) {
        const status = c.wgpuInstanceWaitAny(instance, 1, &wait_info, 50_000_000);
        switch (status) {
            c.WGPUWaitStatus_Success => {
                if (wait_info.completed != c.WGPU_FALSE) return;
                c.wgpuInstanceProcessEvents(instance);
            },
            c.WGPUWaitStatus_TimedOut => {
                c.wgpuInstanceProcessEvents(instance);
            },
            else => return error.WaitFailed,
        }
    }
}

pub fn requestAdapterSync(
    instance: c.WGPUInstance,
    options: ?*const c.WGPURequestAdapterOptions,
) WaitError!c.WGPUAdapter {
    const State = struct {
        status: c.WGPURequestAdapterStatus = 0,
        adapter: c.WGPUAdapter = null,
    };

    const callback = struct {
        fn call(
            status: c.WGPURequestAdapterStatus,
            adapter: c.WGPUAdapter,
            message: c.WGPUStringView,
            userdata1: ?*anyopaque,
            userdata2: ?*anyopaque,
        ) callconv(.c) void {
            _ = userdata2;
            if (status != c.WGPURequestAdapterStatus_Success) {
                log.err("requestAdapter failed: {s}", .{stringViewToSlice(message)});
            }
            const state = @as(*State, @ptrCast(@alignCast(userdata1.?)));
            state.status = status;
            state.adapter = adapter;
        }
    }.call;

    var state = State{};
    const callback_info = c.WGPURequestAdapterCallbackInfo{
        .nextInChain = null,
        .mode = c.WGPUCallbackMode_AllowProcessEvents,
        .callback = callback,
        .userdata1 = &state,
        .userdata2 = null,
    };
    const future = c.wgpuInstanceRequestAdapter(instance, options, callback_info);
    try waitFuture(instance, future);

    if (state.status != c.WGPURequestAdapterStatus_Success or state.adapter == null) {
        log.err("requestAdapter final status={d}", .{state.status});
        return error.AdapterRequestFailed;
    }
    return state.adapter;
}

pub fn requestDeviceSync(
    instance: c.WGPUInstance,
    adapter: c.WGPUAdapter,
    descriptor: ?*const c.WGPUDeviceDescriptor,
) WaitError!c.WGPUDevice {
    const State = struct {
        status: c.WGPURequestDeviceStatus = 0,
        device: c.WGPUDevice = null,
    };

    const callback = struct {
        fn call(
            status: c.WGPURequestDeviceStatus,
            device: c.WGPUDevice,
            message: c.WGPUStringView,
            userdata1: ?*anyopaque,
            userdata2: ?*anyopaque,
        ) callconv(.c) void {
            _ = userdata2;
            if (status != c.WGPURequestDeviceStatus_Success) {
                log.err("requestDevice failed: {s}", .{stringViewToSlice(message)});
            }
            const state = @as(*State, @ptrCast(@alignCast(userdata1.?)));
            state.status = status;
            state.device = device;
        }
    }.call;

    var state = State{};
    const callback_info = c.WGPURequestDeviceCallbackInfo{
        .nextInChain = null,
        .mode = c.WGPUCallbackMode_AllowProcessEvents,
        .callback = callback,
        .userdata1 = &state,
        .userdata2 = null,
    };
    const future = c.wgpuAdapterRequestDevice(adapter, descriptor, callback_info);
    try waitFuture(instance, future);

    if (state.status != c.WGPURequestDeviceStatus_Success or state.device == null) {
        log.err("requestDevice final status={d}", .{state.status});
        return error.DeviceRequestFailed;
    }
    return state.device;
}
