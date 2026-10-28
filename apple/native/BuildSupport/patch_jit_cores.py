"""Idempotent development JIT adapters for the pinned Flycast and Play! sources.

Callbacks are supplied only by the isolated lab. Regular builds retain their
existing allocator unless a frontend explicitly registers the capability.
"""
from pathlib import Path


def replace(path, old, new):
    text=path.read_text()
    if new in text:return
    if old not in text:raise RuntimeError('JIT patch context changed: '+str(path))
    path.write_text(text.replace(old,new,1))


def apply(name, source):
    if name == 'azahar':
        from patch_azahar_jit import apply as patch_azahar
        patch_azahar(source, replace)
        from patch_azahar_storage import apply as patch_storage
        patch_storage(source, replace)
        from patch_azahar_runtime import apply as patch_runtime
        patch_runtime(source, replace)
    if name=='flycast':
        exports=source/'shell/libretro/libretro.osx.def'
        text=exports.read_text()
        if '_veta_set_jit_allocator' not in text:exports.write_text(text.rstrip()+'\n_veta_set_jit_allocator\n')
        replace(source/'core/build.h', '#ifdef __SWITCH__\n#define FEAT_NO_RWX_PAGES', '#if defined(TARGET_IPHONE) && !TARGET_OS_SIMULATOR\n#define FEAT_NO_RWX_PAGES\n#endif\n#ifdef __SWITCH__\n#define FEAT_NO_RWX_PAGES')
        p=source/'core/linux/posix_vmem.cpp'
        replace(p, 'namespace virtmem\n{', '''// VETA: frontend-owned prepared RX/RW pairs; registration happens before init.
#include <mutex>
#include <vector>
static bool (*veta_alloc)(size_t,void**,void**);
static bool (*veta_free)(void*);
struct VetaJitRegion {void *rx,*rw;size_t size;};
static std::vector<VetaJitRegion> veta_regions;
static std::mutex veta_mutex;
extern "C" __attribute__((visibility("default"))) void veta_set_jit_allocator(
    bool (*allocate)(size_t,void**,void**),bool (*release)(void*))
{std::lock_guard<std::mutex> guard(veta_mutex);if(veta_regions.empty()){veta_alloc=allocate;veta_free=release;}}
static bool veta_is_alias(void *p,size_t size) {
    std::lock_guard<std::mutex> guard(veta_mutex);
    for(auto &r:veta_regions)if((uintptr_t)p>=(uintptr_t)r.rw && size<=r.size && (uintptr_t)p-(uintptr_t)r.rw<=r.size-size)return true;
    return false;
}
namespace virtmem
{''')
        replace(p, 'bool region_set_exec(void *start, size_t len)\n{', 'bool region_set_exec(void *start, size_t len)\n{\n    if(veta_is_alias(start,len))return true; // Keep RW alias writable, RX is separate.')
        replace(p, 'bool prepare_jit_block(void *code_area, size_t size, void **code_area_rw, ptrdiff_t *rx_offset)\n{', '''bool prepare_jit_block(void *code_area, size_t size, void **code_area_rw, ptrdiff_t *rx_offset)
{
    if(veta_alloc){
        void *rx=nullptr,*rw=nullptr;if(!veta_alloc(size,&rx,&rw))return false;
        {std::lock_guard<std::mutex> guard(veta_mutex);veta_regions.push_back({rx,rw,size});}
        *code_area_rw=rw;*rx_offset=(intptr_t)rx-(intptr_t)rw;return true;
    }''')
        replace(p, 'void release_jit_block(void *code_area1, void *code_area2, size_t size)\n{', '''void release_jit_block(void *code_area1, void *code_area2, size_t size)
{
    {std::lock_guard<std::mutex> guard(veta_mutex);
    for(auto i=veta_regions.begin();i!=veta_regions.end();++i)
        if(i->rx==code_area1 || i->rw==code_area1 || i->rx==code_area2 || i->rw==code_area2){veta_free(i->rx);veta_regions.erase(i);return;}}
''')
        replace(source/'core/hw/aica/dsp_arm64.cpp', '\tDynCode = pCodeBuffer;', '''#ifdef FEAT_NO_RWX_PAGES
    DynCode = pCodeBuffer + rx_offset;
#else
\tDynCode = pCodeBuffer;
#endif''')
    if name=='play':
        p=source/'deps/CodeGen/src/MemoryFunction.cpp'
        replace(p, '#define BLOCK_ALIGN 0x10', '''#define BLOCK_ALIGN 0x10
// VETA callback registration is optional; only the development lab supplies it.
#include <stdexcept>
static bool (*veta_alloc)(size_t,void**,void**);
static bool (*veta_free)(void*);
extern "C" __attribute__((visibility("default"))) void veta_set_jit_allocator(
    bool (*allocate)(size_t,void**,void**),bool (*release)(void*))
{veta_alloc=allocate;veta_free=release;}''')
        replace(p, '#if defined(MEMFUNC_USE_WIN32)\n\tm_size = size;', '''if(veta_alloc) {
        void *rx=nullptr,*rw=nullptr;
        if(!veta_alloc(size,&rx,&rw))throw std::runtime_error("Prepared JIT pool exhausted");
        m_code=rx;m_writable=rw;m_size=size;memcpy(rw,code,size);ClearCache();return;
    }
#if defined(MEMFUNC_USE_WIN32)
\tm_size = size;''')
        replace(p, 'void CMemoryFunction::Reset()\n{', '''void CMemoryFunction::Reset()
{
    if(m_writable){veta_free(m_code);m_code=nullptr;m_writable=nullptr;m_size=0;return;}''')
        replace(p, '\tstd::swap(m_code, rhs.m_code);', '\tstd::swap(m_code, rhs.m_code);\n    std::swap(m_writable, rhs.m_writable);')
        replace(p, 'void CMemoryFunction::BeginModify()\n{', 'void CMemoryFunction::BeginModify()\n{\n    if(m_writable)return;')
        replace(p, 'void CMemoryFunction::EndModify()\n{', 'void CMemoryFunction::EndModify()\n{\n    if(m_writable){ClearCache();return;}')
        h=source/'deps/CodeGen/include/MemoryFunction.h'
        replace(h, '\tvoid* GetCode() const;', '\tvoid* GetCode() const;\n    void* GetWritableCode() const {return m_writable ? m_writable : m_code;}')
        replace(h, '\tvoid* m_code;', '\tvoid* m_code;\n    void* m_writable = nullptr;')
        p=source/'Source/BasicBlock.cpp';text=p.read_text();text=text.replace('auto code = reinterpret_cast<uint8*>(m_function.GetCode());','auto code = reinterpret_cast<uint8*>(m_function.GetWritableCode());');p.write_text(text)

        # Drain pending draws while the VM pauses, release GL resources exactly once.
        p=source/'Source/ui_libretro/main_libretro.cpp'
        replace(p, '\t\t\t\tgsHandler->Release();\n\t\t\t}', '\t\t\t\tgsHandler->FlushMailBox();\n\t\t\t}\n            gsHandler->Release();')
