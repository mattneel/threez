#include "dawn/native/DawnNative.h"
#include "dawn/webgpu.h"
#if defined(__ANDROID__)
#include <android/log.h>
#endif
#include <assert.h>
#include <inttypes.h>
#include <stdio.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct DawnNativeInstanceImpl* DawnNativeInstance;

static void dniLogLine(const char* fmt, ...) {
    char buffer[1024];
    va_list args;
    va_start(args, fmt);
    vsnprintf(buffer, sizeof(buffer), fmt, args);
    va_end(args);
#if defined(__ANDROID__)
    __android_log_write(ANDROID_LOG_INFO, "threez", buffer);
#else
    fprintf(stderr, "%s\n", buffer);
#endif
}

static const char* dniBackendTypeName(WGPUBackendType backend) {
    switch (backend) {
        case WGPUBackendType_Undefined: return "Undefined";
        case WGPUBackendType_Null: return "Null";
        case WGPUBackendType_WebGPU: return "WebGPU";
        case WGPUBackendType_D3D11: return "D3D11";
        case WGPUBackendType_D3D12: return "D3D12";
        case WGPUBackendType_Metal: return "Metal";
        case WGPUBackendType_Vulkan: return "Vulkan";
        case WGPUBackendType_OpenGL: return "OpenGL";
        case WGPUBackendType_OpenGLES: return "OpenGLES";
        default: return "UnknownBackend";
    }
}

static const char* dniAdapterTypeName(WGPUAdapterType type) {
    switch (type) {
        case WGPUAdapterType_DiscreteGPU: return "DiscreteGPU";
        case WGPUAdapterType_IntegratedGPU: return "IntegratedGPU";
        case WGPUAdapterType_CPU: return "CPU";
        case WGPUAdapterType_Unknown: return "Unknown";
        default: return "UnknownAdapter";
    }
}

DawnNativeInstance dniCreate(void) {
    return reinterpret_cast<DawnNativeInstance>(new dawn::native::Instance());
}

void dniDestroy(DawnNativeInstance dni) {
    assert(dni);
    delete reinterpret_cast<dawn::native::Instance*>(dni);
}

WGPUInstance dniGetWgpuInstance(DawnNativeInstance dni) {
    assert(dni);
    return reinterpret_cast<dawn::native::Instance*>(dni)->Get();
}

void dniDiscoverDefaultAdapters(DawnNativeInstance dni) {
    assert(dni);
    dawn::native::Instance* instance = reinterpret_cast<dawn::native::Instance*>(dni);
    (void)instance->EnumerateAdapters(static_cast<const WGPURequestAdapterOptions*>(nullptr));
}

void dniLogAdapters(DawnNativeInstance dni, const WGPURequestAdapterOptions* options, const char* label) {
    assert(dni);
    dawn::native::Instance* instance = reinterpret_cast<dawn::native::Instance*>(dni);
    const std::vector<dawn::native::Adapter> adapters = instance->EnumerateAdapters(options);

    dniLogLine(
        "dawn adapters[%s]: count=%zu backend=%d compatibleSurface=%p power=%d",
        label ? label : "unnamed",
        adapters.size(),
        options ? static_cast<int>(options->backendType) : -1,
        options ? static_cast<void*>(options->compatibleSurface) : nullptr,
        options ? static_cast<int>(options->powerPreference) : -1
    );

    for (size_t i = 0; i < adapters.size(); ++i) {
        WGPUAdapter adapter = adapters[i].Get();
        WGPUAdapterInfo info = {};
        info.nextInChain = nullptr;
        const WGPUStatus status = wgpuAdapterGetInfo(adapter, &info);
        if (status != WGPUStatus_Success) {
            dniLogLine("dawn adapters[%s][%zu]: getInfo failed status=%d", label ? label : "unnamed", i, static_cast<int>(status));
            continue;
        }

        const char* device = info.device.data ? info.device.data : "";
        const char* desc = info.description.data ? info.description.data : "";
        dniLogLine(
            "dawn adapters[%s][%zu]: backend=%s type=%s vendor=%.*s device=%.*s desc=%.*s vendorId=%" PRIu32 " deviceId=%" PRIu32,
            label ? label : "unnamed",
            i,
            dniBackendTypeName(info.backendType),
            dniAdapterTypeName(info.adapterType),
            static_cast<int>(info.vendor.length), info.vendor.data ? info.vendor.data : "",
            static_cast<int>(info.device.length), device,
            static_cast<int>(info.description.length), desc,
            info.vendorID,
            info.deviceID
        );
        wgpuAdapterInfoFreeMembers(info);
    }
}

WGPUAdapter dniGetFirstAdapter(DawnNativeInstance dni, const WGPURequestAdapterOptions* options) {
    assert(dni);
    dawn::native::Instance* instance = reinterpret_cast<dawn::native::Instance*>(dni);
    const std::vector<dawn::native::Adapter> adapters = instance->EnumerateAdapters(options);
    if (adapters.empty()) {
        return nullptr;
    }

    WGPUAdapter adapter = adapters[0].Get();
    wgpuAdapterAddRef(adapter);
    return adapter;
}

WGPUDevice dniCreateDeviceFromAdapter(WGPUAdapter adapter, const WGPUDeviceDescriptor* descriptor) {
    if (adapter == nullptr) {
        return nullptr;
    }

    dawn::native::Adapter native_adapter(reinterpret_cast<dawn::native::AdapterBase*>(adapter));
    return native_adapter.CreateDevice(descriptor);
}

const DawnProcTable* dnGetProcs(void) {
    return &dawn::native::GetProcs();
}

#ifdef __cplusplus
}
#endif
