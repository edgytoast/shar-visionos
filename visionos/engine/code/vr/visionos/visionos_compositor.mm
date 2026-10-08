#define VK_USE_PLATFORM_METAL_EXT 1
#include <vr/visionos/visionos_compositor.h>
#include <vr/visionos/visionos_entry.h>
#include <vr/visionos/visionos_present.h>
#include <vr/visionos/visionos_window.h>
#include <vr/visionos/visionos_mirror.h>
#include <vr/vulkan/openxr_vulkan_context.h>

#import <ARKit/ARKit.h>
#import <CompositorServices/CompositorServices.h>
#import <Foundation/Foundation.h>
#import <GameController/GameController.h>
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>

#include <SDL.h>
#include <SDL_main.h>
#include <AL/alc.h>
#include <AL/alext.h>

#include <mach/mach.h>
#include <os/proc.h>
#include <pthread.h>
#include <unistd.h>
#include <algorithm>
#include <atomic>
#include <cmath>
#include <condition_variable>
#include <map>
#include <mutex>
#include <sstream>
#include <string>
#include <vector>

// What @autoreleasepool compiles to; used directly because a frame's pool spans two calls.
extern "C" void* objc_autoreleasePoolPush(void);
extern "C" void objc_autoreleasePoolPop(void* pool);

