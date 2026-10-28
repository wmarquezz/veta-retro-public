// Offscreen libretro Vulkan presentation through MoltenVK/Metal. The core and
// frontend share one queue; synchronous readback preserves VETA's existing
// native video, screenshots, external display and two-screen composition.
#include "HardwareVulkan.h"
#include <libretro_vulkan.h>
#include <algorithm>
#include <atomic>
#include <time.h>
#include <cstdio>
#include <cstring>
#include <mutex>
#include <vector>

namespace {
struct ProfileCounter {std::atomic<uint64_t> count{0},ns{0};};
struct Profile {
    std::atomic<bool> enabled{false};
    ProfileCounter read,submit,wait,callbackWait,queueLock,convert;
    std::atomic<uint64_t> failures{0};
} profile;
uint64_t profile_clock() {
    struct timespec value{};if(clock_gettime(CLOCK_MONOTONIC_RAW,&value)!=0)return 0;
    return uint64_t(value.tv_sec)*1000000000ull+uint64_t(value.tv_nsec);
}
void profile_add(ProfileCounter &counter,uint64_t start) {
    const auto end=profile_clock();
    counter.count.fetch_add(1,std::memory_order_relaxed);
    if(start && end>=start)counter.ns.fetch_add(end-start,std::memory_order_relaxed);
}
// One enabled load per operation; no clocks/atomic increments when disabled.
struct ProfileScope {
    ProfileCounter &counter;bool enabled;uint64_t start;
    ProfileScope(ProfileCounter &counter,bool enabled):counter(counter),enabled(enabled),start(enabled?profile_clock():0){}
    ~ProfileScope(){if(enabled)profile_add(counter,start);}
};
struct ReadProfileScope {
    bool enabled=profile.enabled.load(std::memory_order_relaxed),success=false;
    uint64_t start=enabled?profile_clock():0;
    ~ReadProfileScope(){if(enabled){profile_add(profile.read,start);if(!success)profile.failures.fetch_add(1,std::memory_order_relaxed);}}
};
struct State {
    retro_hw_render_callback callback{};
    retro_hw_render_context_negotiation_interface_vulkan negotiation{};
    retro_hw_render_interface_vulkan interface{};
    VkInstance instance{};
    retro_vulkan_context context{};
    VkCommandPool pool{};
    VkCommandBuffer command{};
    VkBuffer buffer{};
    VkDeviceMemory memory{};
    VkDeviceSize capacity{};
    void *mapped{};
    const retro_vulkan_image *image{};
    std::vector<VkSemaphore> waits;
    std::vector<VkCommandBuffer> commands;
    VkSemaphore signal{};
    std::mutex queueMutex;
    bool requested=false,reset=false,failed=false;
} state;
bool checked(VkResult result,const char *operation) {
    if(result==VK_SUCCESS)return true;
    fprintf(stderr,"VETA Vulkan %s failed: %d\n",operation,int(result));return false;
}
void lock_queue(void*){
    ProfileScope sample(profile.queueLock,profile.enabled.load(std::memory_order_relaxed));
    state.queueMutex.lock();
}
void unlock_queue(void*){state.queueMutex.unlock();}
uint32_t sync_index(void*){return 0;}
uint32_t sync_mask(void*){return 1;}
void wait_sync(void*) {
    const bool enabled=profile.enabled.load(std::memory_order_relaxed);
    std::unique_lock<std::mutex> lock(state.queueMutex,std::defer_lock);
    {ProfileScope sample(profile.queueLock,enabled);lock.lock();}
    if(state.context.queue){ProfileScope sample(profile.callbackWait,enabled);vkQueueWaitIdle(state.context.queue);}
}
void set_image(void*,const retro_vulkan_image *image,uint32_t count,const VkSemaphore *waits,uint32_t family) {
    state.image=nullptr;state.waits.clear();
    // This adapter currently negotiates a single graphics/compute queue.
    if(family!=state.context.queue_family_index && family!=VK_QUEUE_FAMILY_IGNORED)return;
    if(count && !waits)return;
    state.image=image;
    if(count)state.waits.assign(waits,waits+count);
}
void set_commands(void*,uint32_t count,const VkCommandBuffer *commands) {
    state.commands.clear();if(count && commands)state.commands.assign(commands,commands+count);
}
void set_signal(void*,VkSemaphore semaphore){state.signal=semaphore;}
uintptr_t framebuffer(){return 0;}
retro_proc_address_t proc(const char *name){return reinterpret_cast<retro_proc_address_t>(vkGetInstanceProcAddr(state.instance,name));}
bool initialize() {
    uint32_t count=0;
    if(!checked(vkEnumerateInstanceExtensionProperties(nullptr,&count,nullptr),"instance extensions"))return false;
    std::vector<VkExtensionProperties> available(count);
    if(!checked(vkEnumerateInstanceExtensionProperties(nullptr,&count,available.data()),"instance extensions"))return false;
    auto has=[&](const char *name){return std::any_of(available.begin(),available.end(),[&](auto &e){return strcmp(e.extensionName,name)==0;});};
    std::vector<const char*> extensions;
    for(const char *name:{"VK_KHR_surface","VK_EXT_metal_surface","VK_KHR_get_physical_device_properties2","VK_KHR_portability_enumeration"})if(has(name))extensions.push_back(name);
    VkApplicationInfo app{VK_STRUCTURE_TYPE_APPLICATION_INFO};app.pApplicationName="VETA Retro";app.apiVersion=VK_API_VERSION_1_1;
    if(state.negotiation.get_application_info){if(auto *value=state.negotiation.get_application_info())app=*value;}
    VkInstanceCreateInfo instance{VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO};instance.pApplicationInfo=&app;
    instance.enabledExtensionCount=uint32_t(extensions.size());instance.ppEnabledExtensionNames=extensions.data();
    if(has("VK_KHR_portability_enumeration"))instance.flags|=VK_INSTANCE_CREATE_ENUMERATE_PORTABILITY_BIT_KHR;
    if(!checked(vkCreateInstance(&instance,nullptr,&state.instance),"create instance"))return false;
    count=0;if(!checked(vkEnumeratePhysicalDevices(state.instance,&count,nullptr),"physical devices") || !count)return false;
    std::vector<VkPhysicalDevice> devices(count);
    if(!checked(vkEnumeratePhysicalDevices(state.instance,&count,devices.data()),"physical devices"))return false;
    // Azahar supplies its optional features and extensions through the v1
    // create_device callback even when its negotiation struct is version 2.
    if(!state.negotiation.create_device)return false;
    if(!state.negotiation.create_device(&state.context,state.instance,devices[0],VK_NULL_HANDLE,vkGetInstanceProcAddr,nullptr,0,nullptr,0,nullptr))return false;
    if(!state.context.device || !state.context.queue)return false;
    VkCommandPoolCreateInfo pool{VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO};pool.queueFamilyIndex=state.context.queue_family_index;pool.flags=VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT;
    if(!checked(vkCreateCommandPool(state.context.device,&pool,nullptr,&state.pool),"command pool"))return false;
    VkCommandBufferAllocateInfo command{VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO};command.commandPool=state.pool;command.level=VK_COMMAND_BUFFER_LEVEL_PRIMARY;command.commandBufferCount=1;
    if(!checked(vkAllocateCommandBuffers(state.context.device,&command,&state.command),"command buffer"))return false;
    auto &i=state.interface;i.interface_type=RETRO_HW_RENDER_INTERFACE_VULKAN;i.interface_version=RETRO_HW_RENDER_INTERFACE_VULKAN_VERSION;
    i.handle=&state;i.instance=state.instance;i.gpu=state.context.gpu;i.device=state.context.device;i.queue=state.context.queue;i.queue_index=state.context.queue_family_index;
    i.get_instance_proc_addr=vkGetInstanceProcAddr;i.get_device_proc_addr=vkGetDeviceProcAddr;
    i.set_image=set_image;i.get_sync_index=sync_index;i.get_sync_index_mask=sync_mask;i.wait_sync_index=wait_sync;
    i.lock_queue=lock_queue;i.unlock_queue=unlock_queue;i.set_command_buffers=set_commands;i.set_signal_semaphore=set_signal;
    VkPhysicalDeviceProperties properties{};vkGetPhysicalDeviceProperties(i.gpu,&properties);
    fprintf(stderr,"VETA Vulkan ready: %s, API %u.%u.%u\n",properties.deviceName,VK_VERSION_MAJOR(properties.apiVersion),VK_VERSION_MINOR(properties.apiVersion),VK_VERSION_PATCH(properties.apiVersion));
    return true;
}
void free_readback() {
    if(state.mapped)vkUnmapMemory(state.context.device,state.memory);
    if(state.buffer)vkDestroyBuffer(state.context.device,state.buffer,nullptr);
    if(state.memory)vkFreeMemory(state.context.device,state.memory,nullptr);
    state.mapped=nullptr;state.buffer=VK_NULL_HANDLE;state.memory=VK_NULL_HANDLE;state.capacity=0;
}
bool reserve(VkDeviceSize size) {
    if(size<=state.capacity)return true;
    free_readback();
    VkBufferCreateInfo info{VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO};info.size=size;info.usage=VK_BUFFER_USAGE_TRANSFER_DST_BIT;info.sharingMode=VK_SHARING_MODE_EXCLUSIVE;
    if(!checked(vkCreateBuffer(state.context.device,&info,nullptr,&state.buffer),"readback buffer"))return false;
    VkMemoryRequirements requirements{};vkGetBufferMemoryRequirements(state.context.device,state.buffer,&requirements);
    VkPhysicalDeviceMemoryProperties properties{};vkGetPhysicalDeviceMemoryProperties(state.context.gpu,&properties);
    uint32_t type=UINT32_MAX;
    for(uint32_t i=0;i<properties.memoryTypeCount;i++)if((requirements.memoryTypeBits&(1u<<i)) && (properties.memoryTypes[i].propertyFlags&(VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT|VK_MEMORY_PROPERTY_HOST_COHERENT_BIT))==(VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT|VK_MEMORY_PROPERTY_HOST_COHERENT_BIT)){type=i;break;}
    if(type==UINT32_MAX)return false;
    VkMemoryAllocateInfo allocation{VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO};allocation.allocationSize=requirements.size;allocation.memoryTypeIndex=type;
    if(!checked(vkAllocateMemory(state.context.device,&allocation,nullptr,&state.memory),"readback memory") || !checked(vkBindBufferMemory(state.context.device,state.buffer,state.memory,0),"bind readback") || !checked(vkMapMemory(state.context.device,state.memory,0,size,0,&state.mapped),"map readback"))return false;
    state.capacity=size;return true;
}
}
extern "C" void veta_vk_profile_reset(bool enabled) {
    profile.enabled.store(false,std::memory_order_relaxed);
    for(auto *counter:{&profile.read,&profile.submit,&profile.wait,&profile.callbackWait,&profile.queueLock,&profile.convert}) {
        counter->count.store(0,std::memory_order_relaxed);counter->ns.store(0,std::memory_order_relaxed);
    }
    profile.failures.store(0,std::memory_order_relaxed);
#if DEBUG
    profile.enabled.store(enabled,std::memory_order_relaxed);
#else
    (void)enabled;
#endif
}
extern "C" VetaVulkanProfile veta_vk_profile_snapshot() {
    VetaVulkanProfile out{};
#define COPY_PROFILE(name,field) out.name##_count=profile.field.count.load(std::memory_order_relaxed);out.name##_ns=profile.field.ns.load(std::memory_order_relaxed)
    COPY_PROFILE(read,read);COPY_PROFILE(submit,submit);COPY_PROFILE(wait,wait);
    COPY_PROFILE(callback_wait,callbackWait);COPY_PROFILE(lock,queueLock);COPY_PROFILE(convert,convert);
#undef COPY_PROFILE
    out.read_failures=profile.failures.load(std::memory_order_relaxed);
    return out;
}
extern "C" bool veta_vk_active(){return state.requested;}
extern "C" bool veta_vk_setup(retro_hw_render_callback *request) {
    if(state.requested || request->context_type!=RETRO_HW_CONTEXT_VULKAN)return false;
    request->get_current_framebuffer=framebuffer;request->get_proc_address=proc;
    state.callback=*request;state.requested=true;return true;
}
extern "C" bool veta_vk_environment(unsigned command,void *data) {
    if(!data)return false;
    if(command==RETRO_ENVIRONMENT_SET_HW_RENDER_CONTEXT_NEGOTIATION_INTERFACE) {
        auto *value=static_cast<const retro_hw_render_context_negotiation_interface_vulkan*>(data);
        if(!state.requested || value->interface_type!=RETRO_HW_RENDER_CONTEXT_NEGOTIATION_INTERFACE_VULKAN || value->interface_version<1 || value->interface_version>2)return false;
        // Copy only the v1 prefix; optional v2 callbacks are not used.
        state.negotiation.interface_type=value->interface_type;state.negotiation.interface_version=value->interface_version;
        state.negotiation.get_application_info=value->get_application_info;state.negotiation.create_device=value->create_device;state.negotiation.destroy_device=value->destroy_device;
        return true;
    }
    if(command==RETRO_ENVIRONMENT_GET_HW_RENDER_INTERFACE && state.interface.device){*static_cast<const retro_hw_render_interface_vulkan**>(data)=&state.interface;return true;}
    return false;
}
extern "C" void veta_vk_begin() {
    if(!state.requested || state.reset || state.failed)return;
    if(!initialize()){state.failed=true;return;}
    state.reset=true;if(state.callback.context_reset)state.callback.context_reset();
}
extern "C" bool veta_vk_read(uint32_t *pixels,unsigned width,unsigned height) {
    ReadProfileScope sample;
    if(!state.reset || !state.image || !pixels || !width || !height || width>2048 || height>2048)return false;
    const auto &image=*state.image;
    const auto format=image.create_info.format;
    const bool rgba=format==VK_FORMAT_R8G8B8A8_UNORM || format==VK_FORMAT_R8G8B8A8_SRGB;
    const bool bgra=format==VK_FORMAT_B8G8R8A8_UNORM || format==VK_FORMAT_B8G8R8A8_SRGB;
    if((!rgba && !bgra) || !image.create_info.image)return false;
    std::unique_lock<std::mutex> lock(state.queueMutex,std::defer_lock);
    {ProfileScope lockSample(profile.queueLock,sample.enabled);lock.lock();}
    if(!reserve(VkDeviceSize(width)*height*4))return false;
    if(!checked(vkResetCommandBuffer(state.command,0),"reset readback"))return false;
    VkCommandBufferBeginInfo begin{VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO};begin.flags=VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;
    if(!checked(vkBeginCommandBuffer(state.command,&begin),"begin readback"))return false;
    VkImageMemoryBarrier barrier{VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER};barrier.srcAccessMask=VK_ACCESS_MEMORY_WRITE_BIT|VK_ACCESS_MEMORY_READ_BIT;barrier.dstAccessMask=VK_ACCESS_TRANSFER_READ_BIT;
    barrier.oldLayout=image.image_layout;barrier.newLayout=VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL;barrier.srcQueueFamilyIndex=barrier.dstQueueFamilyIndex=VK_QUEUE_FAMILY_IGNORED;barrier.image=image.create_info.image;barrier.subresourceRange=image.create_info.subresourceRange;barrier.subresourceRange.levelCount=barrier.subresourceRange.layerCount=1;
    vkCmdPipelineBarrier(state.command,VK_PIPELINE_STAGE_ALL_COMMANDS_BIT,VK_PIPELINE_STAGE_TRANSFER_BIT,0,0,nullptr,0,nullptr,1,&barrier);
    VkBufferImageCopy copy{};copy.imageSubresource={VK_IMAGE_ASPECT_COLOR_BIT,barrier.subresourceRange.baseMipLevel,barrier.subresourceRange.baseArrayLayer,1};copy.imageExtent={width,height,1};
    vkCmdCopyImageToBuffer(state.command,barrier.image,VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,state.buffer,1,&copy);
    barrier.srcAccessMask=VK_ACCESS_TRANSFER_READ_BIT;barrier.dstAccessMask=VK_ACCESS_MEMORY_READ_BIT|VK_ACCESS_MEMORY_WRITE_BIT;barrier.oldLayout=VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL;barrier.newLayout=image.image_layout;
    vkCmdPipelineBarrier(state.command,VK_PIPELINE_STAGE_TRANSFER_BIT,VK_PIPELINE_STAGE_ALL_COMMANDS_BIT,0,0,nullptr,0,nullptr,1,&barrier);
    VkBufferMemoryBarrier host{VK_STRUCTURE_TYPE_BUFFER_MEMORY_BARRIER};host.srcAccessMask=VK_ACCESS_TRANSFER_WRITE_BIT;host.dstAccessMask=VK_ACCESS_HOST_READ_BIT;host.srcQueueFamilyIndex=host.dstQueueFamilyIndex=VK_QUEUE_FAMILY_IGNORED;host.buffer=state.buffer;host.size=VK_WHOLE_SIZE;
    vkCmdPipelineBarrier(state.command,VK_PIPELINE_STAGE_TRANSFER_BIT,VK_PIPELINE_STAGE_HOST_BIT,0,0,nullptr,1,&host,0,nullptr);
    if(!checked(vkEndCommandBuffer(state.command),"end readback"))return false;
    auto commands=state.commands;commands.push_back(state.command);
    std::vector<VkPipelineStageFlags> stages(state.waits.size(),VK_PIPELINE_STAGE_ALL_COMMANDS_BIT);
    VkSubmitInfo submit{VK_STRUCTURE_TYPE_SUBMIT_INFO};submit.commandBufferCount=uint32_t(commands.size());submit.pCommandBuffers=commands.data();
    if(state.commands.empty()){submit.waitSemaphoreCount=uint32_t(state.waits.size());submit.pWaitSemaphores=state.waits.data();submit.pWaitDstStageMask=stages.data();}
    if(state.signal){submit.signalSemaphoreCount=1;submit.pSignalSemaphores=&state.signal;}
    bool ok;
    {ProfileScope submitSample(profile.submit,sample.enabled);ok=checked(vkQueueSubmit(state.context.queue,1,&submit,VK_NULL_HANDLE),"submit readback");}
    if(ok){ProfileScope waitSample(profile.wait,sample.enabled);ok=checked(vkQueueWaitIdle(state.context.queue),"wait readback");}
    state.waits.clear();state.commands.clear();state.signal=VK_NULL_HANDLE;
    if(!ok)return false;
    {
    ProfileScope convertSample(profile.convert,sample.enabled);
    auto *bytes=static_cast<const uint8_t*>(state.mapped);
    for(unsigned y=0;y<height;y++)for(unsigned x=0;x<width;x++){
        const auto *p=bytes+((state.callback.bottom_left_origin?height-1-y:y)*width+x)*4;
        pixels[y*width+x]=0xff000000u|(uint32_t(p[rgba?0:2])<<16)|(uint32_t(p[1])<<8)|p[rgba?2:0];
    }
    }
    sample.success=true;
    return true;
}
extern "C" void veta_vk_release_core() {
    if(state.reset && state.callback.context_destroy)state.callback.context_destroy();
    state.reset=false;
}
extern "C" void veta_vk_destroy() {
    // Called only AFTER retro_unload_game/deinit release their Vulkan objects.
    if(state.context.device){vkDeviceWaitIdle(state.context.device);free_readback();if(state.pool)vkDestroyCommandPool(state.context.device,state.pool,nullptr);}
    if(state.negotiation.destroy_device)state.negotiation.destroy_device();
    if(state.context.device)vkDestroyDevice(state.context.device,nullptr);
    if(state.instance)vkDestroyInstance(state.instance,nullptr);
    state.callback={};state.negotiation={};state.interface={};state.context={};state.instance=VK_NULL_HANDLE;state.pool=VK_NULL_HANDLE;state.command=VK_NULL_HANDLE;
    state.image=nullptr;state.waits.clear();state.commands.clear();state.signal=VK_NULL_HANDLE;state.requested=state.reset=state.failed=false;
}
