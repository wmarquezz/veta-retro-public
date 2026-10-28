#!/usr/bin/env python3
"""Compile actual bridge functions: concurrent input/audio + teardown ordering.

No emulator or device is launched. ThreadSanitizer checks the host component;
a fake core records lifecycle order and never stands in for a physical GPU test.
"""
from pathlib import Path
import argparse, subprocess, tempfile

parser = argparse.ArgumentParser()
parser.add_argument('--sanitize', choices=['thread', 'address', 'none'], default='thread')
args = parser.parse_args()
source = (Path(__file__).resolve().parents[1] / 'Sources/NESBridge.c').read_text()

def function(name):
    import re
    match = re.search(r'(?:^|(?<=}))\s*(?:static )?[^\n;{}]+\b' + name + r'\([^;{}]*\)\s*\{', source, re.M)
    if not match:
        raise RuntimeError('Function missing: ' + name)
    start, cursor, depth = match.start(), match.end(), 1
    while depth:
        if source[cursor] == '{': depth += 1
        if source[cursor] == '}': depth -= 1
        cursor += 1
    return source[start:cursor]

def declaration(prefix):
    return next(line for line in source.splitlines() if line.startswith(prefix))

headers = r"""
#include <assert.h>
#include <pthread.h>
#include <stdbool.h>
#include <stdint.h>
#include <stddef.h>
#include <stdio.h>
#include <stdatomic.h>
#include <string.h>
#include "CoreAPI.h"
#include "NESBridge.h"
"""
globals_text = '\n'.join(declaration(prefix) for prefix in [
    'static unsigned activeConsole;', 'static _Atomic(uint32_t) inputMasks',
    'static _Atomic(uint64_t) pointerState', '#define AUDIO_CAPACITY',
    'static int16_t audioRing', 'static atomic_uint audioWrite',
    'static atomic_uint_fast64_t audioDelivered', 'static _Atomic(uint64_t) audioFrames'])
functions = '\n'.join(function(name) for name in [
    'veta_max_players', 'veta_set_input', 'veta_input_mask', 'veta_set_pointer',
    'veta_set_analog', 'input_state', 'audio_batch', 'veta_audio_count',
    'veta_audio_nonzero'])