namespace
{
cp_layer_renderer_t gRenderer = nil;
ar_session_t gSession = nil;

// The immersive space's layer renderer. visionOS can dismiss the space (the Digital Crown, or the
// PS button on a Sense controller) and gives a new renderer when Play opens it again; the engine
// keeps running on the old thread, so the new renderer is handed over rather than relaunched.
std::mutex gRendererMutex;
std::condition_variable gRendererArrived;
cp_layer_renderer_t gNextRenderer = nil;
std::atomic<bool> gEngineLaunched{false};
ar_world_tracking_provider_t gWorldTracking = nil;
id<MTLCommandQueue> gQueue = nil;
// Whether gQueue is MoltenVK's own queue (AdoptEngineQueue).
bool gSharedQueue = false;

// Current frame, valid between BeginCompositorFrame and EndCompositorFrame.
cp_frame_t gFrame = NULL;
cp_drawable_t gDrawable = NULL;
ar_device_anchor_t gFrameAnchor = nil;
double gAnchorTime = 0;

// Frame pacing, logged every few seconds: rate, time from input sampling to commit, and frames
// committed after the compositor's rendering deadline (which it drops or shows late).
struct FrameStats
{
    CFTimeInterval windowStart = 0, frameStart = 0, deadline = 0;
    unsigned frames = 0, late = 0;
    double busyTotal = 0, busyMax = 0;
} gStats;
// When the GPU finished each presented frame against its rendering deadline, from the present
// command buffer's completion (another thread): frames, how many finished late, and the summed
// margin in microseconds (positive when early).
// Also the GPU's span for the frame, microseconds: from a marker committed on the engine's queue as
// the frame starts to the present finishing. Everything the engine submits runs between them, in
// order; if the GPU sits idle waiting for the CPU, that's counted too.
std::atomic<unsigned> gGpuFrames{0}, gGpuLate{0};
std::atomic<int64_t> gGpuMargin{0}, gGpuSpan{0};
id<MTLCommandBuffer> gFrameMarker = nil;
id<MTLBuffer> gMarkerBuffer = nil;
id<MTLTexture> gRenderTexture = nil;  // gEngineTexture, while a frame is open

// The engine renders both eyes into this 2-slice texture, never into the drawable, and
// EndCompositorFrame blits it across. The engine draws through a UNORM view of the sRGB image
// (PCVR's colour contract), which Metal allows only with MTLTextureUsagePixelFormatView. The
// drawables keep the default usage first proved on the headset (SHARConfiguration.swift),
// so this texture carries that usage instead. On the Simulator's mono drawable, only the left eye
// is blitted.
//
// Presenting paced by an event (SignalEngineFrame), the engine alternates between two, so it
// can draw a frame while the GPU presents the last one.
id<MTLTexture> gEngineTextures[2] = {nil, nil};
unsigned gEngineSlot = 0;
#define gEngineTexture gEngineTextures[gEngineSlot]

// Presenting paced by an event (opt-in: SHAR_PRESENT_EVENT=1, the launcher's "Pace frames on the
// GPU"). The engine's queue signals a timeline semaphore as each frame's work completes, and the
// present pass waits for it on the GPU, exported as an MTLSharedEvent (VK_EXT_metal_objects): no
// CPU drains the engine's queue, so the engine starts the next frame while the GPU finishes this
// one. The present pass stays on its own queue, as presenting with the wait does, rather than on
// MoltenVK's (AdoptEngineQueue), whose first headset run showed nothing.
VkSemaphore gPresentSemaphore = VK_NULL_HANDLE;
id<MTLSharedEvent> gPresentEvent = nil;
uint64_t gEngineFrameValue = 0;     // the last value signalled
bool gFrameSignalled = false;       // this frame's present waits for gEngineFrameValue
std::atomic<uint64_t> gPresentedValue{0};  // the last frame whose present has finished
double gPresentWaits = 0;           // seconds the CPU waited for a present, since the last stats

// The engine renders at this fraction of the drawable's size (the Graphics menu's Render Scale),
// and EndCompositorFrame's present pass scales the result into the drawable. Images the engine
// rendered into before a resize are destroyed a few frames later.
float gRenderScale = 1.0f;
struct RetiredImage { VkImage image; unsigned framesLeft; };
std::vector<RetiredImage> gRetiredImages;

// Drawables are pooled, so each colour texture is imported once. MoltenVK retains the imported
// texture, which also keeps its address from being reused while it is in this map.
std::map<void*, VkImage> gImportedImages;

// FXAA, the Window view and the compositor's depth, for the present pass. Content depth is a
// plane this far away until the game writes real reverse-Z depth; depth 0 is the far plane, and the
// headset shows nothing at all where a frame has it.
SharVisionOS::PresentOptions gPresent;

// The app's handler for the View setting, and the mode it was last told.
std::atomic<SharVisionOS_ViewHandler> gViewHandler{nullptr};
int gNotifiedView = -1;

// Set by SharVisionOS_WorldRecentered (main thread) and when frames move between the window and the
// immersive space, taken by the engine's next frame. gCrownRecentered is the first alone.
std::atomic<bool> gWorldRecentered{false};
std::atomic<bool> gCrownRecentered{false};

// The room behind menus (SharVisionOS_SetRoomBehindMenus), in a mixed Full space. A frame without
// the world (gFrameWorldDrawn false) shows the room where nothing is drawn: at once after another
// such frame, or after the game, black held for a quarter second (a quick door stays black) and
// then eased into the room over half a second. gHeadDistance (metres from the space's origin,
// across the floor) drives the safety boundary.
std::atomic<bool> gRoomBehindMenus{false};
bool gFrameWorldDrawn = true, gLastFrameWorldDrawn = true;
bool gMenuBackdrop = false;
float gFrameFade = 0;  // the game's fade to black this frame (SetFrameFade)
simd_float2 gMenuBackdropQuad[2][4] = {};
CFTimeInterval gSeeThroughSince = 0;
float gHeadDistance = 0;
simd_float4x4 gHeadTransform = matrix_identity_float4x4;
bool gHeadTransformValid = false;

VkFormat VkFormatForPixelFormat(MTLPixelFormat format)
{
    switch (format)
    {
        case MTLPixelFormatBGRA8Unorm_sRGB: return VK_FORMAT_B8G8R8A8_SRGB;
        case MTLPixelFormatBGRA8Unorm: return VK_FORMAT_B8G8R8A8_UNORM;
        case MTLPixelFormatRGBA8Unorm_sRGB: return VK_FORMAT_R8G8B8A8_SRGB;
        case MTLPixelFormatRGBA8Unorm: return VK_FORMAT_R8G8B8A8_UNORM;
        default: return VK_FORMAT_UNDEFINED;
    }
}

VkImage ImportTexture(id<MTLTexture> texture)
{
    auto cached = gImportedImages.find((__bridge void*)texture);
    if (cached != gImportedImages.end()) return cached->second;

    const VkFormat format = VkFormatForPixelFormat(texture.pixelFormat);
    if (format == VK_FORMAT_UNDEFINED)
    {
        NSLog(@"[SharVisionOS] unsupported drawable pixel format %lu", (unsigned long)texture.pixelFormat);
        return VK_NULL_HANDLE;
    }

    VkImportMetalTextureInfoEXT import = {VK_STRUCTURE_TYPE_IMPORT_METAL_TEXTURE_INFO_EXT};
    import.plane = VK_IMAGE_ASPECT_PLANE_0_BIT;
    import.mtlTexture = texture;

    // Same contract as an OpenXR swapchain image on PCVR: sRGB storage, rendered through a UNORM
    // view (hence MUTABLE_FORMAT, which needs MTLTextureUsagePixelFormatView on the texture;
    // gEngineTexture has it).
    VkImageCreateInfo info = {VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO};
    info.pNext = &import;
    info.flags = VK_IMAGE_CREATE_MUTABLE_FORMAT_BIT;
    info.imageType = VK_IMAGE_TYPE_2D;
    info.format = format;
    info.extent = {(uint32_t)texture.width, (uint32_t)texture.height, 1};
    info.mipLevels = 1;
    info.arrayLayers = (uint32_t)texture.arrayLength;
    info.samples = VK_SAMPLE_COUNT_1_BIT;
    info.tiling = VK_IMAGE_TILING_OPTIMAL;
    info.usage = VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | VK_IMAGE_USAGE_TRANSFER_DST_BIT |
                 VK_IMAGE_USAGE_TRANSFER_SRC_BIT | VK_IMAGE_USAGE_SAMPLED_BIT;
    info.sharingMode = VK_SHARING_MODE_EXCLUSIVE;
    info.initialLayout = VK_IMAGE_LAYOUT_UNDEFINED;

    VkImage image = VK_NULL_HANDLE;
    const VkResult result = vkCreateImage(SharOpenXR::GetVulkanContext().GetDevice(), &info, NULL, &image);
    if (result != VK_SUCCESS)
    {
        NSLog(@"[SharVisionOS] importing drawable texture failed (Vk %d)", (int)result);
        return VK_NULL_HANDLE;
    }
    NSLog(@"[SharVisionOS] imported colour texture %p: %lux%lu x%lu slices, format %lu", (__bridge void*)texture,
          (unsigned long)texture.width, (unsigned long)texture.height, (unsigned long)texture.arrayLength,
          (unsigned long)texture.pixelFormat);
    gImportedImages[(__bridge void*)texture] = image;
    return image;
}

// The current slot's (the other is replaced on its own turn, when it no longer fits).
void RetireEngineTexture()
{
    if (!gEngineTexture) return;
    auto imported = gImportedImages.find((__bridge void*)gEngineTexture);
    if (imported != gImportedImages.end())
    {
        SharOpenXR::GetVulkanContext().ReleaseRenderTarget(imported->second);
        gRetiredImages.push_back({imported->second, 3});
        gImportedImages.erase(imported);
    }
    gEngineTexture = nil;
}

void DestroyRetiredImages()
{
    VkDevice device = SharOpenXR::GetVulkanContext().GetDevice();
    for (size_t i = 0; i < gRetiredImages.size();)
    {
        if (gRetiredImages[i].framesLeft-- > 0) { ++i; continue; }
        if (device != VK_NULL_HANDLE) vkDestroyImage(device, gRetiredImages[i].image, NULL);
        gRetiredImages.erase(gRetiredImages.begin() + i);
    }
}

// The engine's 2-slice eye image at Render Scale times `width` x `height`, kept while that holds.
id<MTLTexture> EngineTexture(id<MTLDevice> device, NSUInteger fullWidth, NSUInteger fullHeight, MTLPixelFormat format)
{
    const NSUInteger width = std::max<NSUInteger>(1, (NSUInteger)std::lround(fullWidth * gRenderScale));
    const NSUInteger height = std::max<NSUInteger>(1, (NSUInteger)std::lround(fullHeight * gRenderScale));
    if (gEngineTexture && gEngineTexture.width == width && gEngineTexture.height == height &&
        gEngineTexture.pixelFormat == format)
        return gEngineTexture;
    RetireEngineTexture();

    MTLTextureDescriptor* descriptor = [MTLTextureDescriptor new];
    descriptor.textureType = MTLTextureType2DArray;
    descriptor.pixelFormat = format;
    descriptor.width = width;
    descriptor.height = height;
    descriptor.arrayLength = 2;
    descriptor.storageMode = MTLStorageModePrivate;
    descriptor.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead | MTLTextureUsagePixelFormatView;
    gEngineTexture = [device newTextureWithDescriptor:descriptor];
    NSLog(@"[SharVisionOS] rendering into a %lux%lu x2 texture (%.0f%% of %lux%lu)", (unsigned long)width,
          (unsigned long)height, gRenderScale * 100.0f, (unsigned long)fullWidth, (unsigned long)fullHeight);
    return gEngineTexture;
}

id<MTLTexture> EngineTextureMatching(id<MTLTexture> drawableTexture)
{
    return EngineTexture(drawableTexture.device, drawableTexture.width, drawableTexture.height,
                         drawableTexture.pixelFormat);
}

// A Vulkan image's own Metal texture (VK_EXT_metal_objects), for images the engine made.
id<MTLTexture> ExportTexture(VkImage image)
{
    static PFN_vkExportMetalObjectsEXT exportObjects = nullptr;
    VkDevice device = SharOpenXR::GetVulkanContext().GetDevice();
    if (!exportObjects)
        exportObjects = (PFN_vkExportMetalObjectsEXT)vkGetDeviceProcAddr(device, "vkExportMetalObjectsEXT");
    if (!exportObjects || image == VK_NULL_HANDLE) return nil;
    VkExportMetalTextureInfoEXT texture = {VK_STRUCTURE_TYPE_EXPORT_METAL_TEXTURE_INFO_EXT};
    texture.image = image;
    texture.plane = VK_IMAGE_ASPECT_PLANE_0_BIT;
    VkExportMetalObjectsInfoEXT info = {VK_STRUCTURE_TYPE_EXPORT_METAL_OBJECTS_INFO_EXT};
    info.pNext = &texture;
    exportObjects(device, &info);
    return texture.mtlTexture;
}

// The shared-space window (View: Window). visionOS gives an app no head pose or drawables outside a
// Full Space, so there the engine renders a fixed stereo pair through the window (see
// visionos_window.h), one frame per RealityKit update of the app's window. Each finished frame goes
// into one of three sets the app copies from.
std::atomic<bool> gWindowActive{false};
std::atomic<bool> gWindowVisible{true};  // its scene isn't in the background (else the game is held)
std::atomic<float> gWindowWidth{1.2f};  // metres, from the app
dispatch_semaphore_t gWindowTick = dispatch_semaphore_create(0);
bool gWindowFrame = false;   // the frame in progress is for the window
float gWindowEyeOffset = 0;  // the frame in progress's, game metres
std::mutex gWindowMutex;     // guards the frame bookkeeping below
SharVisionOS::WindowFrameOutput gWindowFrames[3];
int gWindowLatest = -1, gWindowReading = -1;
bool gWindowWriting[3] = {false, false, false};  // a frame's GPU work is still writing the set
unsigned gWindowSlotReuses = 0;                  // since the last stats line: see EndWindowFrame
uint64_t gWindowSerial = 0;

// The game's sound stops while the game is held (IsCompositorRunning) and while visionOS has
// interrupted the app's audio. A held game thread stops refilling its sound streams, so their last
// few seconds looped; after an interruption, nothing restarts the output. Pausing OpenAL Soft's
// device (ALC_SOFT_pause_device) stops mixing and the output, and resuming starts both again.
enum : uint32_t { kSoundHeldForGame = 1, kSoundHeldForInterruption = 2 };
std::mutex gSoundMutex;
uint32_t gSoundHolds = 0;

void HoldSound(uint32_t reason, bool hold)
{
    std::lock_guard<std::mutex> lock(gSoundMutex);
    const uint32_t before = gSoundHolds;
    gSoundHolds = hold ? before | reason : before & ~reason;
    if ((before != 0) == (gSoundHolds != 0)) return;
    ALCcontext* context = alcGetCurrentContext();
    ALCdevice* device = context ? alcGetContextsDevice(context) : nullptr;
    if (!device || !alcIsExtensionPresent(device, "ALC_SOFT_pause_device")) return;
    if (gSoundHolds)
        reinterpret_cast<LPALCDEVICEPAUSESOFT>(alcGetProcAddress(device, "alcDevicePauseSOFT"))(device);
    else
        reinterpret_cast<LPALCDEVICERESUMESOFT>(alcGetProcAddress(device, "alcDeviceResumeSOFT"))(device);
    NSLog(@"[SharVisionOS] sound %s", gSoundHolds ? "paused" : "resumed");
}

// Set when the game comes back from being held; the game reads it (ConsumeResumeFromHold) to come
// back on its pause menu.
std::atomic<bool> gResumedFromHold{false};

// The scene before the HUD, which the engine copies here at its HDR resolve (matches the engine
// texture).
id<MTLTexture> gWindowScene = nil;

id<MTLTexture> WindowSceneTexture(id<MTLTexture> engine)
{
    if (gWindowScene && gWindowScene.width == engine.width && gWindowScene.height == engine.height &&
        gWindowScene.pixelFormat == engine.pixelFormat)
        return gWindowScene;
    SharOpenXR::GetVulkanContext().SetWindowSceneCapture(VK_NULL_HANDLE, VK_NULL_HANDLE);
    if (gWindowScene)
    {
        auto imported = gImportedImages.find((__bridge void*)gWindowScene);
        if (imported != gImportedImages.end())
        {
            gRetiredImages.push_back({imported->second, 3});
            gImportedImages.erase(imported);
        }
    }
    MTLTextureDescriptor* descriptor = [MTLTextureDescriptor new];
    descriptor.textureType = MTLTextureType2DArray;
    descriptor.pixelFormat = engine.pixelFormat;
    descriptor.width = engine.width;
    descriptor.height = engine.height;
    descriptor.arrayLength = 2;
    descriptor.storageMode = MTLStorageModePrivate;
    descriptor.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead | MTLTextureUsagePixelFormatView;
    gWindowScene = [engine.device newTextureWithDescriptor:descriptor];
    return gWindowScene;
}

XrFovf WindowEyeFov(float offset)
{
    // An off-axis frustum through the window, centred between the eyes, reaching past its edges by
    // the overscan.
    const float horizontal = SharVisionOS::kWindowHalfFovTangent + SharVisionOS::kWindowOverscanX,
                vertical = SharVisionOS::WindowHalfHeightTangent() + SharVisionOS::kWindowOverscanY,
                shift = offset / SharVisionOS::kWindowPlaneDistance;
    XrFovf fov;
    fov.angleLeft = -std::atan(horizontal + shift);
    fov.angleRight = std::atan(horizontal - shift);
    fov.angleUp = std::atan(vertical);
    fov.angleDown = -std::atan(vertical);
    return fov;
}

XrPosef PoseFromTransform(simd_float4x4 transform)
{
    const simd_quatf rotation = simd_quaternion(transform);
    XrPosef pose;
    pose.orientation = {rotation.vector.x, rotation.vector.y, rotation.vector.z, rotation.vector.w};
    pose.position = {transform.columns[3].x, transform.columns[3].y, transform.columns[3].z};
    return pose;
}

// ViewTangents gives the frustum edges as tangent magnitudes (left, right, top, bottom).
XrFovf FovFromTangents(simd_float4 tangents)
{
    XrFovf fov;
    fov.angleLeft = -std::atan(tangents.x);
    fov.angleRight = std::atan(tangents.y);
    fov.angleUp = std::atan(tangents.z);
    fov.angleDown = -std::atan(tangents.w);
    return fov;
}

void* RunEngine(void* argument)
{
    std::string* dataDirectory = static_cast<std::string*>(argument);
    if (!dataDirectory->empty() && chdir(dataDirectory->c_str()) != 0)
        NSLog(@"[SharVisionOS] chdir to game data failed: %s", dataDirectory->c_str());
    delete dataDirectory;

    SDL_SetMainReady();
    // MoltenVK warns once per pipeline that Metal can't disable primitive restart, harmlessly;
    // at that volume visionOS starts dropping the app's log lines. Errors only, unless overridden.
    setenv("MVK_CONFIG_LOG_LEVEL", "1", 0);
    // Controllers are read straight from GameController (visionos_controllers.mm and
    // ReadGamepad) and reach the game as virtual input. SDL's MFi driver would also feed them in
    // directly, one gamepad per Sense half (the left half's Square as "A", both sticks as the left
    // stick), fighting that input; it also touches UIKit from this thread. So it's off.
    SDL_SetHint(SDL_HINT_JOYSTICK_MFI, "0");
    // The game still only takes input while a gamepad is connected: UserController learns its
    // input names from one. An idle virtual SDL gamepad, which never reports anything, is that
    // gamepad.
    if (SDL_InitSubSystem(SDL_INIT_GAMEPAD))
    {
        SDL_VirtualJoystickDesc pad;
        SDL_INIT_INTERFACE(&pad);
        pad.type = SDL_JOYSTICK_TYPE_GAMEPAD;
        pad.name = "SHAR VR input";
        // The game's own rumble (radController drives the gamepad's two motors) goes to the real
        // controllers.
        pad.Rumble = [](void*, Uint16 low, Uint16 high) {
            SharVisionOS::SetRumble(low / 65535.0f, high / 65535.0f);
            return true;
        };
        if (!SDL_AttachVirtualJoystick(&pad))
            NSLog(@"[SharVisionOS] couldn't attach the virtual gamepad: %s", SDL_GetError());
    }
    // Upstream's command-line options (commandlineoptions.cpp), for Simulator test runs only: e.g.
    // SIMCTL_CHILD_SHAR_ARGS="skipfe" boots straight into level 1.
    std::vector<std::string> arguments = {"SimpsonsVR"};
#if TARGET_OS_SIMULATOR
    if (const char* extra = getenv("SHAR_ARGS"))
    {
        std::istringstream words(extra);
        for (std::string word; words >> word;) arguments.push_back(word);
    }
#endif
    std::vector<char*> argv;
    for (std::string& argument : arguments) argv.push_back(&argument[0]);
    argv.push_back(nullptr);
    NSLog(@"[SharVisionOS] engine thread starting");
    const int result = SDL_main((int)arguments.size(), argv.data());
    NSLog(@"[SharVisionOS] engine exited with %d", result);
    return NULL;
}
}

