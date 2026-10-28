"""Adapt pinned Dynarmic ARM64 to VETA's verified executable-memory pool.

RX addresses remain the program counters; all emission and relinking use the
RW alias. Normal iPhone builds keep the interpreter because CanUseJIT is false.
"""


def apply(source, replace):
    # Azahar defines merry::oaknut before adding Dynarmic, so the latter's
    # nested submodule is not the header used by this build.
    oaknut = source / 'externals/oaknut/include/oaknut/code_block.hpp'
    replace(oaknut, 'namespace oaknut {', '''namespace oaknut {
// Registered before initialization by the development frontend only.
inline bool (*veta_allocate)(std::size_t, void**, void**) = nullptr;
inline bool (*veta_release)(void*) = nullptr;''')
    replace(oaknut, '    {\n#if defined(_WIN32)\n        m_memory', '''    {
        if (veta_allocate && veta_release) {
            void *rx = nullptr, *rw = nullptr;
            if (!veta_allocate(size, &rx, &rw)) throw std::bad_alloc{};
            m_memory = static_cast<std::uint32_t*>(rx);
            m_writable = static_cast<std::uint32_t*>(rw);
            m_release = veta_release;
            return;
        }
#if defined(_WIN32)
        m_memory''')
    replace(oaknut, '        if (m_memory == nullptr)\n            throw std::bad_alloc{};', '''        if (m_memory == nullptr || m_memory == reinterpret_cast<std::uint32_t*>(-1))
            throw std::bad_alloc{};''')
    replace(oaknut, '    ~CodeBlock()\n    {', '''    ~CodeBlock()
    {
        if (m_release) { m_release(m_memory); return; }''')
    replace(oaknut, '    void protect()\n    {', '''    std::uint32_t* writable_ptr() const { return m_writable ? m_writable : m_memory; }

    void protect()
    {
        if (m_writable) return;''')
    replace(oaknut, '    void unprotect()\n    {', '''    void unprotect()
    {
        if (m_writable) return;''')
    replace(oaknut, '        sys_icache_invalidate(mem, size);', '''        if (m_writable) {
            const auto offset = reinterpret_cast<std::uintptr_t>(mem) - reinterpret_cast<std::uintptr_t>(m_memory);
            sys_dcache_flush(reinterpret_cast<char*>(m_writable) + offset, size);
        }
        sys_icache_invalidate(mem, size);''')
    replace(oaknut, '    std::uint32_t* m_memory;', '''    std::uint32_t* m_memory;
    std::uint32_t* m_writable = nullptr;
    bool (*m_release)(void*) = nullptr;''')
    arm = source / 'externals/dynarmic/src/dynarmic/backend/arm64/address_space.cpp'
    replace(arm, 'namespace Dynarmic::Backend::Arm64 {', '''extern "C" __attribute__((visibility("default"))) void veta_set_jit_allocator(
    bool (*allocate)(std::size_t, void**, void**), bool (*release)(void*)) {
    oaknut::veta_allocate = allocate;
    oaknut::veta_release = release;
}

namespace Dynarmic::Backend::Arm64 {''')
    # Includes secondary generators used to patch already-emitted branch targets.
    text = arm.read_text().replace('mem.ptr(), mem.ptr()', 'mem.writable_ptr(), mem.ptr()')
    arm.write_text(text)
    # Upstream eagerly allocates an executable lock thunk during dlopen, before
    # callback registration. Use AOT atomics with the same 0/1 storage protocol
    # as the emitted LDAXR/STXR/STLR instructions, avoiding another JIT arena.
    spin = source / 'externals/dynarmic/src/dynarmic/common/spin_lock_arm64.cpp'
    text = spin.read_text()
    if '// VETA AOT spin lock' not in text:
        start = text.index('namespace {\n\nstruct SpinLockImpl')
        end = text.index('\n}  // namespace Dynarmic', start)
        text = text[:start] + '''// VETA AOT spin lock: no executable allocation during static initialization.
void SpinLock::Lock() {
    while (__atomic_exchange_n(&storage, 1, __ATOMIC_ACQUIRE)) {
        while (__atomic_load_n(&storage, __ATOMIC_RELAXED)) {
            __asm__ volatile("yield");
        }
    }
}

void SpinLock::Unlock() {
    __atomic_store_n(&storage, 0, __ATOMIC_RELEASE);
}
''' + text[end:]
        spin.write_text(text)
    settings = source / 'src/citra_libretro/core_settings.cpp'
    replace(settings, '''Settings::values.use_cpu_jit =
#ifdef IOS
        false;''', '''Settings::values.use_cpu_jit =
#ifdef IOS
        LibRetro::CanUseJIT();''')
    replace(settings, '''Settings::values.use_shader_jit =
#ifdef IOS
        false;''', '''Settings::values.use_shader_jit =
#ifdef IOS
        LibRetro::CanUseJIT();''')
    shader = source / 'src/video_core/shader/shader_jit_a64_compiler.cpp'
    replace(shader,
            'std::memcpy(code_mem->ptr(), code_vec.data(), code_vec.size() * sizeof(u32));',
            'std::memcpy(code_mem->writable_ptr(), code_vec.data(), code_vec.size() * sizeof(u32));')
    cpu = source / 'src/core/arm/dynarmic/arm_dynarmic.cpp'
    replace(cpu, '    Dynarmic::A32::UserConfig config;', '''    Dynarmic::A32::UserConfig config;
#ifdef HAVE_LIBRETRO
    // Several guest CPUs/page tables share the frontend's bounded JIT pool.
    config.code_cache_size = 32 * 1024 * 1024;
#endif''')
    exports = source / 'src/citra_libretro/libretro.osx.def'
    text = exports.read_text()
    if '_veta_set_jit_allocator' not in text:
        exports.write_text(text.rstrip() + '\n_veta_set_jit_allocator\n')
