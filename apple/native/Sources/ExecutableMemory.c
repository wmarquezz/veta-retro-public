#include "CoreAPI.h"
#include <TargetConditionals.h>
#include <mach/mach.h>
#include <mach/vm_map.h>
#include <libkern/OSCacheControl.h>
#include <pthread.h>
#include <stdint.h>
#include <string.h>

// Simulator-only W^X allocation. iPhone availability remains false: signing
// an app for development does not by itself grant JIT on a physical device.
static struct {void *address;size_t size;} regions[64];
static pthread_mutex_t lock=PTHREAD_MUTEX_INITIALIZER;
bool veta_exec_alloc(struct retro_exec_mem_alloc *request) {
#if TARGET_OS_SIMULATOR
    if(!request || request->version!=1 || !request->size || request->size>256u*1024u*1024u)return false;
    size_t size=(request->size+vm_page_size-1)&~(vm_page_size-1);
    vm_address_t address=0;
    if(vm_allocate(mach_task_self(),&address,size,VM_FLAGS_ANYWHERE)!=KERN_SUCCESS)return false;
    pthread_mutex_lock(&lock);unsigned i=0;for(;i<64 && regions[i].address;i++);
    if(i<64) {regions[i].address=(void*)address;regions[i].size=size;}
    pthread_mutex_unlock(&lock);
    if(i==64){vm_deallocate(mach_task_self(),address,size);return false;}
    request->rx=request->rw=(void*)address;request->mode=RETRO_EXEC_MEM_MODE_WX_TOGGLE;return true;
#else
    return false;
#endif
}
bool veta_exec_free(struct retro_exec_mem_free *request) {
    if(!request)return false;
    pthread_mutex_lock(&lock);
    for(unsigned i=0;i<64;i++)if(regions[i].address==request->rx && regions[i].address){
        vm_deallocate(mach_task_self(),(vm_address_t)regions[i].address,regions[i].size);
        regions[i].address=NULL;regions[i].size=0;pthread_mutex_unlock(&lock);return true;
    }
    pthread_mutex_unlock(&lock);return false;
}
bool veta_jit_available(void) {
#if TARGET_OS_SIMULATOR && defined(__aarch64__)
    struct retro_exec_mem_alloc allocation={.version=1,.size=vm_page_size};
    if(!veta_exec_alloc(&allocation))return false;
    uint32_t code[]={0x52800540,0xd65f03c0}; // mov w0,#42; ret
    memcpy(allocation.rw,code,sizeof(code));sys_icache_invalidate(allocation.rx,sizeof(code));
    bool ok=vm_protect(mach_task_self(),(vm_address_t)allocation.rx,vm_page_size,false,VM_PROT_READ|VM_PROT_EXECUTE)==KERN_SUCCESS;
    if(ok)ok=((int(*)(void))allocation.rx)()==42;
    struct retro_exec_mem_free release={allocation.rx};veta_exec_free(&release);return ok;
#else
    return false;
#endif
}