extern "C" void SharVisionOS_SetViewHandler(SharVisionOS_ViewHandler handler)
{
    gViewHandler = handler;
}

extern "C" void SharVisionOS_SetRoomBehindMenus(bool enabled)
{
    gRoomBehindMenus = enabled;
}

extern "C" void SharVisionOS_WorldRecentered(void)
{
    gCrownRecentered = true;
    gWorldRecentered = true;
}

extern "C" void SharVisionOS_SetWindowActive(bool active)
{
    std::lock_guard<std::mutex> lock(gRendererMutex);
    gWindowActive = active;
    // A window that opens is in the foreground.
    if (active) gWindowVisible = true;
    gRendererArrived.notify_all();
}

extern "C" void SharVisionOS_SetWindowVisible(bool visible)
{
    std::lock_guard<std::mutex> lock(gRendererMutex);
    gWindowVisible = visible;
    gRendererArrived.notify_all();
}

extern "C" void SharVisionOS_SetAudioInterrupted(bool interrupted)
{
    HoldSound(kSoundHeldForInterruption, interrupted);
}

extern "C" void SharVisionOS_WindowTick(void)
{
    dispatch_semaphore_signal(gWindowTick);
}

extern "C" void SharVisionOS_SetWindowWidth(float metres)
{
    gWindowWidth = metres;
}

