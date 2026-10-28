#include <fenv.h>
#pragma once
#include <stdint.h>
#include <stddef.h>
#include <stdbool.h>
bool veta_load(const char *path, const char *directory, const char *region);
bool veta_load_console(const char *path, const char *directory, const char *region, unsigned console);
bool veta_load_system(const char *path,const char *saveDirectory,const char *systemDirectory,const char *region,unsigned console);
bool veta_load_system_mode(const char *path,const char *saveDirectory,const char *systemDirectory,const char *region,unsigned console,bool interpreter);
void veta_unload(void);
void veta_run(void);
bool veta_shutdown_requested(void);
// DEBUG-only opt-in for the NEXT load. Only 3DS (console16) is instrumented.
// Snapshot survives unload for close telemetry and resets on each new load.
// core_run_ns includes video_read_ns; these are nested, not additive timings.
typedef struct {
    bool enabled;
    uint64_t core_run_count,core_run_ns,hardware_begin_ns;
    uint64_t video_read_count,video_read_failures,video_read_ns;
    uint64_t queue_submit_count,queue_submit_ns,queue_wait_count,queue_wait_ns;
    uint64_t callback_wait_count,callback_wait_ns,queue_lock_count,queue_lock_ns;
    uint64_t cpu_convert_count,cpu_convert_ns;
} VetaRunProfile;
void veta_run_profile_enable(bool enabled);
VetaRunProfile veta_run_profile_snapshot(void);
// GC/Wii GL uses hybrid readback: defer intermediate runs, capture the last
// predicted run in its original callback. No hint means immediate readback.
// Profiling is off normally. DEBUG VETA_PERF165_DEFER_GC_READBACK overrides:
// "0" immediate; "profile" immediate+profile; "1" all-deferred+profile;
// "hybrid" hybrid+profile. Missing/unknown values preserve normal behavior.
// Owner thread only. Counts survive unload and reset on the next load.
typedef struct {
    bool profiling,enabled,pending;
    uint64_t callbacks,reads,deferred,superseded,failures,read_ns;
} VetaVideoReadbackProfile;
VetaVideoReadbackProfile veta_video_readback_profile(void);
// Owner thread, next veta_run only. No effect outside GC/Wii hybrid mode.
// A false prediction remains safe: veta_video materializes any pending image.
void veta_video_readback_hint(bool final_frame);
// GC/Wii GL publication on physical development devices; explicit
// VETA_PERF165_SHARED_GL=0 selects CPU readback. Owner thread acquisition; each
// consumer must release its lease after GPU completion (or before submission).
// texture is an unretained Objective-C MTLTexture pointer valid while leased.
typedef struct {
    void *lease, *texture;
    unsigned width, height;
    uint64_t generation, sequence;
} VetaSharedFrame;
typedef struct {
    bool requested, active;
    uint64_t publications, acquisitions, fallbacks, snapshots;
    uint64_t generation, sequence; // Latest valid publication in the current pool, or 0.
    uint64_t allocated_bytes, retired_bytes;
} VetaSharedVideoProfile;
VetaSharedFrame veta_shared_frame_acquire(void *metalDevice);
void veta_shared_frame_release(void *lease);
VetaSharedVideoProfile veta_shared_video_profile(void);

void veta_reset(void);
void veta_set_input(unsigned port, uint16_t mask);
const uint32_t *veta_video(void);
unsigned veta_width(void);
unsigned veta_height(void);
double veta_fps(void);
double veta_sample_rate(void);
uint64_t veta_frame_count(void);
uint64_t veta_audio_count(void);
uint64_t veta_audio_nonzero(void);
uint64_t veta_audio_delivered(void);
uint64_t veta_audio_underruns(void);
uint64_t veta_audio_dropped(void);
unsigned veta_audio_queued(void);
size_t veta_state_size(void);
bool veta_save_state(void *data, size_t size);
bool veta_load_state(const void *data, size_t size);
size_t veta_ram_size(void);
void veta_read_ram(void *data, size_t size);
bool veta_write_ram(const void *data, size_t size);
void veta_audio_read(float *left, float *right, unsigned count, float volume);
void veta_audio_clear(void);
uint16_t veta_input_mask(unsigned port);

size_t veta_rtc_size(void);
void veta_read_rtc(void *data,size_t size);
bool veta_write_rtc(const void *data,size_t size);

void veta_set_pointer(int16_t x,int16_t y,bool pressed);
void veta_set_analog(unsigned port,unsigned stick,int16_t x,int16_t y);

// Pending options are consumed exactly once by the next core load.
void veta_options_clear(void);
bool veta_option_set(const char *key,const char *value);
unsigned veta_max_players(unsigned console);
unsigned veta_rumble_strength(unsigned port,unsigned effect);
void veta_rumble_clear(void);

// NES only. Validates the entire list before replacing, because FCEUmm adds
// codes regardless of the enabled argument. Other cores return false.
bool veta_nes_cheat_valid(const char *code);
bool veta_nes_cheats_replace(const char *const *codes,size_t count);
