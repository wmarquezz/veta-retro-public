"""Bound terminal libretro RunLoop failures without taking over core cleanup.

Timing is intentionally unchanged: ARM11 268111856 / 4481136 ticks per
VBlank = 59.83122493939037 Hz, while libretro currently advertises 60 Hz.
HLE audio produces 160 stereo pairs per 160*8192 ticks (32728.498046875 Hz),
advertising 32728 Hz. Correcting this small drift needs a separate baseline;
it cannot explain large underrun percentages.
"""


def apply(source, replace):
    path = source / 'src/citra_libretro/citra_libretro.cpp'
    replace(path, '    bool game_loaded = false;', '''    bool game_loaded = false;
    // VETA: stop CPU execution after a terminal error until an explicit reload/reset.
    // Keep game_loaded intact: context teardown and retro_unload_game still own cleanup.
    bool terminal_run_error = false;''')
    replace(path, 'void retro_run() {', '''void retro_run() {
    if (emu_instance->terminal_run_error) {
        return;
    }''')
    replace(path, '''            LibRetro::DisplayMessage(msg.c_str());
        }
    }
}

static void setup_memory_maps()''', '''            LibRetro::DisplayMessage(msg.c_str());
            // Upstream explicitly allows continuing after a previous shader-cache crash.
            // Other failures need not produce another frame: waiting for one can spin forever.
            if (result != Core::System::ResultStatus::ErrorShaderCacheCrash) {
                emu_instance->terminal_run_error = true;
                LibRetro::Shutdown();
                return;
            }
        }
    }
}

static void setup_memory_maps()''')
    replace(path, '''void retro_reset() {
    LOG_DEBUG''', '''void retro_reset() {
    emu_instance->terminal_run_error = false;
    LOG_DEBUG''')
    replace(path, '''bool retro_load_game(const struct retro_game_info* info) {
    LOG_INFO''', '''bool retro_load_game(const struct retro_game_info* info) {
    emu_instance->terminal_run_error = false;
    LOG_INFO''')