extern "C" uint64_t SharVisionOS_WindowFrame(int* eyeWidth, int* eyeHeight, int* hudWidth, int* hudHeight)
{
    std::lock_guard<std::mutex> lock(gWindowMutex);
    if (gWindowLatest < 0) return 0;
    const SharVisionOS::WindowFrameOutput& frame = gWindowFrames[gWindowLatest];
    if (eyeWidth) *eyeWidth = (int)frame.colour.width / 2;
    if (eyeHeight) *eyeHeight = (int)frame.colour.height;
    if (hudWidth) *hudWidth = (int)frame.hud.width;
    if (hudHeight) *hudHeight = (int)frame.hud.height;
    return gWindowSerial;
}

// The HUD's top level, then its mipmaps: the window shows it smaller than it's drawn, most of all
// far off or at an angle, and with one level its text and menus sparkled. Its alpha is
// premultiplied, so the levels average correctly.
static void CopyWindowHudLevels(id<MTLBlitCommandEncoder> blit, id<MTLTexture> from, id<MTLTexture> to)
{
    [blit copyFromTexture:from sourceSlice:0 sourceLevel:0 toTexture:to destinationSlice:0 destinationLevel:0
               sliceCount:1 levelCount:1];
    if (to.mipmapLevelCount > 1) [blit generateMipmapsForTexture:to];
}

extern "C" void SharVisionOS_CopyWindowFrame(id<MTLCommandBuffer> commands, id<MTLTexture> colour, id<MTLTexture> hud,
                                             NSArray<id<MTLBuffer>>* positions, NSArray<id<MTLBuffer>>* indices)
{
    SharVisionOS::WindowFrameOutput frame;
    {
        std::lock_guard<std::mutex> lock(gWindowMutex);
        if (gWindowLatest >= 0)
        {
            gWindowReading = gWindowLatest;
            frame = gWindowFrames[gWindowLatest];
        }
    }
    const NSUInteger layerSize = SHARVISIONOS_WINDOW_GRID_VERTICES * sizeof(float) * 3;
    const NSUInteger cutSize = SHARVISIONOS_WINDOW_GRID_INDICES * sizeof(uint32_t);
    bool matches = frame.colour && frame.colour.width == colour.width && frame.colour.height == colour.height &&
                   frame.hud.width == hud.width && frame.hud.height == hud.height && positions.count == 6 &&
                   indices.count == 4;
    for (id<MTLBuffer> buffer in positions) matches = matches && buffer.length >= layerSize;
    for (id<MTLBuffer> buffer in indices) matches = matches && buffer.length >= cutSize;
    if (matches)
    {
        id<MTLBlitCommandEncoder> blit = [commands blitCommandEncoder];
        [blit copyFromTexture:frame.colour toTexture:colour];
        CopyWindowHudLevels(blit, frame.hud, hud);
        for (NSUInteger i = 0; i < 6; ++i)
            [blit copyFromBuffer:frame.positions sourceOffset:i * layerSize toBuffer:positions[i] destinationOffset:0
                            size:layerSize];
        for (NSUInteger i = 0; i < 4; ++i)
            [blit copyFromBuffer:frame.indices sourceOffset:i * cutSize toBuffer:indices[i] destinationOffset:0
                            size:cutSize];
        [blit endEncoding];
    }
    else
    {
        // A size change raced the copy: show black for a frame rather than whatever was there.
        for (id<MTLTexture> texture in @[colour, hud])
        {
            MTLRenderPassDescriptor* pass = [MTLRenderPassDescriptor renderPassDescriptor];
            pass.colorAttachments[0].texture = texture;
            pass.colorAttachments[0].loadAction = MTLLoadActionClear;
            pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, texture == colour ? 1 : 0);
            pass.colorAttachments[0].storeAction = MTLStoreActionStore;
            [[commands renderCommandEncoderWithDescriptor:pass] endEncoding];
        }
        // The clear is level 0's: the HUD's other levels from it.
        if (hud.mipmapLevelCount > 1)
        {
            id<MTLBlitCommandEncoder> blit = [commands blitCommandEncoder];
            [blit generateMipmapsForTexture:hud];
            [blit endEncoding];
        }
    }
    [commands addCompletedHandler:^(id<MTLCommandBuffer>) {
        std::lock_guard<std::mutex> lock(gWindowMutex);
        gWindowReading = -1;
    }];
}

extern "C" void SharVisionOS_CopyWindowHud(id<MTLCommandBuffer> commands, id<MTLTexture> hud)
{
    SharVisionOS::WindowFrameOutput frame;
    {
        std::lock_guard<std::mutex> lock(gWindowMutex);
        if (gWindowLatest >= 0)
        {
            gWindowReading = gWindowLatest;
            frame = gWindowFrames[gWindowLatest];
        }
    }
    if (frame.hud && frame.hud.width == hud.width && frame.hud.height == hud.height)
    {
        id<MTLBlitCommandEncoder> blit = [commands blitCommandEncoder];
        CopyWindowHudLevels(blit, frame.hud, hud);
        [blit endEncoding];
    }
    [commands addCompletedHandler:^(id<MTLCommandBuffer>) {
        std::lock_guard<std::mutex> lock(gWindowMutex);
        gWindowReading = -1;
    }];
}

extern "C" bool SharVisionOS_IsEngineRunning(void)
{
    return gEngineLaunched;
}

extern "C" void SharVisionOS_Launch(cp_layer_renderer_t renderer, const char* dataDirectory)
{
    if (gEngineLaunched.exchange(true))
    {
        if (!renderer) return;
        std::lock_guard<std::mutex> lock(gRendererMutex);
        gNextRenderer = renderer;
        gRendererArrived.notify_all();
        return;
    }
    gRenderer = renderer;

#if TARGET_OS_SIMULATOR
    // On the Simulator's GPU (read-write texture tier 1), MoltenVK's Metal argument buffers never
    // write storage images: the volumetric light's froxels stayed zero and the scene went black.
    // Discrete binding fixes that at no measurable cost. The headset keeps argument buffers. Set
    // before the first Vulkan call, when MoltenVK reads its configuration; the environment can
    // still override it.
    setenv("MVK_CONFIG_USE_METAL_ARGUMENT_BUFFERS", "0", 0);
#endif
    // vkQueueSubmit commits its Metal command buffers before it returns, which is what lets the
    // present pass follow the engine's frame on the same queue without a wait (AdoptEngineQueue,
    // opt-in).
    const char* wanted = getenv("SHAR_PRESENT_WITHOUT_WAIT");
    if (wanted && *wanted) setenv("MVK_CONFIG_SYNCHRONOUS_QUEUE_SUBMITS", "1", 1);

    // Apple gives secondary threads a 512 KB stack; the engine was written for a main thread's.
    pthread_attr_t attributes;
    pthread_attr_init(&attributes);
    pthread_attr_setstacksize(&attributes, 16 * 1024 * 1024);
    pthread_t thread;
    auto* directory = new std::string(dataDirectory ? dataDirectory : "");
    if (pthread_create(&thread, &attributes, RunEngine, directory) == 0)
        pthread_detach(thread);
    else
        NSLog(@"[SharVisionOS] could not start the engine thread");
    pthread_attr_destroy(&attributes);
}

