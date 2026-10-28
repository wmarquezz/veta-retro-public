#!/usr/bin/env python3
"""Offline source contract: compile extracted real callbacks with simulated CPU events.

Does not build Azahar, execute a game, or change the generated source tree.
The pre-patch case demonstrates the unbounded loop using a bounded fake CPU.
"""
from pathlib import Path
import argparse
import hashlib
import re
import subprocess
import tempfile

from patch_azahar_runtime import apply
from patch_jit_cores import replace


def function(text, signature):
    start = text.index(signature)
    brace = text.index('{', start)
    depth = 1
    end = brace + 1
    while depth:
        depth += (text[end] == '{') - (text[end] == '}')
        end += 1
    return text[start:end]


def harness(text, environment, enum, fixed):
    statuses = re.findall(r'^\s*(\w+)\s*(?:,|(?=///<))', enum, re.M)
    assert 'ErrorUnknown' in statuses and 'ShutdownRequested' in statuses
    terminals = [s for s in statuses if s not in ('Success', 'ErrorShaderCacheCrash')]
    callbacks = '\n'.join(function(text, name) for name in
                          ['void retro_run()', 'void retro_unload_game()', 'void retro_reset()'])
    shutdown = function(environment, 'bool Shutdown()')
    declarations = text[text.index('    bool game_loaded = false;'):
                        text.index('    struct retro_hw_render_callback hw_render{};')]
    return r'''
#include <cassert>
#include <cstdint>
#include <iostream>
#include <stdexcept>
#include <string>
#define LOG_DEBUG(...) ((void)0)
using u32 = uint32_t;
constexpr unsigned RETRO_DEVICE_JOYPAD=1, RETRO_DEVICE_ID_JOYPAD_L3=14;
constexpr unsigned RETRO_ENVIRONMENT_SHUTDOWN=7;
int calls=0, cleanups=0, requests=0, messages=0, frames=0;
bool submitted=false, recover_once=false, accept_shutdown=true;
struct Window {
    void UpdateLayout() {}
    bool HasSubmittedFrame() { bool old=submitted; submitted=false; return old; }
} window;
struct CitraLibRetro {
''' + declarations + r'''
    Window* emu_window=&window;
} instance;
auto* emu_instance=&instance;
namespace Core {
class System {
public:
''' + enum + r'''
    static System& GetInstance() { static System system; return system; }
    ResultStatus result=ResultStatus::Success;
    ResultStatus RunLoop() {
        if (++calls>8) throw std::runtime_error("bounded-test-detected-unbounded-loop");
        if (recover_once) { recover_once=false; return ResultStatus::ErrorShaderCacheCrash; }
        if (result==ResultStatus::Success) {submitted=true; ++frames;}
        return result;
    }
    std::string GetStatusDetails() {return "simulated failure";}
    void ApplySettings() {}
    void RegisterCoreLoopThreadId() {}
    void Shutdown() {++cleanups;}
};
}
namespace FileUtil {
enum class UserPath {ShaderDir};
std::string GetUserPath(UserPath) {return "private-test-cache/";}
}
namespace Settings {struct {bool swap_screen=false;} values;}
namespace AudioCore {
struct Mic {void PollMicrophone() {}};
Mic* GetLibRetroInput() {return nullptr;}
}
namespace LibRetro {
struct {std::string swap_screen_mode="Toggle";} settings;
void PollInput() {}
void UploadVideoFrame(const void*, unsigned, unsigned, unsigned) {}
bool HasUpdatedConfig() {return false;}
void ParseCoreOptions() {}
int CheckInput(unsigned,unsigned,unsigned,unsigned) {return 0;}
std::string FetchVariable(const char*, const char* fallback) {return fallback;}
void DisplayMessage(const char*) {++messages;}
bool environ_cb(unsigned cmd, void* data) {
    assert(cmd==RETRO_ENVIRONMENT_SHUTDOWN && data==nullptr);
    assert(emu_instance->game_loaded); // The core remains owned until unload.
    assert(cleanups==0); // No reentrant destruction during retro_run.
    ++requests; return accept_shutdown;
}
''' + shutdown + r'''
}
bool do_load_game() {return true;}
''' + callbacks + r'''
void clear() {
    instance=CitraLibRetro{}; instance.game_loaded=true;
    calls=cleanups=requests=messages=frames=0;
    submitted=recover_once=false;
    Core::System::GetInstance().result=Core::System::ResultStatus::Success;
}
int main() {
    constexpr bool fixed=''' + ('true' if fixed else 'false') + r''';
    using Status=Core::System::ResultStatus;
    for (bool accepted: {false,true}) {
      accept_shutdown=accepted;
      for (auto terminal: {''' + ','.join('Status::' + s for s in terminals) + r'''}) {
        clear(); Core::System::GetInstance().result=terminal;
        bool bounded_failure=false;
        try {retro_run();} catch (const std::runtime_error&) {bounded_failure=true;}
        if (!fixed) {
            assert(bounded_failure && calls==9 && requests==0 && cleanups==0);
        } else {
            assert(!bounded_failure && calls==1 && requests==1 && messages==1);
            assert(cleanups==0 && emu_instance->game_loaded);
            retro_run(); assert(calls==1 && requests==1); // Even if frontend declined shutdown.
        }
        retro_unload_game(); assert(cleanups==1);
      }
    }
    clear(); recover_once=true;
    retro_run(); assert(calls==2 && frames==1 && requests==0 && messages==1);
    retro_run(); assert(calls==3 && frames==2 && requests==0);
    retro_unload_game(); assert(cleanups==1);
    if (fixed) {
        clear(); Core::System::GetInstance().result=Status::ErrorNotInitialized;
        retro_run(); assert(requests==1);
        retro_reset(); assert(cleanups==1);
        Core::System::GetInstance().result=Status::Success;
        retro_run(); assert(calls==2 && frames==1);
    }
    clear(); instance.game_loaded=false;
    retro_run(); assert(calls==0 && requests==0);
    std::cout << (fixed ? "AFTER PASS: bounded terminal errors, shutdown accepted/declined, cleanup, recovery, reset\n"
                         : "BEFORE reproduced: terminal errors keep looping; shader warning recovers\n");
}
'''


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path, default=Path(__file__).resolve().parents[1] /
                        '.build/engine-sources/azahar')
    args = parser.parse_args()
    root = args.source.resolve()
    relative = Path('src/citra_libretro/citra_libretro.cpp')
    original = (root / relative).read_text()
    original_hash = hashlib.sha256(original.encode()).hexdigest()
    if 'bool terminal_run_error' in original:
        # Obtain the pinned, pre-runtime-patch source without modifying any checkout.
        before = subprocess.check_output(['git', '-C', str(root), 'show', 'HEAD:' + str(relative)], text=True)
    else:
        before = original
    environment = (root / 'src/citra_libretro/environment.cpp').read_text()
    header = (root / 'src/core/core.h').read_text()
    enum = re.search(r'enum class ResultStatus : u32 \{.*?\};', header, re.S).group()
    with tempfile.TemporaryDirectory(prefix='veta-azahar-runtime-') as temporary:
        directory = Path(temporary)
        source = directory / 'isolated-source'
        target = source / relative
        target.parent.mkdir(parents=True)
        target.write_text(before)
        apply(source, replace)
        after = target.read_text()
        apply(source, replace)
        assert target.read_text() == after, 'Patch is not idempotent'
        assert function(before, 'void retro_unload_game()') == function(after, 'void retro_unload_game()')
        assert function(after, 'bool retro_load_game(').splitlines()[1].strip() == 'emu_instance->terminal_run_error = false;'
        for fixed, text in [(False, before), (True, after)]:
            cpp = directory / ('after.cpp' if fixed else 'before.cpp')
            cpp.write_text(harness(text, environment, enum, fixed))
            executable = cpp.with_suffix('')
            subprocess.run(['xcrun', 'clang++', '-std=c++20', '-Wall', '-Wextra', '-Werror',
                            '-fsanitize=address,undefined', str(cpp), '-o', str(executable)], check=True)
            subprocess.run([str(executable)], check=True, timeout=10)
    assert hashlib.sha256((root / relative).read_bytes()).hexdigest() == original_hash
    print('PASS: idempotent patch; unload unchanged; reload clears guard; generated source untouched')
    print('Source-level contract only: CPU/GPU and frontend services are simulated, no game/iPhone runtime claim.')


if __name__ == '__main__':
    main()
