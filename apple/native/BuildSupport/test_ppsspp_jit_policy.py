#!/usr/bin/env python3
"""Compile actual capability/CPU fallback/cache-selection source in isolation.

This executes policy contracts with simulated frontend capabilities and a
counted cache constructor, not an emulator or real executable-memory allocator.
Both before/after source are tested. The generated engine source is untouched.
"""
from pathlib import Path
import argparse
import hashlib
import subprocess
import tempfile

from patch_ppsspp_jit_policy import apply, OLD, NEW


def function(text, signature):
    start = text.index(signature)
    brace = text.index('{', start)
    depth, end = 1, brace + 1
    while depth:
        depth += (text[end] == '{') - (text[end] == '}')
        end += 1
    return text[start:end]


def harness(frontend, draw_engine, fixed):
    capability = function(frontend, 'bool System_GetPropertyBool(SystemProperty prop)')
    cpu_guard = function(frontend, 'if (System_GetPropertyBool(SYSPROP_CAN_JIT) == false')
    cache_guard = function(draw_engine, 'if (g_Config.bVertexDecoderJit && PSP_CoreParameter().bUseVertexDecoderJit)')
    vertex_option = next(line.strip() for line in frontend.splitlines()
                         if 'coreParam.bUseVertexDecoderJit = System_GetPropertyBool' in line)
    return r'''
#include <cassert>
#include <iostream>
#define PPSSPP_PLATFORM(P) PPSSPP_PLATFORM_##P
enum SystemProperty { SYSPROP_CAN_JIT, UNRELATED };
constexpr unsigned RETRO_ENVIRONMENT_GET_JIT_CAPABLE=74;
enum class CPUCore { INTERPRETER, JIT, IR_INTERPRETER };
bool global_jit=false, callback_accepted=false;
int callback_calls=0, cache_allocations=0;
bool environ_cb(unsigned command, void* data) {
    assert(command==RETRO_ENVIRONMENT_GET_JIT_CAPABLE);
    ++callback_calls;
    if (callback_accepted) *static_cast<bool*>(data)=global_jit;
    return callback_accepted;
}
struct { int iCpuCore; bool bVertexDecoderJit=true; } g_Config;
struct CoreParameter { bool bUseVertexDecoderJit=false; } coreParam;
CoreParameter& PSP_CoreParameter() {return coreParam;}
struct VertexDecoderJitCache {VertexDecoderJitCache(){++cache_allocations;}};
''' + capability + r'''
void select() {
''' + cpu_guard + '\n' + vertex_option + r'''
}
void create_decoder() {
    VertexDecoderJitCache *decJitCache_=nullptr;
''' + cache_guard + r'''
    delete decJitCache_;
}
int main() {
    constexpr bool fixed=''' + ('true' if fixed else 'false') + r''';
    constexpr bool ios=PPSSPP_PLATFORM(IOS), app_store=PPSSPP_PLATFORM(IOS_APP_STORE);
    for (bool accepted: {false,true}) for (bool global: {false,true}) {
        callback_accepted=accepted; global_jit=global; callback_calls=0;
        const bool expected=fixed && ios && app_store ? false : ios ? accepted && global : true;
        assert(System_GetPropertyBool(SYSPROP_CAN_JIT)==expected);
        assert(callback_calls==(ios && !(fixed && app_store) ? 1 : 0));
        assert(!System_GetPropertyBool(UNRELATED));
        for (CPUCore selected: {CPUCore::INTERPRETER,CPUCore::IR_INTERPRETER,CPUCore::JIT}) {
            g_Config.iCpuCore=(int)selected;
            select();
            assert(g_Config.iCpuCore==(int)(!expected && selected==CPUCore::JIT ? CPUCore::IR_INTERPRETER : selected));
            assert(coreParam.bUseVertexDecoderJit==expected);
            for (bool configured: {false,true}) {
                cache_allocations=0;g_Config.bVertexDecoderJit=configured;
                create_decoder();
                assert(cache_allocations==(expected && configured ? 1 : 0));
            }
        }
    }
    std::cout << (fixed ? "AFTER" : "BEFORE") << " PASS ios=" << ios << " app_store=" << app_store
              << " global JIT on/off, callback accepted/declined, CPU modes, vertex cache on/off\n";
}
'''


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path, default=Path(__file__).resolve().parents[1] / '.build/ppsspp')
    args = parser.parse_args()
    root = args.source.resolve()
    file = root / 'libretro/libretro.cpp'
    original = file.read_text()
    digest = hashlib.sha256(file.read_bytes()).hexdigest()
    before = original.replace(NEW, OLD, 1) if NEW in original else original
    draw = (root / 'GPU/Common/DrawEngineCommon.cpp').read_text()
    decoder = (root / 'GPU/Common/VertexDecoderCommon.cpp').read_text()
    # The policy passes a null cache into the existing interpreter/handwritten path.
    assert 'if (!jitCache)' in decoder and 'VtxDec_Tu8_C565_Ns16_Pfloat' in decoder
    with tempfile.TemporaryDirectory(prefix='veta-ppsspp-policy-') as temporary:
        directory = Path(temporary)
        isolated = directory / 'source'
        target = isolated / 'libretro/libretro.cpp'
        target.parent.mkdir(parents=True)
        target.write_text(before)
        apply(isolated)
        after = target.read_text()
        apply(isolated)
        assert target.read_text() == after
        assert after.replace(NEW, OLD, 1) == before, 'Unexpected edits outside capability case'
        for invalid in [before.replace(OLD, '/* upstream changed */', 1), before + '\n' + OLD]:
            target.write_text(invalid)
            try:
                apply(isolated)
                raise AssertionError('Context drift was accepted')
            except RuntimeError:
                assert target.read_text() == invalid, 'Drift rejection modified source'
        for fixed, source in [(False, before), (True, after)]:
            cpp = directory / ('after.cpp' if fixed else 'before.cpp')
            cpp.write_text(harness(source, draw, fixed))
            for ios, app_store in [(0,0),(0,1),(1,0),(1,1)]:
                executable = directory / f'contract-{fixed}-{ios}-{app_store}'
                subprocess.run(['xcrun','clang++','-std=c++20','-Wall','-Wextra','-Werror',
                                '-fsanitize=address,undefined',f'-DPPSSPP_PLATFORM_IOS={ios}',
                                f'-DPPSSPP_PLATFORM_IOS_APP_STORE={app_store}',
                                str(cpp),'-o',str(executable)],check=True)
                subprocess.run([str(executable)],check=True,timeout=10)
    assert hashlib.sha256(file.read_bytes()).hexdigest()==digest
    print('PASS: idempotence, drift/duplicate rejection, original source untouched; source contracts only')


if __name__ == '__main__':
    main()