namespace SharVisionOS
{
bool InitializeCompositor()
{
    // Launched from the window there is no layer renderer yet; both use the system's GPU.
    id<MTLDevice> device = gRenderer ? cp_layer_renderer_get_device(gRenderer) : MTLCreateSystemDefaultDevice();
    gQueue = [device newCommandQueue];

    // ARKit only delivers data in a Full Space; in the window the providers wait for one.
    gWorldTracking = ar_world_tracking_provider_create(ar_world_tracking_configuration_create());
    gSession = ar_session_create();
    ar_session_run(gSession, ar_data_providers_create_with_data_providers(gWorldTracking, nil));
    NSLog(@"[SharVisionOS] compositor ready on %@", device.name);
    return true;
}

void ShutdownCompositor()
{
    VkDevice device = SharOpenXR::GetVulkanContext().GetDevice();
    for (auto& entry : gImportedImages)
        if (device != VK_NULL_HANDLE) vkDestroyImage(device, entry.second, NULL);
    gImportedImages.clear();
    if (gSession) ar_session_stop(gSession);
    gSession = nil;
    gWorldTracking = nil;
    gEngineTextures[0] = gEngineTextures[1] = nil;
}

bool ConsumeResumeFromHold()
{
    return gResumedFromHold.exchange(false);
}

bool IsCompositorRunning()
{
    // Frames go to whichever is open: the game's window, else its immersive space. The app opens
    // one before closing the other. With neither, the game holds here until one opens; also while
    // the space is paused (the headset off) or the window is in the background. A held game makes
    // no sound and no rumble.
    bool held = false;
    const auto hold = [&held] {
        if (held) return;
        held = true;
        SetRumble(0, 0);
        HoldSound(kSoundHeldForGame, true);
    };
    const auto resume = [&held] {
        if (!held) return true;
        HoldSound(kSoundHeldForGame, false);
        gResumedFromHold = true;
        NSLog(@"[SharVisionOS] the game resumes");
        return true;
    };
    for (;;)
    {
        {
            std::unique_lock<std::mutex> lock(gRendererMutex);
            if (gNextRenderer)
            {
                gRenderer = gNextRenderer;
                gNextRenderer = nil;
            }
        }
        const bool window = gWindowActive;
        if (window != gWindowFrame)
        {
            // The views jump between the head and the window's fixed pair: re-anchor the game.
            gWindowFrame = window;
            gWorldRecentered = true;
            if (!window)
            {
                SharOpenXR::GetVulkanContext().SetWindowSceneCapture(VK_NULL_HANDLE, VK_NULL_HANDLE);
                SharOpenXR::GetVulkanContext().SetWindowMirrorOnly(false);
                SharOpenXR::GetVulkanContext().SetWindowMetering(false);
            }
            NSLog(@"[SharVisionOS] presenting to the %s", window ? "window" : "immersive space");
        }
        if (window)
        {
            if (gWindowVisible) return resume();
            // Hidden or in the background, where visionOS may refuse the GPU work: wait for it to
            // come back (or close) rather than rendering on.
            NSLog(@"[SharVisionOS] the game's window is in the background; held until it's back");
            hold();
            std::unique_lock<std::mutex> lock(gRendererMutex);
            gRendererArrived.wait(lock, [] { return gWindowVisible || !gWindowActive || gNextRenderer != nil; });
            continue;
        }
        if (gRenderer && cp_layer_renderer_get_state(gRenderer) != cp_layer_renderer_state_invalidated)
        {
            switch (cp_layer_renderer_get_state(gRenderer))
            {
                case cp_layer_renderer_state_paused:
                    hold();
                    cp_layer_renderer_wait_until_running(gRenderer);
                    // Running again, or invalidated (the space closed): the loop sees which.
                    continue;
                case cp_layer_renderer_state_running:
                    return resume();
                default:
                    return false;
            }
        }
        NSLog(@"[SharVisionOS] nothing to present to; paused until the game's space or window opens");
        hold();
        std::unique_lock<std::mutex> lock(gRendererMutex);
        gRendererArrived.wait(lock, [] { return gNextRenderer != nil || gWindowActive; });
    }
}

// Every twelfth window frame meters the world for the mirror's exposure: 7.5 times a second at
// 90 Hz, plenty for an exposure that adapts over half a second or so, for a twelfth of the world
// drawing that mirror-only mode saves.
constexpr uint32_t kWindowMeterInterval = 12;

bool BeginWindowFrame(XrView views[2], bool* tracked, uint32_t* width, uint32_t* height)
{
    // Paced by the window's RealityKit updates; a hidden window stops ticking, so time out.
    dispatch_semaphore_wait(gWindowTick, dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC));
    while (dispatch_semaphore_wait(gWindowTick, DISPATCH_TIME_NOW) == 0) {}
    const CFTimeInterval lastStart = gStats.frameStart;
    gStats.frameStart = CACurrentMediaTime();
    gStats.deadline = gStats.frameStart + 1.0 / 90.0;
    DestroyRetiredImages();
    // The window's pixel density, over the overscan too.
    gRenderTexture = EngineTexture(
        gQueue.device, (NSUInteger)std::lround(kWindowEyeWidth * (1.0f + kWindowOverscanX / kWindowHalfFovTangent)),
        (NSUInteger)std::lround(kWindowEyeHeight * (1.0f + kWindowOverscanY / WindowHalfHeightTangent())),
        MTLPixelFormatBGRA8Unorm_sRGB);
    *width = (uint32_t)gRenderTexture.width;
    *height = (uint32_t)gRenderTexture.height;
    // The scene goes to the capture as the engine resolves it, before the HUD goes over it.
    const VkImage scene = ImportTexture(WindowSceneTexture(gRenderTexture));
    SharOpenXR::GetVulkanContext().SetWindowSceneCapture(ImportTexture(gRenderTexture), scene);
    // The eyes are where a viewer's would be for the window's picture to be true to life, which
    // depends on how big the window is.
    gWindowEyeOffset = WindowEyeOffset(gWindowWidth);
    SharOpenXR::GetVulkanContext().SetTransparentEyeClear(false);
    // The mirror's exposure comes from a metering frame every so often (SetWindowMetering).
    SharOpenXR::VulkanContext& context = SharOpenXR::GetVulkanContext();
    const float seconds = lastStart > 0 ? (float)std::min(gStats.frameStart - lastStart, 0.1) : 0.0f;
    // The game's iris-wipe fade (the last frame's, SetFrameFade) darkens the mirror to black as it
    // would the engine's picture. Never quite 0, which the app reads as no exposure yet.
    const float shown = std::max(1.0f - std::min(std::max(gFrameFade, 0.0f), 1.0f), 1e-4f);
    BeginMirrorFrame(gWindowEyeOffset, context.UpdateWindowExposure(seconds) * shown);
    static uint32_t windowFrames = 0;
    context.SetWindowMirrorOnly(IsMirrorEnabled());
    context.SetWindowMetering(IsMirrorEnabled() && ++windowFrames % kWindowMeterInterval == 0);
    for (size_t eye = 0; eye < 2; ++eye)
    {
        const float offset = eye == 0 ? -gWindowEyeOffset : gWindowEyeOffset;
        views[eye].type = XR_TYPE_VIEW;
        views[eye].next = NULL;
        views[eye].pose.orientation = {0.0f, 0.0f, 0.0f, 1.0f};
        views[eye].pose.position = {offset, 0.0f, 0.0f};
        views[eye].fov = WindowEyeFov(offset);
    }
    *tracked = true;
    gFrameAnchor = nil;
    gAnchorTime = 0;
    return true;
}

// The compositor's Metal work (the present pass, the window's frame) reads what the engine drew. On
// a queue of its own it needed the engine's queue drained first, every frame, which kept the CPU
// from starting the next frame while the GPU finished this one: in level 3 that wait was 40% of
// the engine thread. On MoltenVK's own queue, command buffers run in the order they were
// committed, and Metal orders a tracked texture's write before a later read (and that read before
// the next frame's write into the same texture), so nothing waits.
//
// Opt-in (SHAR_PRESENT_WITHOUT_WAIT=1) until it's proven on the headset. The first headset run with
// it on by default showed nothing, though the engine ran at 90 fps and every present finished
// before its deadline. Unconfirmed suspect: the engine draws through a UNORM view of the texture
// the present pass reads, and nothing establishes that Metal orders a write through a view before
// a read of its parent.
void AdoptEngineQueue()
{
    if (gSharedQueue) return;
    static bool tried = false;
    if (tried) return;
    tried = true;
    const char* wanted = getenv("SHAR_PRESENT_WITHOUT_WAIT");
    if (!wanted || !*wanted)
    {
        NSLog(@"[SharVisionOS] presenting on its own queue after the engine's (SHAR_PRESENT_WITHOUT_WAIT=1 "
              @"tries without the wait)");
        return;
    }
    VkDevice device = SharOpenXR::GetVulkanContext().GetDevice();
    auto exportObjects = (PFN_vkExportMetalObjectsEXT)vkGetDeviceProcAddr(device, "vkExportMetalObjectsEXT");
    if (!exportObjects) return;
    VkExportMetalCommandQueueInfoEXT queue = {VK_STRUCTURE_TYPE_EXPORT_METAL_COMMAND_QUEUE_INFO_EXT};
    queue.queue = SharOpenXR::GetVulkanContext().GetQueue();
    VkExportMetalObjectsInfoEXT info = {VK_STRUCTURE_TYPE_EXPORT_METAL_OBJECTS_INFO_EXT};
    info.pNext = &queue;
    exportObjects(device, &info);
    if (!queue.mtlCommandQueue || queue.mtlCommandQueue.device != gQueue.device)
    {
        NSLog(@"[SharVisionOS] MoltenVK's queue isn't available; each frame waits for the engine's");
        return;
    }
    gQueue = queue.mtlCommandQueue;
    gSharedQueue = true;
    NSLog(@"[SharVisionOS] presenting on MoltenVK's queue");
}

