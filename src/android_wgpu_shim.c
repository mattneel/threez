#include "dawn/webgpu.h"

#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

typedef void (*ThreezErrorCallback)(WGPUErrorType err_type, const char* message, void* userdata);

typedef struct ThreezCompatSwapChainDescriptor {
    const WGPUChainedStruct* nextInChain;
    const char* label;
    uint32_t usage;
    WGPUTextureFormat format;
    uint32_t width;
    uint32_t height;
    uint32_t presentMode;
} ThreezCompatSwapChainDescriptor;

typedef struct ThreezCompatSwapChainImpl {
    WGPUDevice device;
    WGPUSurface surface;
    WGPUSurfaceConfiguration config;
    WGPUTexture currentTexture;
    bool hasCurrentTexture;
} ThreezCompatSwapChainImpl;

typedef ThreezCompatSwapChainImpl* WGPUSwapChain;

static WGPUStringView threezStringView(const char* s) {
    WGPUStringView view;
    if (s) {
        view.data = s;
        view.length = strlen(s);
    } else {
        view.data = NULL;
        view.length = 0;
    }
    return view;
}

static WGPUPresentMode threezPresentModeCompat(uint32_t old_mode) {
    switch (old_mode) {
        case 0:
            return WGPUPresentMode_Immediate;
        case 1:
            return WGPUPresentMode_Mailbox;
        case 2:
            return WGPUPresentMode_Fifo;
        default:
            return WGPUPresentMode_Fifo;
    }
}

static void threezSwapChainDropCurrentTexture(WGPUSwapChain swap_chain) {
    if (swap_chain && swap_chain->hasCurrentTexture && swap_chain->currentTexture) {
        wgpuTextureRelease(swap_chain->currentTexture);
        swap_chain->currentTexture = NULL;
        swap_chain->hasCurrentTexture = false;
    }
}

WGPUShaderModule threezCreateShaderModuleShim(WGPUDevice device, const char* label, const char* code) {
    WGPUShaderSourceWGSL wgsl_desc;
    wgsl_desc.chain.next = NULL;
    wgsl_desc.chain.sType = WGPUSType_ShaderSourceWGSL;
    wgsl_desc.code = threezStringView(code);

    WGPUShaderModuleDescriptor desc;
    desc.nextInChain = &wgsl_desc.chain;
    desc.label = threezStringView(label);

    return wgpuDeviceCreateShaderModule(device, &desc);
}

void wgpuDeviceSetUncapturedErrorCallback(WGPUDevice device, ThreezErrorCallback callback, void* userdata) {
    (void)device;
    (void)callback;
    (void)userdata;
}

WGPUSwapChain wgpuDeviceCreateSwapChain(
    WGPUDevice device,
    WGPUSurface surface,
    const ThreezCompatSwapChainDescriptor* descriptor
) {
    if (!device || !surface || !descriptor) {
        return NULL;
    }

    WGPUSwapChain swap_chain = (WGPUSwapChain)calloc(1, sizeof(ThreezCompatSwapChainImpl));
    if (!swap_chain) {
        return NULL;
    }

    swap_chain->device = device;
    swap_chain->surface = surface;
    swap_chain->config.nextInChain = NULL;
    swap_chain->config.device = device;
    swap_chain->config.format = descriptor->format;
    swap_chain->config.usage = (WGPUTextureUsage)descriptor->usage;
    swap_chain->config.width = descriptor->width;
    swap_chain->config.height = descriptor->height;
    swap_chain->config.viewFormatCount = 0;
    swap_chain->config.viewFormats = NULL;
    swap_chain->config.alphaMode = WGPUCompositeAlphaMode_Auto;
    swap_chain->config.presentMode = threezPresentModeCompat(descriptor->presentMode);
    swap_chain->currentTexture = NULL;
    swap_chain->hasCurrentTexture = false;

    wgpuSurfaceConfigure(surface, &swap_chain->config);
    return swap_chain;
}

WGPUTextureView wgpuSwapChainGetCurrentTextureView(WGPUSwapChain swap_chain) {
    if (!swap_chain) {
        return NULL;
    }

    threezSwapChainDropCurrentTexture(swap_chain);

    WGPUSurfaceTexture surface_texture;
    memset(&surface_texture, 0, sizeof(surface_texture));
    wgpuSurfaceGetCurrentTexture(swap_chain->surface, &surface_texture);
    if (surface_texture.status != WGPUSurfaceGetCurrentTextureStatus_SuccessOptimal &&
        surface_texture.status != WGPUSurfaceGetCurrentTextureStatus_SuccessSuboptimal) {
        if (surface_texture.texture) {
            wgpuTextureRelease(surface_texture.texture);
        }
        return NULL;
    }
    if (!surface_texture.texture) {
        return NULL;
    }

    swap_chain->currentTexture = surface_texture.texture;
    swap_chain->hasCurrentTexture = true;
    return wgpuTextureCreateView(surface_texture.texture, NULL);
}

void wgpuSwapChainPresent(WGPUSwapChain swap_chain) {
    if (!swap_chain) {
        return;
    }

    (void)wgpuSurfacePresent(swap_chain->surface);
    threezSwapChainDropCurrentTexture(swap_chain);
}

void wgpuSwapChainRelease(WGPUSwapChain swap_chain) {
    if (!swap_chain) {
        return;
    }

    threezSwapChainDropCurrentTexture(swap_chain);
    wgpuSurfaceUnconfigure(swap_chain->surface);
    free(swap_chain);
}
