// visionOS core for openxr_desktop_runtime.cpp (included in place of its OpenXR internals).
//
// The file's platform-neutral glue (the SharOpenXR facade below the internals) reads these
// Desktop:: names directly, so they keep the Win32 core's names and types; only the
// implementation behind them changes, to CompositorServices via visionos_compositor.h. OpenXR
// handles the glue checks before using OpenXR-only features (refresh rate, haptics) stay null.
#include <vr/visionos/visionos_compositor.h>
#include <gameflow/gameflow.h>
#include <presentation/gui/ingame/guimanageringame.h>
#include <presentation/gui/ingame/guiscreenhud.h>
#include <render/breakables/breakablesmanager.h>
#include <worldsim/avatar.h>
#include <worldsim/avatarmanager.h>
#include <worldsim/coins/coinmanager.h>
#include <SDL.h>
#include <TargetConditionals.h>
#include <cstdio>
#include <sstream>
#include <string>

namespace SharOpenXR { namespace Desktop { namespace {
XrResult XRAPI_CALL ApplyVisionOSHaptic(XrSession,const XrHapticActionInfo*,const XrHapticBaseHeader*);
std::vector<XrSwapchainImageVulkanKHR> images(1,{XR_TYPE_SWAPCHAIN_IMAGE_VULKAN_KHR});
uint32_t currentImage=0,currentEye=0;
int32_t eyeWidth=0,eyeHeight=0;
VkFormat swapchainFormat=VK_FORMAT_B8G8R8A8_SRGB;
XrFrameState currentFrame={XR_TYPE_FRAME_STATE};
XrView currentViews[2]={{XR_TYPE_VIEW},{XR_TYPE_VIEW}};
XrViewStateFlags currentViewFlags=0;
bool frameActive=false,imageAcquired=false,eyeActive=false,running=false;
bool worldRendering=false,embeddedHudRendering=false;
bool multiviewRendering=false,multiviewTargetActive=false;
rmt::Matrix multiviewProjection[2],multiviewAdjustment[2];
SharedVulkanRenderSequence renderSequence;
// ARKit's world origin is on the floor, like an OpenXR STAGE space.
bool originValid=false,usingStageSpace=true;
rmt::Matrix cullingBaseCamera;
bool cullingBaseValid=false;
XrPosef origin={{0.0f,0.0f,0.0f,1.0f},{0.0f,0.0f,0.0f}};
XrPosef handPoses[2]={{{0,0,0,1},{0,0,0}},{{0,0,0,1},{0,0,0}}};
bool handPoseValid[2]={false,false};
bool& menuHorizontalInputDominant=GetSharedVrState().menuHorizontalInputDominant;
bool& menuVerticalInputDominant=GetSharedVrState().menuVerticalInputDominant;
XrSession session=XR_NULL_HANDLE;
PFN_xrRequestDisplayRefreshRateFB requestDisplayRefreshRate=NULL;
// The glue's ApplyControllerHaptics drives an OpenXR haptic action once per hand path. These stand
// in for that action and those paths (placeholders naming the hands), and ApplyVisionOSHaptic plays
// the vibration on the controller in that hand.
XrAction hapticAction=reinterpret_cast<XrAction>(1);
PFN_xrApplyHapticFeedback applyHapticFeedback=ApplyVisionOSHaptic;
XrPath handPaths[2]={1,2};
bool initialized=false;
uint64_t frameSerial=0;

XrResult XRAPI_CALL ApplyVisionOSHaptic(XrSession,const XrHapticActionInfo* info,const XrHapticBaseHeader* haptic)
{
    const XrHapticVibration* vibration=reinterpret_cast<const XrHapticVibration*>(haptic);
    const int hand=info&&info->subactionPath==handPaths[1]?1:0;
    SharVisionOS::PlayHaptic(hand,vibration->amplitude,vibration->duration/1e9);
    return XR_SUCCESS;
}
VrConsoleAdapterState consoleAdapterState;
bool gamepadActive=false;
}

// Routes one console input (from the shared VR input layer) to the game's controller.
static void SetVisionOSConsoleInput(void* context,const char* name,float value)
{
    const auto setByName=[](void* target,const char* input,float v){
        UserController* controller=static_cast<UserController*>(target);
        const int index=controller->GetIdByName(input);
        if(index>=0)controller->SetVirtualInputValue(static_cast<unsigned>(index),v);};
    // No desktop aliases: visionOS builds the generic UserController (as Quest does), which knows
    // raw console buttons ("A", "Start", "LeftStickX"). The aliases are PCVR's Win32 controller
    // action names ("feSelect"), which this controller can't resolve, so presses were dropped.
    AdaptVrConsoleInput(name,value,false,menuHorizontalInputDominant,menuVerticalInputDominant,
                        &consoleAdapterState,setByName,context);
}

// PS VR2 Sense controllers stand in for the Touch controllers the shared layer expects; without
// them, a gamepad does (no hand poses). Gameplay meaning stays in SubmitVrInputFrame, as on Quest
// and PCVR.
static void SyncGamepadInput()
{
    InputManager* manager=InputManager::GetInstance();
    UserController* controller=manager?manager->GetController(0):NULL;
    if(!controller)return;
    SharVisionOS::GamepadState pad;
    // Sense controllers, else a gamepad, else bare hands (not while a gamepad's held: its hands
    // would pinch and swing).
    const bool fromController=SharVisionOS::ReadSpatialControllers(&pad) || SharVisionOS::ReadGamepad(&pad);
    const bool bareHands=!fromController && !SharVisionOS::IsWindowPresentation() && SharVisionOS::ReadBareHands(&pad);
    // The VR wheel: bare hands hold it by touching it (openxr_shared_vehicle.cpp).
    GetSharedVrState().bareHandsInput=bareHands;
    if(bareHands)
    {
        // The walking clutch pushed all the way is the stick's click, to run. In a car that click
        // is the horn, and steering hard is pushing all the way: every sharp turn honked.
        AvatarManager* avatars=AvatarManager::GetInstance();
        Avatar* avatar=avatars?avatars->GetAvatarForPlayer(0):NULL;
        if(avatar&&avatar->IsInCar())pad.leftStickClick=0;
    }
    if(!fromController&&!bareHands)
    {
        if(gamepadActive)
        {
            // Release everything once on disconnect so no button stays held.
            EmitNeutralVrController(SetVisionOSConsoleInput,controller);
            ResetVrInputSemantics();
            consoleAdapterState=VrConsoleAdapterState();
            controller->ClearVirtualInputs();
            // Controller 0 stays available (inputmanager.cpp): virtual input is its only source.
            gamepadActive=false;
        }
        return;
    }
    gamepadActive=true;
    controller->SetVirtualInputAvailable(true);
    const VrInputFrame raw={{pad.leftX,pad.leftY},{pad.rightX,pad.rightY},
                            pad.a,pad.b,pad.x,pad.y,pad.menu,
                            pad.leftTrigger,pad.rightTrigger,pad.leftShoulder,pad.rightShoulder,
                            pad.leftStickClick,pad.rightStickClick};
    SubmitVrInputFrame(raw,SetVisionOSConsoleInput,controller);
}

// Simulator test runs only: SHAR_TEST_EVENTS="break:19@60 coins:5@62 scale:50@64" plays breakable 19 (Krusty
// glass) by the player 60 s after the first frame, drops 5 coins at 62 s and sets Render Scale to
// 50% at 64 s, so the headless Simulator can reach what otherwise needs driving into something
// (constants/breakablesenum.h) or a menu. aa:<mode> and view:<mode> set Anti-Aliasing and View;
// turn:<degrees> turns the first-person view (positive to the right) as the runtime's turns do;
// iris:1 and iris:0 close and open the game's iris-wipe fade.
static void RunTestEvents()
{
    struct Event{std::string kind;int value;double at;bool done;};
    static std::vector<Event> events=[]{
        std::vector<Event> parsed;
#if TARGET_OS_SIMULATOR
        if(const char* script=getenv("SHAR_TEST_EVENTS"))
        {
            std::istringstream words(script);
            for(std::string word;words>>word;)
            {
                const size_t colon=word.find(':'),at=word.find('@');
                if(colon==std::string::npos||at==std::string::npos||at<colon)continue;
                parsed.push_back({word.substr(0,colon),atoi(word.c_str()+colon+1),atof(word.c_str()+at+1),false});
            }
        }
#endif
        return parsed;
    }();
    if(events.empty())return;
    static const Uint64 start=SDL_GetTicks();
    const double now=(SDL_GetTicks()-start)/1000.0;
    for(Event& event:events)
    {
        if(event.done||now<event.at)continue;
        event.done=true;
        if(event.kind=="scale")
        {
            // Same path as the Graphics menu's Render Scale: ApplyPendingSharedRenderScale picks it up.
            SetSharedRenderScale(event.value/100.0f,NULL,NULL);
            SDL_Log("visionOS test: render scale %d%%",event.value);
            continue;
        }
        if(event.kind=="iris")
        {
            SharOpenXR::SetIrisBlackout(event.value!=0);
            SDL_Log("visionOS test: iris %s",event.value?"closed":"open");
            continue;
        }
        if(event.kind=="turn")
        {
            SharOpenXR::AddVrYaw(event.value*0.017453293f);
            SDL_Log("visionOS test: turn %d degrees",event.value);
            continue;
        }
        if(event.kind=="aa"||event.kind=="view")
        {
            // The Graphics menu's Anti-Aliasing, or the VR menu's View.
            if(event.kind=="aa")SetSharedAntiAliasing(event.value);else SetSharedViewMode(event.value);
            SDL_Log("visionOS test: %s %d",event.kind.c_str(),event.value);
            continue;
        }
        AvatarManager* avatars=AvatarManager::GetInstance();
        Avatar* avatar=avatars?avatars->GetAvatarForPlayer(0):NULL;
        if(!avatar){SDL_Log("visionOS test: %s:%d skipped, no player",event.kind.c_str(),event.value);continue;}
        rmt::Vector position;
        avatar->GetPosition(position);
        position.x+=1.5f;
        if(event.kind=="break")
        {
            const BreakablesEnum::BreakableID id=static_cast<BreakablesEnum::BreakableID>(event.value);
            BreakablesManager* breakables=GetBreakablesManager();
            if(!breakables||!breakables->IsLoaded(id))
            {
                SDL_Log("visionOS test: breakable %d isn't loaded here",event.value);
                continue;
            }
            rmt::Matrix transform;
            transform.Identity();
            transform.FillTranslate(position);
            breakables->Play(id,transform);
        }
        else if(event.kind=="coins")GetCoinManager()->SpawnCoins(event.value,position);
        SDL_Log("visionOS test: %s:%d at %.1f %.1f %.1f",event.kind.c_str(),event.value,
                position.x,position.y,position.z);
    }
}

static std::string PreferenceFile(const char* name)
{
    char* base=SDL_GetPrefPath("c4rlox","simpsons");
    if(!base)return std::string();
    std::string path(base);
    SDL_free(base);
    return path+name;
}

// Beside the game's settings: there while the window has switched VR mode off. The settings save
// Original mode with the rest, so after quitting in the window, Full and Progressive started in it
// next time (no bare hands, no Sense layout); this is how the next launch knows to switch back.
static std::string WindowOriginalModeMarker()
{
    return PreferenceFile("visionos-window-original-mode");
}

// Builds from before the marker left Original mode saved after any Window session, with nothing to
// say the window chose it. Once, on the first launch of a build with the marker, VR mode comes back
// (a mode chosen in the VR menu from then on is kept).
static bool TakeOriginalModeMigration()
{
    const std::string done=PreferenceFile("visionos-vr-mode-restored");
    if(FILE* marker=std::fopen(done.c_str(),"r")){std::fclose(marker);return false;}
    if(FILE* marker=std::fopen(done.c_str(),"w"))std::fclose(marker);
    return true;
}

// The VR menu's View: full immersion, progressive, or the game's window in the shared space. The
// window has no head or controller tracking (visionOS keeps those to Full Spaces), so it plays in
// Original mode, third person; VR mode comes back when the game returns to the immersive space.
static void UpdateView()
{
    SharedVrState& s=GetSharedVrState();
    static bool restoreVrMode=false,markerRead=false;
    if(!markerRead)
    {
        markerRead=true;
        if(FILE* marker=std::fopen(WindowOriginalModeMarker().c_str(),"r"))
        {
            std::fclose(marker);
            restoreVrMode=true;
        }
        if(TakeOriginalModeMigration()&&!s.vrModeEnabled)
        {
            // Kept in the window's marker until it's done: a first launch into the window, quit there,
            // would otherwise use it up without restoring anything.
            if(FILE* marker=std::fopen(WindowOriginalModeMarker().c_str(),"w"))std::fclose(marker);
            SDL_Log("visionOS: VR mode to be restored once (an older build saved the window's Original mode)");
            restoreVrMode=true;
        }
    }
    s.flatWindowActive=SharVisionOS::IsWindowPresentation();
    s.flatWindowTangent=SharVisionOS::WindowHalfHeightTangent();
    if(s.flatWindowActive&&s.vrModeEnabled)
    {
        if(FILE* marker=std::fopen(WindowOriginalModeMarker().c_str(),"w"))std::fclose(marker);
        SetSharedVrModeEnabled(false);
        restoreVrMode=true;
    }
    else if(!s.flatWindowActive&&restoreVrMode)
    {
        SetSharedVrModeEnabled(true);
        std::remove(WindowOriginalModeMarker().c_str());
        restoreVrMode=false;
    }
    SharVisionOS::SetView(s.viewMode);
}

void ShutdownRuntime();
void EndFrame();

static bool FillSharedHudRuntime(SharedHudRuntime* runtime)
{
    if(!runtime)return false;
    runtime->activeEye=eyeActive?currentEye+1:0;
    runtime->multiviewImageAcquired=imageAcquired;
    runtime->embeddedHudRendering=embeddedHudRendering;
    runtime->cullingBaseValid=cullingBaseValid;
    runtime->vrModeEnabled=GetSharedVrState().vrModeEnabled;
    runtime->origin=origin;
    runtime->cullingBaseCamera=cullingBaseCamera;
    runtime->activeWheelCentre=GetSharedVrState().activeWheelCentre;
    for(unsigned eye=0;eye<2;++eye)
    {
        runtime->views[eye]=currentViews[eye];
        runtime->eyeWidth[eye]=eyeWidth;
        runtime->eyeHeight[eye]=eyeHeight;
        runtime->handPoses[eye]=handPoses[eye];
        runtime->handPoseValid[eye]=handPoseValid[eye];
    }
    runtime->renderImage=images[0].image;
    runtime->renderFormat=swapchainFormat;
    return true;
}

bool InitializeRuntime()
{
    SetSharedHudRuntimeProvider(FillSharedHudRuntime);
    if(initialized)return true;
    LoadVrSettings();
    GetSharedVrMenu().Reset();
    GetSharedMoviePanel().End();
    if(!SharVisionOS::InitializeCompositor())return false;
    if(!GetVulkanContext().Initialize(XR_NULL_HANDLE,XR_NULL_SYSTEM_ID,NULL))
    {
        SDL_LogError(SDL_LOG_CATEGORY_APPLICATION,"visionOS: Vulkan initialization failed");
        ShutdownRuntime();
        return false;
    }
    // The drawable size is fixed by the compositor; the engine renders at a fraction of it instead.
    SharVisionOS::SetRenderScale(GetSharedVrState().renderScale);
    GetSharedVrState().appliedRenderScale=GetSharedVrState().renderScale;
    GetSharedVrState().renderScalePending=false;
    initialized=running=true;
    SDL_Log("visionOS: runtime ready (multiview %d)",GetVulkanContext().IsMultiviewSupported()?1:0);
    return true;
}

void ShutdownRuntime()
{
    GetSharedVrMenu().Reset();
    running=false;
    ShutdownSharedHud();
    SharVisionOS::ShutdownCompositor();
    GetVulkanContext().Shutdown();
    initialized=false;
}

bool IsRuntimeReady()
{
    return initialized&&SharVisionOS::IsCompositorRunning();
}

// Back from being held (the headset off, the game's space or window closed or in the background),
// play comes back on the pause menu rather than straight into traffic, as a console's does when
// its controller reconnects. Only from the running HUD, where Start pauses: paused mid iris wipe
// (going in or out of a building) or mid conversation, resuming returned to that screen with the
// game still paused, and the wipe never finished.
static void PauseAfterHold()
{
    if(GetGameFlow()->GetCurrentContext()!=CONTEXT_GAMEPLAY||GetGameFlow()->GetNextContext()!=CONTEXT_GAMEPLAY)return;
    CGuiSystem* gui=GetGuiSystem();
    CGuiManagerInGame* inGame=gui?gui->GetInGameManager():NULL;
    if(!inGame||inGame->GetCurrentScreen()!=CGuiWindow::GUI_SCREEN_ID_HUD)return;
    CGuiScreenHud* hud=GetCurrentHud();
    if(!hud||!hud->IsActive())return;
    inGame->HandleMessage(GUI_MSG_PAUSE_INGAME);
}

bool BeginFrame()
{
    SharVisionOS::DrainFrameAutoreleasePool();
    SharedHudBeginFrame();
    cullingBaseValid=false;
    if(!IsRuntimeReady())return false;
    if(SharVisionOS::ConsumeResumeFromHold())PauseAfterHold();

    // Free what the engine retired last frame (the previous EndFrame drained the queue).
    GetVulkanContext().ReleaseRetiredResources();
    SyncGamepadInput();
    RunTestEvents();
    // A new Render Scale from the Graphics menu applies from the next compositor frame.
    ApplyPendingSharedRenderScale([](void*,float scale){SharVisionOS::SetRenderScale(scale);return true;},NULL);
    SharVisionOS::SetAntiAliasing(GetSharedVrState().antiAliasing);

    bool tracked=false;
    uint32_t width=0,height=0;
    if(!SharVisionOS::BeginCompositorFrame(currentViews,&tracked,&width,&height))return false;
    frameActive=true;
    ++frameSerial;
    eyeWidth=static_cast<int32_t>(width);
    eyeHeight=static_cast<int32_t>(height);
    currentFrame.shouldRender=XR_TRUE;
    currentViewFlags=tracked?(XR_VIEW_STATE_ORIENTATION_VALID_BIT|XR_VIEW_STATE_POSITION_VALID_BIT|
                              XR_VIEW_STATE_ORIENTATION_TRACKED_BIT|XR_VIEW_STATE_POSITION_TRACKED_BIT):0;
    if(!SharedRender::HasValidViewTracking(currentViewFlags))
    {
        // No head pose yet (ARKit still starting): present nothing rather than a stale pose.
        currentFrame.shouldRender=XR_FALSE;
        EndFrame();
        return false;
    }
    // The game's front is the space's forward (ARKit's -Z), which is where visionOS puts the
    // progressive portal, and moves to the player's facing on a Digital Crown recenter. Anchoring
    // it to the head's heading instead left the portal showing the side of the scene.
    // Which way the head faces from the space's forward (radians, positive to the right).
    const XrQuaternionf facing=SharedRender::CentreYawAnchor(currentViews[0].pose,currentViews[1].pose).orientation;
    const float headYaw=std::atan2(-2.0f*(facing.x*facing.z+facing.w*facing.y),
                                   1.0f-2.0f*(facing.x*facing.x+facing.y*facing.y));
    static float lastHeadYaw=0.0f;
    static int lastView=-2;
    const int view=SharVisionOS::CurrentView();
    const auto wrap=[](float a){ while(a>3.14159265f)a-=6.2831853f; while(a<-3.14159265f)a+=6.2831853f; return a; };
    // The progressive portal stays on the space's forward axis, and the game shows its own forward
    // there: what the player was looking at, turned to in Full (head or stick), stayed off to the
    // side. So the game turns to keep what the player looks at:
    // - entering Progressive, by how far the head faces from the space's forward, so the view
    //   ahead of the head is in the portal;
    // - on a Digital Crown recenter in Progressive, which moves the space's forward (and the portal)
    //   to where the head faced, by how far the head faced from the old forward, so the view stays.
    //   In Full a recenter brings the game's front (a car's windscreen) to the player, as before.
    bool byCrown=false;
    if(SharVisionOS::ConsumeWorldRecenter(&byCrown))
    {
        originValid=false;
        if(byCrown && view==1 && !SharVisionOS::IsWindowPresentation())
        {
            const float turn=wrap(lastHeadYaw-headYaw);
            SharOpenXR::AddVrYaw(turn);
            SDL_Log("visionOS: recentred; the game turns %.0f degrees to keep the view",turn*57.29578f);
        }
    }
    if(view!=lastView)
    {
        // From Full only: coming from the window, what the player was looking at is the game's
        // forward already (the window's view), which the portal shows.
        if(view==1 && lastView==0)
        {
            SharOpenXR::AddVrYaw(wrap(headYaw));
            SDL_Log("visionOS: into Progressive; the game turns %.0f degrees to keep the view in the portal",
                    headYaw*57.29578f);
        }
        lastView=view;
    }
    lastHeadYaw=headYaw;
    if(!originValid)
    {
        origin=SharedRender::CentreYawAnchor(currentViews[0].pose,currentViews[1].pose);
        origin.orientation=XrQuaternionf{0.0f,0.0f,0.0f,1.0f};
        originValid=true;
        GetSharedVrMenu().InvalidateAnchor();
        SDL_Log("visionOS: tracking origin captured at %.3f %.3f %.3f",
                origin.position.x,origin.position.y,origin.position.z);
    }
    UpdateView();
    SharVisionOS::LocateSpatialControllers(handPoses,handPoseValid);
    // Bare hands' poses for hands without a Sense controller, unless a gamepad is in use (and not
    // in the window: no hand tracking in the shared space, and no permission prompt there).
    if(!SharVisionOS::GamepadConnected() && !SharVisionOS::IsWindowPresentation())
        SharVisionOS::LocateBareHands(handPoses,handPoseValid);
    const auto haptic=[](void*,unsigned hand,float amplitude,unsigned durationMs)
    { SharVisionOS::PlayHaptic(static_cast<int>(hand),amplitude,durationMs/1000.0); };
    UpdateTrackedVrVehicle(originValid,origin,handPoses,handPoseValid,haptic,NULL);

    images[0].image=SharVisionOS::GetCompositorColorImage();
    swapchainFormat=SharVisionOS::GetCompositorColorFormat();
    currentImage=0;
    imageAcquired=images[0].image!=VK_NULL_HANDLE;
    if(!imageAcquired)
    {
        EndFrame();
        return false;
    }
    if((frameSerial%300u)==1u)
        SDL_Log("visionOS frame: serial=%llu %dx%d",static_cast<unsigned long long>(frameSerial),
                eyeWidth,eyeHeight);
    return true;
}

bool BeginEye(unsigned eye)
{
    if(!frameActive||!imageAcquired||eye>1)return false;
    currentEye=eye;
    if(!GetVulkanContext().BeginPddiEye())return false;
    // Drawables are recycled by the compositor, so nothing about a layer's previous contents or
    // layout is ours: start every eye from UNDEFINED, as PCVR does after a swapchain acquire.
    eyeActive=GetVulkanContext().ClearImageInPddiEye(images[0].image,true,eye,eyeWidth,eyeHeight);
    if(!eyeActive)GetVulkanContext().EndPddiEye();
    return eyeActive;
}

static void PresentSharedHud(void*,unsigned eye)
{
    currentEye=eye;
    if(cullingBaseValid)DrawSharedGameplayHud();
}

void EndEye(unsigned)
{
    if(eyeActive)
    {
        if(cullingBaseValid)DrawSharedGameplayHud();
        GetVulkanContext().EndPddiEye();
    }
    eyeActive=false;
}

// The frontend panel's corners in each eye's image, for the backdrop the room behind menus puts
// under it. Its canvas is the frontend camera's view (90 degrees across, 4:3), which the panel
// transform (SharedVrMenu::GetProjection) takes into the eye: the corners are the canvas's.
static void PublishMenuBackdrop()
{
    float quads[2][8]={};
    bool shown=GetSharedVrMenu().IsActive();
    const float canvas[4][2]={{-1.0f,0.75f},{1.0f,0.75f},{1.0f,-0.75f},{-1.0f,-0.75f}};
    for(unsigned eye=0;shown&&eye<2;++eye)
    {
        rmt::Matrix p;
        int width=0,height=0;
        if(!GetSharedVrMenu().GetProjection(true,currentViews[eye],eyeWidth,eyeHeight,&p,&width,&height,false))
        {
            shown=false;
            break;
        }
        for(int k=0;k<4&&shown;++k)
        {
            float clip[4];
            for(int j=0;j<4;++j)
                clip[j]=canvas[k][0]*p.m[0][j]+canvas[k][1]*p.m[1][j]+p.m[2][j]+p.m[3][j];
            if(clip[3]<=0.0001f){shown=false;break;}
            quads[eye][k*2]=0.5f+0.5f*clip[0]/clip[3];
            quads[eye][k*2+1]=0.5f-0.5f*clip[1]/clip[3];
        }
    }
    SharVisionOS::SetMenuBackdrop(shown,quads);
}

void EndFrame()
{
    if(!frameActive)return;
    if(eyeActive)EndEye(currentEye);
    SharVisionOS::SetFrameWorldDrawn(cullingBaseValid);
    // The game's iris wipes: Quest and PC fade the composition layer by this; so does the present.
    SharVisionOS::SetFrameFade(UpdateSharedHudIrisAlpha());
    PublishMenuBackdrop();
    if(imageAcquired)
    {
        // The compositor's present pass reads what the engine drew. On MoltenVK's own queue it
        // follows the engine's command buffers anyway; on another queue everything the engine
        // submitted must have completed first.
        if(!SharVisionOS::SharesEngineQueue() && !SharVisionOS::SignalEngineFrame())
        {
            const VkResult result=vkQueueWaitIdle(GetVulkanContext().GetQueue());
            if(result!=VK_SUCCESS)
                SDL_LogError(SDL_LOG_CATEGORY_APPLICATION,"visionOS: vkQueueWaitIdle failed (%d)",
                             static_cast<int>(result));
        }
        imageAcquired=false;
    }
    SharVisionOS::EndCompositorFrame();
    frameActive=false;
}
} }