bool SharesEngineQueue()
{
    return gSharedQueue;
}

bool CurrentHeadTransform(simd_float4x4* originFromDevice)
{
    if (!gHeadTransformValid || gWindowFrame) return false;
    *originFromDevice = gHeadTransform;
    return true;
}

bool RoomBehindMenusActive()
{
    // View Full only: a progressive portal shows black where frames are transparent.
    return gRoomBehindMenus && gNotifiedView == 0 && !gWindowFrame;
}

void SetFrameWorldDrawn(bool drawn)
{
    gFrameWorldDrawn = drawn;
}

void SetFrameFade(float fade)
{
    gFrameFade = fade;
}

void SetMenuBackdrop(bool shown, const float quads[2][8])
{
    gMenuBackdrop = shown;
    for (int eye = 0; eye < 2; ++eye)
        for (int k = 0; k < 4; ++k)
            gMenuBackdropQuad[eye][k] = simd_make_float2(quads[eye][k * 2], quads[eye][k * 2 + 1]);
}

// The timeline semaphore the engine's queue signals each frame, and its MTLSharedEvent.
bool PresentEventReady()
{
    if (gPresentEvent) return true;
    static bool tried = false;
    if (tried) return false;
    tried = true;
    const char* wanted = getenv("SHAR_PRESENT_EVENT");
    if (!wanted || !*wanted || gSharedQueue) return false;
    SharOpenXR::VulkanContext& context = SharOpenXR::GetVulkanContext();
    VkDevice device = context.GetDevice();
    auto exportObjects = (PFN_vkExportMetalObjectsEXT)vkGetDeviceProcAddr(device, "vkExportMetalObjectsEXT");
    if (!context.IsTimelineSemaphoreSupported() || !exportObjects)
    {
        NSLog(@"[SharVisionOS] no timeline semaphores; each frame waits for the engine's");
        return false;
    }
    VkExportMetalObjectCreateInfoEXT exportable = {VK_STRUCTURE_TYPE_EXPORT_METAL_OBJECT_CREATE_INFO_EXT};
    exportable.exportObjectType = VK_EXPORT_METAL_OBJECT_TYPE_METAL_SHARED_EVENT_BIT_EXT;
    VkSemaphoreTypeCreateInfo type = {VK_STRUCTURE_TYPE_SEMAPHORE_TYPE_CREATE_INFO};
    type.pNext = &exportable;
    type.semaphoreType = VK_SEMAPHORE_TYPE_TIMELINE;
    type.initialValue = 0;
    VkSemaphoreCreateInfo info = {VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO};
    info.pNext = &type;
    if (vkCreateSemaphore(device, &info, NULL, &gPresentSemaphore) != VK_SUCCESS)
    {
        NSLog(@"[SharVisionOS] couldn't make the present's timeline semaphore; each frame waits");
        gPresentSemaphore = VK_NULL_HANDLE;
        return false;
    }
    VkExportMetalSharedEventInfoEXT shared = {VK_STRUCTURE_TYPE_EXPORT_METAL_SHARED_EVENT_INFO_EXT};
    shared.semaphore = gPresentSemaphore;
    VkExportMetalObjectsInfoEXT objects = {VK_STRUCTURE_TYPE_EXPORT_METAL_OBJECTS_INFO_EXT};
    objects.pNext = &shared;
    exportObjects(device, &objects);
    if (!shared.mtlSharedEvent || shared.mtlSharedEvent.device != gQueue.device)
    {
        NSLog(@"[SharVisionOS] the present's semaphore has no shared event; each frame waits");
        vkDestroySemaphore(device, gPresentSemaphore, NULL);
        gPresentSemaphore = VK_NULL_HANDLE;
        return false;
    }
    gPresentEvent = shared.mtlSharedEvent;
    NSLog(@"[SharVisionOS] presenting paced by an event: the CPU doesn't wait for the GPU");
    return true;
}

bool SignalEngineFrame()
{
    gFrameSignalled = false;
    if (gWindowFrame || !gFrame || !PresentEventReady()) return false;
    const uint64_t value = gEngineFrameValue + 1;
    VkTimelineSemaphoreSubmitInfo timeline = {VK_STRUCTURE_TYPE_TIMELINE_SEMAPHORE_SUBMIT_INFO};
    timeline.signalSemaphoreValueCount = 1;
    timeline.pSignalSemaphoreValues = &value;
    VkSubmitInfo submit = {VK_STRUCTURE_TYPE_SUBMIT_INFO};
    submit.pNext = &timeline;
    submit.signalSemaphoreCount = 1;
    submit.pSignalSemaphores = &gPresentSemaphore;
    const VkResult result = vkQueueSubmit(SharOpenXR::GetVulkanContext().GetQueue(), 1, &submit, VK_NULL_HANDLE);
    if (result != VK_SUCCESS)
    {
        NSLog(@"[SharVisionOS] signalling the frame failed (Vk %d); this frame waits", (int)result);
        return false;
    }
    gEngineFrameValue = value;
    gFrameSignalled = true;
    return true;
}

bool BeginCompositorFrame(XrView views[2], bool* tracked, uint32_t* width, uint32_t* height)
{
    *tracked = false;
    AdoptEngineQueue();
    if (gWindowFrame) return BeginWindowFrame(views, tracked, width, height);
    gFrame = cp_layer_renderer_query_next_frame(gRenderer);
    if (!gFrame) return false;

    cp_frame_timing_t timing = cp_frame_predict_timing(gFrame);
    if (!timing)
    {
        gFrame = NULL;
        return false;
    }
    cp_frame_start_update(gFrame);
    cp_frame_end_update(gFrame);
    cp_time_wait_until(cp_frame_timing_get_optimal_input_time(timing));

    cp_frame_start_submission(gFrame);
    gFrameSignalled = false;
    gStats.frameStart = CACurrentMediaTime();
    gStats.deadline = cp_time_to_cf_time_interval(cp_frame_timing_get_rendering_deadline(timing));
    // The GPU span's start (gGpuSpan): a four-byte fill, so the GPU runs it and times it.
    gFrameMarker = nil;
    if (gSharedQueue)
    {
        if (!gMarkerBuffer) gMarkerBuffer = [gQueue.device newBufferWithLength:4 options:MTLResourceStorageModePrivate];
        gFrameMarker = [gQueue commandBuffer];
        id<MTLBlitCommandEncoder> blit = [gFrameMarker blitCommandEncoder];
        [blit fillBuffer:gMarkerBuffer range:NSMakeRange(0, 4) value:0];
        [blit endEncoding];
        [gFrameMarker commit];
    }
    gDrawable = cp_frame_query_drawable(gFrame);
    if (!gDrawable)
    {
        // No drawable (the space is going away): the frame is invalid and must not be ended.
        gFrame = NULL;
        return false;
    }

    id<MTLTexture> colour = cp_drawable_get_color_texture(gDrawable, 0);
    DestroyRetiredImages();
    if (gPresentEvent)
    {
        // The other texture, once the present that read it (two frames ago) is done with it.
        gEngineSlot ^= 1;
        const CFTimeInterval waitStart = CACurrentMediaTime();
        while (gPresentedValue.load() + 1 < gEngineFrameValue && CACurrentMediaTime() - waitStart < 0.1)
            usleep(100);
        gPresentWaits += CACurrentMediaTime() - waitStart;
    }
    gRenderTexture = EngineTextureMatching(colour);
    *width = (uint32_t)gRenderTexture.width;
    *height = (uint32_t)gRenderTexture.height;

    // The anchor goes on the drawable and is read at present time, so each frame gets its own.
    gFrameAnchor = ar_device_anchor_create();
    gAnchorTime = cp_time_to_cf_time_interval(
        cp_frame_timing_get_trackable_anchor_time(cp_drawable_get_frame_timing(gDrawable)));
    const CFTimeInterval presentation =
        cp_time_to_cf_time_interval(cp_frame_timing_get_presentation_time(cp_drawable_get_frame_timing(gDrawable)));
    const bool anchored = gWorldTracking &&
        ar_world_tracking_provider_query_device_anchor_at_timestamp(gWorldTracking, presentation, gFrameAnchor) ==
            ar_device_anchor_query_status_success;
    // A frame without its own anchor carries the last good one: a drawable without any isn't
    // presented at all.
    static ar_device_anchor_t lastAnchor = nil;
    if (anchored)
        lastAnchor = gFrameAnchor;
    else
        gFrameAnchor = lastAnchor;

    const simd_float4x4 originFromDevice =
        anchored ? ar_anchor_get_origin_from_anchor_transform(gFrameAnchor) : matrix_identity_float4x4;
    gHeadDistance = anchored ? simd_length(simd_make_float2(originFromDevice.columns[3].x, originFromDevice.columns[3].z)) : 0;
    gHeadTransform = originFromDevice;
    gHeadTransformValid = anchored;
    SharOpenXR::GetVulkanContext().SetTransparentEyeClear(RoomBehindMenusActive());
    const size_t viewCount = cp_drawable_get_view_count(gDrawable);
    for (size_t eye = 0; eye < 2; ++eye)
    {
        cp_view_t view = cp_drawable_get_view(gDrawable, eye < viewCount ? eye : 0);
        views[eye].type = XR_TYPE_VIEW;
        views[eye].next = NULL;
        views[eye].pose = PoseFromTransform(simd_mul(originFromDevice, cp_view_get_transform(view)));
        views[eye].fov = FovFromTangents(ViewTangents(gDrawable, eye < viewCount ? eye : 0));
    }
    *tracked = anchored;

    static unsigned logged = 0;
    if (logged++ == 0)
    {
        const simd_float4 t = ViewTangents(gDrawable, 0);
        NSLog(@"[SharVisionOS] first frame: %zu view(s), colour %lux%lu x%lu, tangents %.3f %.3f %.3f %.3f, "
              @"anchored %d, head y %.3f", viewCount, (unsigned long)colour.width, (unsigned long)colour.height,
              (unsigned long)colour.arrayLength, t.x, t.y, t.z, t.w, anchored ? 1 : 0, originFromDevice.columns[3].y);
    }
    return true;
}

