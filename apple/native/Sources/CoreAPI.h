#pragma once
#include "libretro.h"
extern __typeof__(retro_init) mgba_retro_init;
extern __typeof__(retro_deinit) mgba_retro_deinit;
extern __typeof__(retro_set_environment) mgba_retro_set_environment;
extern __typeof__(retro_set_video_refresh) mgba_retro_set_video_refresh;
extern __typeof__(retro_set_audio_sample) mgba_retro_set_audio_sample;
extern __typeof__(retro_set_audio_sample_batch) mgba_retro_set_audio_sample_batch;
extern __typeof__(retro_set_input_poll) mgba_retro_set_input_poll;
extern __typeof__(retro_set_input_state) mgba_retro_set_input_state;
extern __typeof__(retro_load_game) mgba_retro_load_game;
extern __typeof__(retro_unload_game) mgba_retro_unload_game;
extern __typeof__(retro_set_controller_port_device) mgba_retro_set_controller_port_device;
extern __typeof__(retro_get_system_av_info) mgba_retro_get_system_av_info;
extern __typeof__(retro_run) mgba_retro_run;
extern __typeof__(retro_reset) mgba_retro_reset;
extern __typeof__(retro_serialize_size) mgba_retro_serialize_size;
extern __typeof__(retro_serialize) mgba_retro_serialize;
extern __typeof__(retro_unserialize) mgba_retro_unserialize;
extern __typeof__(retro_get_memory_size) mgba_retro_get_memory_size;
extern __typeof__(retro_get_memory_data) mgba_retro_get_memory_data;
extern __typeof__(retro_get_system_info) mgba_retro_get_system_info;
typedef struct {
    __typeof__(retro_get_system_info) *get_system_info;
    __typeof__(retro_init) *init;
    __typeof__(retro_deinit) *deinit;
    __typeof__(retro_set_environment) *set_environment;
    __typeof__(retro_set_video_refresh) *set_video_refresh;
    __typeof__(retro_set_audio_sample) *set_audio_sample;
    __typeof__(retro_set_audio_sample_batch) *set_audio_sample_batch;
    __typeof__(retro_set_input_poll) *set_input_poll;
    __typeof__(retro_set_input_state) *set_input_state;
    __typeof__(retro_load_game) *load_game;
    __typeof__(retro_unload_game) *unload_game;
    __typeof__(retro_set_controller_port_device) *set_controller_port_device;
    __typeof__(retro_get_system_av_info) *get_system_av_info;
    __typeof__(retro_run) *run;
    __typeof__(retro_reset) *reset;
    __typeof__(retro_serialize_size) *serialize_size;
    __typeof__(retro_serialize) *serialize;
    __typeof__(retro_unserialize) *unserialize;
    __typeof__(retro_get_memory_size) *get_memory_size;
    __typeof__(retro_get_memory_data) *get_memory_data;
    __typeof__(retro_cheat_reset) *cheat_reset;
    __typeof__(retro_cheat_set) *cheat_set;
    void (*prepare_unload)(void);
} VetaCoreAPI;
#ifndef VETA_JIT_LAB
static const VetaCoreAPI nesAPI={.get_system_info=retro_get_system_info,.init=retro_init,.deinit=retro_deinit,.set_environment=retro_set_environment,.set_video_refresh=retro_set_video_refresh,.set_audio_sample=retro_set_audio_sample,.set_audio_sample_batch=retro_set_audio_sample_batch,.set_input_poll=retro_set_input_poll,.set_input_state=retro_set_input_state,.load_game=retro_load_game,.unload_game=retro_unload_game,.set_controller_port_device=retro_set_controller_port_device,.get_system_av_info=retro_get_system_av_info,.run=retro_run,.reset=retro_reset,.serialize_size=retro_serialize_size,.serialize=retro_serialize,.unserialize=retro_unserialize,.get_memory_size=retro_get_memory_size,.get_memory_data=retro_get_memory_data,.cheat_reset=retro_cheat_reset,.cheat_set=retro_cheat_set};
static const VetaCoreAPI mgbaAPI={.get_system_info=mgba_retro_get_system_info,.init=mgba_retro_init,.deinit=mgba_retro_deinit,.set_environment=mgba_retro_set_environment,.set_video_refresh=mgba_retro_set_video_refresh,.set_audio_sample=mgba_retro_set_audio_sample,.set_audio_sample_batch=mgba_retro_set_audio_sample_batch,.set_input_poll=mgba_retro_set_input_poll,.set_input_state=mgba_retro_set_input_state,.load_game=mgba_retro_load_game,.unload_game=mgba_retro_unload_game,.set_controller_port_device=mgba_retro_set_controller_port_device,.get_system_av_info=mgba_retro_get_system_av_info,.run=mgba_retro_run,.reset=mgba_retro_reset,.serialize_size=mgba_retro_serialize_size,.serialize=mgba_retro_serialize,.unserialize=mgba_retro_unserialize,.get_memory_size=mgba_retro_get_memory_size,.get_memory_data=mgba_retro_get_memory_data};

#endif
const VetaCoreAPI *veta_external_core(unsigned console);
const VetaCoreAPI *veta_external_core_mode(unsigned console,bool interpreter);
