"""Keep VETA's iOS App Store PPSSPP core on its supported non-native-JIT path.

The frontend's shared executable pool belongs to other adapted cores. PPSSPP
does not register that allocator; global JIT availability must not enable its
separate mmap/mprotect vertex decoder cache. This is a capability correction,
not an executable-memory implementation or a performance claim.
"""

OLD = '''   case SYSPROP_CAN_JIT:
#if PPSSPP_PLATFORM(IOS)
      bool can_jit;
      return (environ_cb(RETRO_ENVIRONMENT_GET_JIT_CAPABLE, &can_jit) && can_jit);
#else
      return true;
#endif'''

NEW = '''   case SYSPROP_CAN_JIT:
#if PPSSPP_PLATFORM(IOS) && PPSSPP_PLATFORM(IOS_APP_STORE)
      // VETA: this core has no adapter for the frontend's prepared executable pool.
      // Global JIT availability does not make PPSSPP's private mmap/mprotect
      // allocations executable. Keep CPU IR interpretation and AOT vertex decoders.
      return false;
#elif PPSSPP_PLATFORM(IOS)
      bool can_jit;
      return (environ_cb(RETRO_ENVIRONMENT_GET_JIT_CAPABLE, &can_jit) && can_jit);
#else
      return true;
#endif'''


def apply(source):
    path = source / 'libretro/libretro.cpp'
    text = path.read_text()
    if text.count(NEW) == 1 and OLD not in text:
        return
    if text.count(OLD) != 1 or NEW in text:
        raise RuntimeError('PPSSPP JIT policy context changed: ' + str(path))
    path.write_text(text.replace(OLD, NEW, 1))


if __name__ == '__main__':
    import argparse
    from pathlib import Path
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('source', type=Path)
    apply(parser.parse_args().source)