VkImage GetCompositorColorImage()
{
    return gRenderTexture ? ImportTexture(gRenderTexture) : VK_NULL_HANDLE;
}

VkFormat GetCompositorColorFormat()
{
    return gRenderTexture ? VkFormatForPixelFormat(gRenderTexture.pixelFormat) : VK_FORMAT_UNDEFINED;
}

// Every 5 s: frame rate, the time from input sampling to commit, frames committed after the
// deadline, and memory.
void RecordFrameStats()
{
    const CFTimeInterval now = CACurrentMediaTime();
    const double busy = now - gStats.frameStart;
    if (gStats.windowStart == 0) gStats.windowStart = now;
    ++gStats.frames;
    gStats.late += now > gStats.deadline ? 1 : 0;
    gStats.busyTotal += busy;
    gStats.busyMax = std::max(gStats.busyMax, busy);
    if (now - gStats.windowStart >= 5.0)
    {
        // The app's footprint is what visionOS holds against its memory limit, and ends it at;
        // GPU memory is the Metal device's share of it.
        task_vm_info_data_t vm = {};
        mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
        const double footprint = task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&vm, &count) == KERN_SUCCESS
                                     ? vm.phys_footprint / 1048576.0 : 0.0;
        // The engine's GPU time and the CPU's waits for it; and, presenting, when the GPU got
        // each frame done against the compositor's deadline, which is what shows as judder.
        const double fenceWait = SharOpenXR::GetVulkanContext().TakeFenceWaits();
        const unsigned gpuFrames = gGpuFrames.exchange(0), gpuLate = gGpuLate.exchange(0);
        const int64_t margin = gGpuMargin.exchange(0), span = gGpuSpan.exchange(0);
        char presented[224] = "";
        if (gpuFrames)
            snprintf(presented, sizeof(presented), "; GPU %.1f ms a frame, done %.1f ms before the deadline avg, "
                     "%u of %u late", span / 1000.0 / gpuFrames, margin / 1000.0 / gpuFrames, gpuLate, gpuFrames);
        if (gPresentEvent)
        {
            const size_t used = strlen(presented);
            snprintf(presented + used, sizeof(presented) - used, "; waited %.1f ms a frame for presents",
                     gPresentWaits * 1000.0 / gStats.frames);
            gPresentWaits = 0;
        }
        NSLog(@"[SharVisionOS] %.1f fps; frame work %.1f ms avg, %.1f ms max; %u of %u past the deadline; "
              @"CPU waited %.1f ms a frame for the GPU%s; memory %.0f MB (GPU %.0f MB), %.0f MB to the limit",
              gStats.frames / (now - gStats.windowStart), gStats.busyTotal / gStats.frames * 1000.0,
              gStats.busyMax * 1000.0, gStats.late, gStats.frames, fenceWait / gStats.frames, presented, footprint,
              gQueue.device.currentAllocatedSize / 1048576.0, os_proc_available_memory() / 1048576.0);
        {
            std::lock_guard<std::mutex> lock(gWindowMutex);
            if (gWindowSlotReuses)
                NSLog(@"[SharVisionOS] window frames: %u written into a set the last frame was still writing",
                      gWindowSlotReuses);
            gWindowSlotReuses = 0;
        }
        gStats = FrameStats();
        gStats.windowStart = now;
    }
}

// The finished frame goes into a free one of the window's three sets, which becomes the latest
// once the GPU has written it.
void EndWindowFrame()
{
    EndMirrorFrame();
    @autoreleasepool
    {
        WindowFrameInput input = {};
        input.final = gRenderTexture;
        input.eyeOffset = gWindowEyeOffset;
        input.mirrorOnly = SharOpenXR::GetVulkanContext().IsWindowMirrorOnly();
        VkImage depth = VK_NULL_HANDLE;
        if (SharOpenXR::GetVulkanContext().TakeWindowSceneCapture(&depth, input.projection))
        {
            // Both eyes' depth, a slice each: each eye's as a 2D texture.
            id<MTLTexture> both = ExportTexture(depth);
            for (NSUInteger eye = 0; eye < 2 && both.arrayLength == 2; ++eye)
                input.depth[eye] = [both newTextureViewWithPixelFormat:both.pixelFormat textureType:MTLTextureType2D
                                                                levels:NSMakeRange(0, 1) slices:NSMakeRange(eye, 1)];
            input.scene = input.depth[0] && input.depth[1] ? gWindowScene : nil;
        }
        int slot = 0;
        {
            std::lock_guard<std::mutex> lock(gWindowMutex);
            while (slot == gWindowLatest || slot == gWindowReading) ++slot;
            // S23 probe: the set the last frame is still writing isn't excluded, so this frame can
            // write it too while the last frame's completion publishes it to the window.
            if (gWindowWriting[slot]) ++gWindowSlotReuses;
            gWindowWriting[slot] = true;
        }
        id<MTLCommandBuffer> commands = [gQueue commandBuffer];
        id<MTLTexture> colour = input.scene ? input.scene : input.final;
        // SMAA only for a frame the window copies: a mirror-only one takes just its HUD, from the
        // frame itself, and nothing reads what SMAA would make but its pixel format.
        if (gPresent.antiAliasing == 2 && !input.mirrorOnly) colour = EncodeAntiAliasing(commands, colour, 2);
        const bool encoded = EncodeWindowFrame(commands, input, colour, gWindowFrames[slot]);
        [commands addCompletedHandler:^(id<MTLCommandBuffer>) {
            std::lock_guard<std::mutex> lock(gWindowMutex);
            gWindowWriting[slot] = false;
            if (!encoded) return;
            gWindowLatest = slot;
            ++gWindowSerial;
        }];
        [commands commit];
        RecordFrameStats();
    }
    gRenderTexture = nil;
}

