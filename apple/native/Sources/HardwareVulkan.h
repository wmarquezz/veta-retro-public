#pragma once
#include <stdbool.h>
#include <stdint.h>
#include "libretro.h"
#ifdef __cplusplus
extern "C" {
#endif
// Cumulative wall-clock timings in nanoseconds, reset only after the previous
// core has been unloaded. Readback contains its submit/wait/CPU conversion;
// callback waits and queue-lock contention may overlap other core workers.
typedef struct {
    uint64_t read_count,read_failures,read_ns;
    uint64_t submit_count,submit_ns;
    uint64_t wait_count,wait_ns;
    uint64_t callback_wait_count,callback_wait_ns;
    uint64_t lock_count,lock_ns;
    uint64_t convert_count,convert_ns;
} VetaVulkanProfile;
void veta_vk_profile_reset(bool enabled);
VetaVulkanProfile veta_vk_profile_snapshot(void);
bool veta_vk_setup(struct retro_hw_render_callback *request);
bool veta_vk_environment(unsigned command,void *data);
bool veta_vk_active(void);
void veta_vk_begin(void);
bool veta_vk_read(uint32_t *pixels,unsigned width,unsigned height);
void veta_vk_release_core(void);
void veta_vk_destroy(void);
#ifdef __cplusplus
}
#endif
