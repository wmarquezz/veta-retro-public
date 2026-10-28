#!/usr/bin/env python3
"""Isolated Libretro component test, never touches the iPhone or source ROM."""
import argparse, ctypes as C, hashlib, json, tempfile, time, zlib, struct
from pathlib import Path

class Game(C.Structure): _fields_=[('path',C.c_char_p),('data',C.c_void_p),('size',C.c_size_t),('meta',C.c_char_p)]
class Var(C.Structure): _fields_=[('key',C.c_char_p),('value',C.c_char_p)]
class Geometry(C.Structure): _fields_=[('width',C.c_uint),('height',C.c_uint),('max_width',C.c_uint),('max_height',C.c_uint),('aspect',C.c_float)]
class Timing(C.Structure): _fields_=[('fps',C.c_double),('sample_rate',C.c_double)]
class AV(C.Structure): _fields_=[('geometry',Geometry),('timing',Timing)]

def main():
    p=argparse.ArgumentParser();p.add_argument('--core',type=Path,required=True);p.add_argument('--rom',type=Path,required=True)
    p.add_argument('--system',choices=['atari2600'],required=True);p.add_argument('--output',type=Path,required=True)
    p.add_argument('--region',choices=['auto','ntsc-u','ntsc-j','pal'],default='auto')
    p.add_argument('--menu-down',action='store_true',help='Select New Game where Continue is the initial menu item')
    p.add_argument('--allow-silent-scene',action='store_true',help='Only for a scene known to produce no sound; audio callbacks remain required')
    a=p.parse_args(); lib=C.CDLL(str(a.core)); rom=a.rom.read_bytes(); original=hashlib.sha256(rom).hexdigest()
    storage=tempfile.TemporaryDirectory(prefix='veta176-atari-'); directory=storage.name.encode()
    options={b'tia_ram_init':b'zero',b'bsnes_chip_hle':b'HLE',b'veta_jgenesis_system':a.system.encode(),b'veta_jgenesis_region':a.region.encode()};fmt=0
    frames=[];samples=0;nonzero=0;inputs=[0,0];ports=set();last_frame=b'';last_size=(0,0)
    @C.CFUNCTYPE(C.c_bool,C.c_uint,C.c_void_p)
    def environment(cmd,data):
        nonlocal fmt
        if cmd==10: fmt=C.cast(data,C.POINTER(C.c_uint))[0];return fmt in (0,1,2)
        if cmd in (9,31,30): C.cast(data,C.POINTER(C.c_char_p))[0]=directory;return True
        if cmd==15:
            variable=C.cast(data,C.POINTER(Var)).contents
            if variable.key in options:variable.value=options[variable.key];return True
            return False
        if cmd==16:
            values=C.cast(data,C.POINTER(Var));i=0
            while values[i].key:
                key,value=values[i].key,values[i].value
                if value and b'; ' in value:options.setdefault(key,value.split(b'; ',1)[1].split(b'|')[0])
                i+=1
            return True
        if cmd==17:C.cast(data,C.POINTER(C.c_bool))[0]=False;return True
        if cmd==3:C.cast(data,C.POINTER(C.c_bool))[0]=False;return True
        if cmd==18:C.cast(data,C.POINTER(C.c_bool))[0]=False;return True
        if cmd in (1,11,35,37):return True
        return False
    @C.CFUNCTYPE(None,C.c_void_p,C.c_uint,C.c_uint,C.c_size_t)
    def video(data,w,h,pitch):
        nonlocal last_frame,last_size
        if data:
            bpp=4 if fmt==1 else 2
            last_frame=b''.join(C.string_at(data+y*pitch,w*bpp) for y in range(h));last_size=(w,h)
        frames.append(zlib.crc32(last_frame))
    @C.CFUNCTYPE(C.c_size_t,C.POINTER(C.c_int16),C.c_size_t)
    def batch(data,n):
        nonlocal samples,nonzero
        raw=C.string_at(data,n*4);samples+=n;nonzero+=sum(x!=0 for x in raw);return n
    @C.CFUNCTYPE(None,C.c_int16,C.c_int16)
    def audio(l,r):
        nonlocal samples,nonzero
        samples+=1;nonzero+=int(l!=0 or r!=0)
    @C.CFUNCTYPE(None)
    def poll():pass
    @C.CFUNCTYPE(C.c_int16,C.c_uint,C.c_uint,C.c_uint,C.c_uint)
    def input_state(port,device,index,id):
        ports.add(port)
        return int(port<2 and bool(inputs[port] & (1<<id)))
    for name,callback in [('environment',environment),('video_refresh',video),('audio_sample',audio),('audio_sample_batch',batch),('input_poll',poll),('input_state',input_state)]:
        getattr(lib,'retro_set_'+name)(callback)
    lib.retro_load_game.argtypes=[C.POINTER(Game)];lib.retro_load_game.restype=C.c_bool
    lib.retro_serialize_size.restype=C.c_size_t
    for name in ('serialize','unserialize'):
        getattr(lib,'retro_'+name).argtypes=[C.c_void_p,C.c_size_t];getattr(lib,'retro_'+name).restype=C.c_bool
    lib.retro_get_memory_size.argtypes=[C.c_uint];lib.retro_get_memory_size.restype=C.c_size_t
    lib.retro_get_memory_data.argtypes=[C.c_uint];lib.retro_get_memory_data.restype=C.c_void_p
    lib.retro_init();buf=C.create_string_buffer(rom);game=Game(str(a.rom).encode(),C.cast(buf,C.c_void_p),len(rom),None)
    assert lib.retro_load_game(C.byref(game)), 'load failed'
    for port in range(2):lib.retro_set_controller_port_device(port,1)
    av=AV();lib.retro_get_system_av_info(C.byref(av));start=time.monotonic()
    for i in range(600):
        # SMS has Pause rather than Start; repeated Start would deliberately
        # suspend its games. Start them with a face button instead.
        start_button=0 if a.system=='sms' else 3
        inputs[0]=(1<<start_button) if i in range(180,190) or i in range(300,310) else (1<<7)|(1<<0) if i>400 else 0
        if a.menu_down and 240<=i<250:inputs[0]=1<<5
        inputs[1]=(1<<5)|(1<<0) if i>400 else 0
        lib.retro_run()
    elapsed=time.monotonic()-start;inputs[:]=[0,0]
    n=lib.retro_serialize_size();assert 0<n<64*1024*1024;state=C.create_string_buffer(n)
    assert lib.retro_serialize(state,n),'save failed'
    ram_size=lib.retro_get_memory_size(0)
    ram_before=C.string_at(lib.retro_get_memory_data(0),ram_size) if ram_size else b''
    for _ in range(60):lib.retro_run()
    replay_a=frames[-60:]
    assert lib.retro_unserialize(state,n),'restore failed'
    if ram_size:assert C.string_at(lib.retro_get_memory_data(0),ram_size)==ram_before,'RAM state restoration failed'
    for _ in range(60):lib.retro_run()
    replay_b=frames[-60:]
    assert replay_a==replay_b,'state replay pixels differ'
    # Retain the rendered result even if the following evidence check fails.
    if fmt==1 and last_frame:
        w,h=last_size
        rgb=b''.join(bytes((last_frame[i+2],last_frame[i+1],last_frame[i])) for i in range(0,len(last_frame),4))
        raw=b''.join(b'\0'+rgb[y*w*3:(y+1)*w*3] for y in range(h))
        def chunk(kind,body):return struct.pack('>I',len(body))+kind+body+struct.pack('>I',zlib.crc32(kind+body))
        a.output.with_suffix('.png').write_bytes(b'\x89PNG\r\n\x1a\n'+chunk(b'IHDR',struct.pack('>IIBBBBB',w,h,8,2,0,0,0))+chunk(b'IDAT',zlib.compress(raw))+chunk(b'IEND',b''))
    print(json.dumps({'frames':len(frames),'unique':len(set(frames)),'audio':samples,'nonzero':nonzero}),flush=True)
    assert samples>0 and (nonzero>0 or a.allow_silent_scene),'silent core'
    assert nonzero>0 or a.allow_silent_scene
    assert len(frames)>=720 and len(set(frames))>5,'no animated video'
    # A newly loaded core must restore the snapshot, not only the current process state.
    lib.retro_unload_game();assert lib.retro_load_game(C.byref(game))
    assert lib.retro_unserialize(state,n),'restore after reopen failed'
    for _ in range(60):lib.retro_run()
    assert frames[-60:]==replay_a,'reopen replay pixels differ'
    assert not lib.retro_unserialize(state,n-1),'truncated snapshot accepted'
    # Frontend-managed SRAM can be persisted then loaded after unload/reopen.
    if ram_size:
        pointer=lib.retro_get_memory_data(0);probe=bytes((i*31+7)%256 for i in range(ram_size));C.memmove(pointer,probe,ram_size)
        assert C.string_at(pointer,ram_size)==probe
        lib.retro_unload_game();assert lib.retro_load_game(C.byref(game))
        assert lib.retro_get_memory_size(0)==ram_size
        pointer=lib.retro_get_memory_data(0);C.memmove(pointer,probe,ram_size)
        lib.retro_run();assert C.string_at(lib.retro_get_memory_data(0),ram_size)==probe
    lib.retro_reset();lib.retro_run();lib.retro_unload_game();lib.retro_deinit()
    assert hashlib.sha256(a.rom.read_bytes()).hexdigest()==original
    if a.system in ('md','sms') and a.region=='pal':assert 49<av.timing.fps<51,'PAL override ignored'
    if a.system in ('md','sms') and a.region in ('ntsc-u','ntsc-j'):assert 59<av.timing.fps<61,'NTSC override ignored'
    result={'system':a.system,'region':a.region,'romSHA256':original,'coreSHA256':hashlib.sha256(a.core.read_bytes()).hexdigest(),
            'frames':len(frames),'uniqueFrames':len(set(frames)),'dimensions':last_size,'pixelFormat':fmt,
            'audioFrames':samples,'audibleSamplesObserved':nonzero>0,'silentSceneExplicitlyAllowed':a.allow_silent_scene,'nonzeroAudio':nonzero,'portsPolled':sorted(ports),'stateBytes':n,
            'stateReplay':'PASS','reopenReplay':'PASS','truncatedStateRejected':True,'ramBytes':ram_size,'sramRoundtrip':'PASS' if ram_size else 'not present',
            'targetFPS':av.timing.fps,'secondsFor600Frames':elapsed,'hostFramesPerSecond':600/elapsed,
            'scope':'Mac ARM64 component, not physical iPhone/TV/gameplay acceptance','status':'PASS'}
    a.output.write_text(json.dumps(result,indent=2)+'\n');print(json.dumps(result))
    storage.cleanup()

if __name__=='__main__':main()