void EndCompositorFrame()
{
    if (gWindowFrame)
    {
        EndWindowFrame();
        return;
    }
    if (!gFrame || !gDrawable) return;
    // The command buffer, encoder and pass descriptor come back autoreleased, and the engine
    // thread has no pool of its own: under Metal API validation they'd pile up, one set a frame.
    @autoreleasepool
    {
        // The render context the present pass adds reads the device anchor, so it goes on first.
        cp_drawable_set_device_anchor(gDrawable, gFrameAnchor);
        id<MTLCommandBuffer> commands = [gQueue commandBuffer];
        const CFTimeInterval deadline = gStats.deadline;
        id<MTLCommandBuffer> marker = gFrameMarker;
        gFrameMarker = nil;
        const uint64_t frameValue = gFrameSignalled ? gEngineFrameValue : 0;
        if (frameValue) [commands encodeWaitForEvent:gPresentEvent value:frameValue];
        [commands addCompletedHandler:^(id<MTLCommandBuffer> done) {
            if (frameValue) gPresentedValue.store(frameValue);
            if (done.GPUEndTime <= 0) return;
            ++gGpuFrames;
            if (done.GPUEndTime > deadline) ++gGpuLate;
            gGpuMargin += (int64_t)std::llround((deadline - done.GPUEndTime) * 1e6);
            // The marker ran first on the same queue, so it's done and its times are final.
            if (marker.GPUStartTime > 0)
                gGpuSpan += (int64_t)std::llround((done.GPUEndTime - marker.GPUStartTime) * 1e6);
        }];
        PresentOptions present = gPresent;
        present.fade = gFrameFade;
        present.fadeToRoom = RoomBehindMenusActive();
        if (RoomBehindMenusActive())
        {
            const CFTimeInterval now = CACurrentMediaTime();
            if (gFrameWorldDrawn)
                gSeeThroughSince = 0;
            else
            {
                if (gSeeThroughSince == 0) gSeeThroughSince = gLastFrameWorldDrawn ? now : now - 1.0;
                const float t = std::min(std::max((float)(now - gSeeThroughSince - 0.25) / 0.5f, 0.0f), 1.0f);
                present.room = t * t * (3 - 2 * t);
            }
            present.backdrop = gMenuBackdrop;
            std::copy(&gMenuBackdropQuad[0][0], &gMenuBackdropQuad[0][0] + 8, &present.backdropQuad[0][0]);
            const float out = std::min(std::max((gHeadDistance - 1.2f) / 0.4f, 0.0f), 1.0f);
            present.visibility = 1 - out * out * (3 - 2 * out);
            if (gFrameWorldDrawn != gLastFrameWorldDrawn)
                NSLog(@"[SharVisionOS] room behind menus: %s", gFrameWorldDrawn ? "the game (opaque)" : "a menu frame (the room around it)");
        }
        gLastFrameWorldDrawn = gFrameWorldDrawn;
        EncodePresent(commands, gDrawable, gRenderTexture, present);
        cp_drawable_encode_present(gDrawable, commands);
        [commands commit];
        cp_frame_end_submission(gFrame);
        RecordFrameStats();
    }
    gFrame = NULL;
    gDrawable = NULL;
    gFrameAnchor = nil;
    gRenderTexture = nil;
    gAnchorTime = 0;
}

double CurrentAnchorTime()
{
    return gAnchorTime;
}

void SetRenderScale(float scale)
{
    gRenderScale = std::min(std::max(scale, 0.25f), 2.0f);
}

bool ConsumeWorldRecenter(bool* byCrown)
{
    const bool recentered = gWorldRecentered.exchange(false);
    const bool crown = recentered && gCrownRecentered.exchange(false);
    if (byCrown) *byCrown = recentered && crown;
    return recentered;
}

void DrainFrameAutoreleasePool()
{
    static void* pool = nullptr;
    if (pool) objc_autoreleasePoolPop(pool);
    pool = objc_autoreleasePoolPush();
}

void SetAntiAliasing(int mode)
{
    gPresent.antiAliasing = mode;
}

bool IsWindowPresentation()
{
    return gWindowFrame;
}

int CurrentView()
{
    return gNotifiedView;
}

void SetView(int mode)
{
    if (mode != gNotifiedView)
    {
        gNotifiedView = mode;
        NSLog(@"[SharVisionOS] view %d", mode);
        if (SharVisionOS_ViewHandler handler = gViewHandler.load()) handler(mode);
    }
}

// Simulator test runs only: SHAR_TEST_PRESSES="A@6 DOWN@9 RT@20~5" holds each button (or
// left-stick direction) that many seconds after the first gamepad read, for a quarter second or
// the given number of seconds, so the headless Simulator can drive the menus and the game.
void ApplyTestPresses(GamepadState* state)
{
    struct Press { std::string button; double at, hold; };
    static const std::vector<Press> presses = [] {
        std::vector<Press> parsed;
#if TARGET_OS_SIMULATOR
        if (const char* script = getenv("SHAR_TEST_PRESSES"))
        {
            std::istringstream words(script);
            for (std::string word; words >> word;)
            {
                const size_t at = word.find('@'), tilde = word.find('~');
                if (at != std::string::npos)
                    parsed.push_back({word.substr(0, at), atof(word.c_str() + at + 1),
                                      tilde != std::string::npos ? atof(word.c_str() + tilde + 1) : 0.25});
            }
        }
#endif
        return parsed;
    }();
    if (presses.empty()) return;
    static const CFTimeInterval start = CACurrentMediaTime();
    const double now = CACurrentMediaTime() - start;
    for (const Press& press : presses)
    {
        if (now < press.at || now > press.at + press.hold) continue;
        const std::string& b = press.button;
        if (b == "A") state->a = 1;
        else if (b == "B") state->b = 1;
        else if (b == "X") state->x = 1;
        else if (b == "Y") state->y = 1;
        else if (b == "MENU") state->menu = 1;
        else if (b == "LT") state->leftTrigger = 1;
        else if (b == "RT") state->rightTrigger = 1;
        else if (b == "LG") state->leftShoulder = 1;
        else if (b == "RG") state->rightShoulder = 1;
        else if (b == "UP") state->leftY = 1;
        else if (b == "DOWN") state->leftY = -1;
        else if (b == "LEFT") state->leftX = -1;
        else if (b == "RIGHT") state->leftX = 1;
    }
}

bool GamepadConnected()
{
    for (GCController* controller in GCController.controllers)
        if (![controller.productCategory isEqualToString:GCProductCategorySpatialController] && controller.extendedGamepad)
            return true;
    return false;
}

bool ReadGamepad(GamepadState* state)
{
    GCExtendedGamepad* pad = nil;
    for (GCController* controller in GCController.controllers)
    {
        // Sense controllers are read as a pair by ReadSpatialControllers.
        if ([controller.productCategory isEqualToString:GCProductCategorySpatialController]) continue;
        if ((pad = controller.extendedGamepad)) break;
    }
    if (!pad) return false;

    const auto value = [](GCControllerButtonInput* button) { return button ? button.value : 0.0f; };
    state->leftX = pad.leftThumbstick.xAxis.value;
    state->leftY = pad.leftThumbstick.yAxis.value;
    state->rightX = pad.rightThumbstick.xAxis.value;
    state->rightY = pad.rightThumbstick.yAxis.value;
    state->a = value(pad.buttonA);
    state->b = value(pad.buttonB);
    state->x = value(pad.buttonX);
    state->y = value(pad.buttonY);
    state->menu = value(pad.buttonMenu);
    state->leftTrigger = value(pad.leftTrigger);
    state->rightTrigger = value(pad.rightTrigger);
    state->leftShoulder = value(pad.leftShoulder);
    state->rightShoulder = value(pad.rightShoulder);
    state->leftStickClick = value(pad.leftThumbstickButton);
    state->rightStickClick = value(pad.rightThumbstickButton);

    static bool announced = false;
    if (!announced)
    {
        announced = true;
        NSLog(@"[SharVisionOS] gamepad connected: %@", pad.controller.vendorName);
    }
    ApplyTestPresses(state);
    return true;
}
}