# Lifecycle globals that the real function resets after stopping the core.
lifecycle = r"""
static bool loaded,initialized,optionsChanged;
static unsigned activeOptionCount;
static bool vk;
static char calls[64];
static unsigned callCount;
static void event(char c){calls[callCount++]=c;calls[callCount]=0;}
static void veta_hw_make_current(void){event('M');}
static void veta_hw_begin(void){event('B');}
static void veta_hw_destroy(void){event('D');}
static bool veta_vk_active(void){return vk;}
static void veta_vk_release_core(void){event('R');}
void veta_rumble_clear(void){}
void veta_audio_clear(void){atomic_store(&audioRead,0);atomic_store(&audioWrite,0);}
static void prepare(void){event('P');}
static void unload(void){event('U');}
static void deinit(void){event('I');}
static void cheat_reset(void){}
static VetaCoreAPI fake;
static const VetaCoreAPI *core=&fake;
#define GUEST_FPU_SCOPE ((void)0)
"""
tests = r"""
static atomic_bool done;
static void *reader(void *unused){
    (void)unused;
    uint64_t previous=0;
    while(!atomic_load_explicit(&done,memory_order_acquire)){
        for(unsigned p=0;p<4;p++){
            uint16_t mask=veta_input_mask(p);
            assert(mask==0 || mask==0x5555 || mask==0xaaaa);
            for(unsigned s=0;s<2;s++)for(unsigned axis=0;axis<2;axis++){
                int16_t v=input_state(p,RETRO_DEVICE_ANALOG,s,axis);
                assert(v==0 || v==32767 || v==-32767);
            }
        }
        int16_t x=input_state(0,RETRO_DEVICE_POINTER,0,RETRO_DEVICE_ID_POINTER_X);
        assert(x==0 || x==30000 || x==-30000);
        uint64_t n=veta_audio_count();assert(n>=previous);previous=n;
        (void)veta_audio_nonzero();
    }
    return NULL;
}
static void ordered(unsigned console,bool hasHook,bool vulkan,const char *expected){
    activeConsole=console;loaded=initialized=true;vk=vulkan;callCount=0;calls[0]=0;
    fake=(VetaCoreAPI){.prepare_unload=hasHook?prepare:NULL,.unload_game=unload,.deinit=deinit,.cheat_reset=cheat_reset};
    veta_set_input(0,0xffff);veta_set_analog(0,0,-100,100);veta_set_pointer(-200,200,true);
    veta_unload();assert(!strcmp(calls,expected));
    assert(!loaded && !initialized && veta_input_mask(0)==0);
    assert(input_state(0,RETRO_DEVICE_ANALOG,0,0)==0);
    assert(input_state(0,RETRO_DEVICE_POINTER,0,RETRO_DEVICE_ID_POINTER_PRESSED)==0);
}
int main(void){
    assert(atomic_load(&audioDelivered)==0 && atomic_load(&audioUnderruns)==0);
    assert(atomic_is_lock_free(&inputMasks[0]));
    assert(atomic_is_lock_free(&analogPairs[0][0]));
    assert(atomic_is_lock_free(&pointerState));
    activeConsole=17;
    for(unsigned p=0;p<4;p++){
        veta_set_input(p,1u<<p);assert(input_state(p,RETRO_DEVICE_JOYPAD,0,p)==1);
        veta_set_analog(p,1,INT16_MIN,INT16_MAX);
        assert(input_state(p,RETRO_DEVICE_ANALOG,1,0)==INT16_MIN);
        assert(input_state(p,RETRO_DEVICE_ANALOG,1,1)==INT16_MAX);
        veta_set_input(p,0);veta_set_analog(p,1,0,0);
    }
    assert(input_state(4,RETRO_DEVICE_JOYPAD,0,0)==0);
    veta_set_input(4,0xffff);veta_set_analog(4,0,1,1);veta_set_analog(0,2,1,1);
    veta_set_pointer(INT16_MIN,INT16_MAX,true);activeConsole=18;
    assert(input_state(0,RETRO_DEVICE_ANALOG,1,0)==INT16_MIN);
    assert(input_state(0,RETRO_DEVICE_ANALOG,1,1)==INT16_MAX);
    assert(input_state(1,RETRO_DEVICE_JOYPAD,0,0)==0);
    veta_set_pointer(0,0,false);activeConsole=17;
    pthread_t a,b;assert(!pthread_create(&a,NULL,reader,NULL));assert(!pthread_create(&b,NULL,reader,NULL));
    const int16_t audio[]={100,-100,0,0};
    for(unsigned i=0;i<200000;i++){
        int16_t v=i&1?32767:-32767;
        for(unsigned p=0;p<4;p++){
            veta_set_input(p,i&1?0x5555:0xaaaa);
            veta_set_analog(p,0,v,-v);veta_set_analog(p,1,-v,v);
        }
        veta_set_pointer(i&1?30000:-30000,i&1?-30000:30000,i&1);
        audio_batch(audio,2);
    }
    atomic_store_explicit(&done,true,memory_order_release);
    pthread_join(a,NULL);pthread_join(b,NULL);
    assert(veta_audio_count()==400000 && veta_audio_nonzero()==200000);
    ordered(17,true,false,"MBPDUI");ordered(18,true,false,"MBPDUI");
    ordered(12,false,false,"MUID");ordered(19,false,false,"MUID");
    ordered(16,false,true,"MRUID");ordered(0,false,false,"MDUI");
    ordered(14,true,false,"MBPDUI");
    puts("PASS: signed inputs, 4 ports, concurrent callbacks/counters, lifecycle orders");
}
"""
with tempfile.TemporaryDirectory(prefix='veta-bridge-concurrency-') as directory:
    root=Path(directory); unit=root/'bridge.c';binary=root/'bridge'
    unit.write_text(headers+globals_text+'\n'+functions+'\n'+lifecycle+'\n'+function('veta_unload')+'\n'+tests)
    includes=Path(__file__).resolve().parents[1]/'Sources'
    command=['xcrun','clang','-std=c11','-O1','-g','-pthread','-Wall','-Wextra','-Werror',
             '-I'+str(includes),'-I'+str(includes.parent/'.build/fceumm/src/drivers/libretro/libretro-common/include'),str(unit),'-o',str(binary)]
    if args.sanitize!='none':command.insert(2,'-fsanitize='+args.sanitize)
    subprocess.run(command,check=True)
    subprocess.run([str(binary)],check=True)
