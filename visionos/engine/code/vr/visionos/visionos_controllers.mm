// PS VR2 Sense controllers on visionOS 26: the Touch controllers the shared VR layer was written
// for. GameController reports one GCController per hand (product category
// GCProductCategorySpatialController) for the buttons; ARKit accessory tracking gives each one's
// 6DoF grip pose, in the same world origin as the head.
//
// With neither a Sense controller nor a gamepad, bare hands stand in for them (ARKit hand
// tracking): pinches and a fist are the buttons, and two pinch clutches are the sticks.
#include <vr/visionos/visionos_compositor.h>
#include <vr/visionos/visionos_prompts.h>

#import <ARKit/ARKit.h>
#import <CoreHaptics/CoreHaptics.h>
#import <Foundation/Foundation.h>
#import <GameController/GameController.h>

#include <algorithm>
#include <mutex>
#include <string>

#import <QuartzCore/QuartzCore.h>

namespace
{
enum { kLeft = 0, kRight = 1 };

// Accessory loads complete on an ARKit queue, so what they produce is guarded. Everything else
// here runs on the engine thread.
std::mutex gMutex;
NSMutableArray* gAccessories = [NSMutableArray new];  // ar_accessory_t
bool gAccessoriesChanged = false;

NSMutableSet<GCController*>* gRequested = [NSMutableSet new];
ar_session_t gSession = nil;
ar_accessory_tracking_provider_t gProvider = nil;

bool IsSpatial(GCController* controller)
{
    return [controller.productCategory isEqualToString:GCProductCategorySpatialController];
}

int HandOfChirality(ar_accessory_chirality_t chirality)
{
    if (chirality == ar_accessory_chirality_left) return kLeft;
    if (chirality == ar_accessory_chirality_right) return kRight;
    return -1;
}

// Which hand a controller is for. Both Sense halves report the same element names ("Button A",
// "Grip", "Thumbstick"...), so it comes from the name ("... Sense Controller (L)"), or else from
// the loaded accessory's inherent chirality.
int HandOfController(GCController* controller)
{
    NSString* name = controller.vendorName;
    if ([name hasSuffix:@"(L)"]) return kLeft;
    if ([name hasSuffix:@"(R)"]) return kRight;
    {
        std::lock_guard<std::mutex> lock(gMutex);
        for (ar_accessory_t accessory in gAccessories)
            if (ar_accessory_get_source_device(accessory) == controller)
            {
                const int hand = HandOfChirality(ar_accessory_get_inherent_chirality(accessory));
                if (hand >= 0) return hand;
            }
    }
    return -1;
}

void LogController(GCController* controller)
{
    GCPhysicalInputProfile* profile = controller.physicalInputProfile;
    NSArray* buttons = [profile.buttons.allKeys sortedArrayUsingSelector:@selector(compare:)];
    NSArray* sticks = [profile.dpads.allKeys sortedArrayUsingSelector:@selector(compare:)];
    NSLog(@"[SharVisionOS] spatial controller connected: %@; buttons: %@; sticks: %@", controller.vendorName,
          [buttons componentsJoinedByString:@", "], [sticks componentsJoinedByString:@", "]);
}

void LogAccessory(ar_accessory_t accessory)
{
    NSMutableArray* locations = [NSMutableArray new];
    ar_strings_enumerate_strings(ar_accessory_copy_location_names(accessory), ^bool(const char* name) {
        [locations addObject:@(name)];
        return true;
    });
    const char* hands[] = {"unspecified", "left", "right"};
    const intptr_t chirality = ar_accessory_get_inherent_chirality(accessory);
    NSLog(@"[SharVisionOS] accessory loaded: %s, %s hand, locations: %@", ar_accessory_get_name(accessory),
          chirality >= 0 && chirality <= 2 ? hands[chirality] : "?", [locations componentsJoinedByString:@", "]);
}

// Asks ARKit for an accessory for each newly connected spatial controller, and drops the ones
// whose controller has gone.
void UpdateAccessories()
{
    NSArray<GCController*>* controllers = GCController.controllers;
    for (GCController* controller in [gRequested allObjects])
    {
        if ([controllers containsObject:controller]) continue;
        [gRequested removeObject:controller];
        std::lock_guard<std::mutex> lock(gMutex);
        NSIndexSet* gone = [gAccessories indexesOfObjectsPassingTest:^BOOL(id accessory, NSUInteger, BOOL*) {
            return ar_accessory_get_source_device(accessory) == controller;
        }];
        if (gone.count)
        {
            [gAccessories removeObjectsAtIndexes:gone];
            gAccessoriesChanged = true;
        }
        NSLog(@"[SharVisionOS] spatial controller disconnected: %@", controller.vendorName);
    }

    for (GCController* controller in controllers)
    {
        if (!IsSpatial(controller) || [gRequested containsObject:controller]) continue;
        [gRequested addObject:controller];
        LogController(controller);
        ar_accessory_load_from_device(controller, ^(id<GCDevice>, bool successful, ar_error_t error,
                                                    ar_accessory_t accessory) {
            if (!successful || !accessory)
            {
                CFErrorRef cfError = error ? ar_error_copy_cf_error(error) : NULL;
                NSLog(@"[SharVisionOS] loading the accessory for %@ failed: %@", controller.vendorName,
                      cfError ? (__bridge NSError*)cfError : @"no error");
                if (cfError) CFRelease(cfError);
                return;
            }
            LogAccessory(accessory);
            std::lock_guard<std::mutex> lock(gMutex);
            [gAccessories addObject:accessory];
            gAccessoriesChanged = true;
        });
    }
}

// An accessory tracking provider tracks a fixed set of accessories, so a new one replaces it
// whenever that set changes. It runs on its own session so head tracking is never interrupted.
void RestartTrackingIfNeeded()
{
    NSArray* accessories = nil;
    {
        std::lock_guard<std::mutex> lock(gMutex);
        if (!gAccessoriesChanged) return;
        gAccessoriesChanged = false;
        accessories = [gAccessories copy];
    }
    if (gSession) ar_session_stop(gSession);
    gSession = nil;
    gProvider = nil;
    if (accessories.count == 0) return;
    if (!ar_accessory_tracking_provider_is_supported())
    {
        NSLog(@"[SharVisionOS] accessory tracking isn't supported here");
        return;
    }

    ar_accessories_t tracked = ar_accessories_create();
    for (ar_accessory_t accessory in accessories) ar_accessories_add_accessory(tracked, accessory);
    ar_accessory_tracking_configuration_t configuration = ar_accessory_tracking_configuration_create();
    ar_accessory_tracking_configuration_set_accessories(configuration, tracked);
    gProvider = ar_accessory_tracking_provider_create(configuration);
    gSession = ar_session_create();
    ar_session_set_data_provider_state_change_handler(gSession, NULL, ^(ar_data_providers_t, ar_data_provider_state_t state,
                                                                      ar_error_t error, ar_data_provider_t) {
        CFErrorRef cfError = error ? ar_error_copy_cf_error(error) : NULL;
        NSLog(@"[SharVisionOS] controller tracking state %ld%@%@", (long)state, cfError ? @", error: " : @"",
              cfError ? [(__bridge NSError*)cfError description] : @"");
        if (cfError) CFRelease(cfError);
    });
    ar_session_run(gSession, ar_data_providers_create_with_data_providers(gProvider, nil));
    NSLog(@"[SharVisionOS] tracking %lu spatial controller(s)", (unsigned long)accessories.count);
}

XrPosef PoseFromTransform(simd_float4x4 transform)
{
    const simd_quatf rotation = simd_quaternion(transform);
    XrPosef pose;
    pose.orientation = {rotation.vector.x, rotation.vector.y, rotation.vector.z, rotation.vector.w};
    pose.position = {transform.columns[3].x, transform.columns[3].y, transform.columns[3].z};
    return pose;
}

// ---- Bare hands ------------------------------------------------------------------------------
// ARKit hand tracking on a session of its own (head tracking is never interrupted), sampled at the
// frame's predicted time: the latest anchors repeat between ARKit's ~30 Hz updates.
//
// As Touch controllers (the Sense layout):
//   index pinch   trigger            fist      grip
//   middle pinch  A (right) / X (left, a quick still tap)
//   ring pinch    B (right) / Y (left)
//   little pinch  menu (left) / turning (right)
// Walking: hold the left thumb and middle finger together and move the hand like a stick, in the
// horizontal plane with forward where the head faced as the pinch began; fully at 8 cm, and
// pushed all the way it sprints (the left stick's click). Turning: the right thumb and little
// finger, moved sideways. A pinch is one gesture (the strongest finger's), and pinching isn't a
// fist. The thresholds come from another Vision Pro port's hand input, proven on the headset.
ar_session_t gHandSession = nil;
ar_hand_tracking_provider_t gHandProvider = nil;
ar_hand_anchor_t gHandAnchors[2] = {nil, nil};

struct Hand
{
    bool tracked = false;
    simd_float3 wrist, thumbTip, indexTip, middleTip, ringTip, littleTip, indexKnuckle, middleKnuckle;
    bool wristTracked = false, knucklesTracked = false, middleTipTracked = false;
};
Hand gHands[2];
CFTimeInterval gHandsSampledFor = -1;

struct Clutch
{
    bool active = false;
    simd_float3 start = 0, forward = simd_make_float3(0, 0, -1), right = simd_make_float3(1, 0, 0);
    CFTimeInterval began = 0, tapUntil = 0;
    float maxTravel = 0;
    simd_float2 stick = 0;
};
Clutch gClutches[2];  // [0] walks (left middle), [1] turns (right little)

constexpr float kPinchFull = 0.015f, kPinchNone = 0.045f;      // thumb to fingertip, metres
constexpr float kCurlOpen = 0.17f, kCurlClosed = 0.08f;         // middle tip to wrist
constexpr float kClutchStart = 0.8f, kClutchEnd = 0.5f;
constexpr float kClutchRange = 0.08f, kClutchDeadzone = 0.012f, kClutchTapTravel = 0.02f;
constexpr double kClutchTapSeconds = 0.3, kClutchTapPressSeconds = 0.12;
constexpr float kClick = 0.75f;

float Clamp01(float v) { return std::min(std::max(v, 0.0f), 1.0f); }

float Pinch(simd_float3 thumb, simd_float3 finger)
{
    return Clamp01((kPinchNone - simd_distance(thumb, finger)) / (kPinchNone - kPinchFull));
}

void StartHandTracking()
{
    static bool tried = false;
    if (tried) return;
    tried = true;
    if (!ar_hand_tracking_provider_is_supported())
    {
        NSLog(@"[SharVisionOS] hand tracking isn't supported here");
        return;
    }
    gHandProvider = ar_hand_tracking_provider_create(ar_hand_tracking_configuration_create());
    gHandAnchors[kLeft] = ar_hand_anchor_create();
    gHandAnchors[kRight] = ar_hand_anchor_create();
    gHandSession = ar_session_create();
    ar_session_request_authorization(gHandSession, ar_authorization_type_hand_tracking,
                                     ^(ar_authorization_results_t results, ar_error_t error) {
        NSLog(@"[SharVisionOS] hand tracking authorization asked%s", error ? " (with an error)" : "");
    });
    ar_session_set_data_provider_state_change_handler(gHandSession, nil,
        ^(ar_data_providers_t, ar_data_provider_state_t state, ar_error_t error, ar_data_provider_t) {
        NSLog(@"[SharVisionOS] hand tracking state %ld%s", (long)state, error ? " (with an error)" : "");
    });
    ar_session_run(gHandSession, ar_data_providers_create_with_data_providers(gHandProvider, nil));
    NSLog(@"[SharVisionOS] hand tracking started");
}

simd_float3 JointPosition(ar_hand_skeleton_t skeleton, simd_float4x4 originFromAnchor,
                          ar_hand_skeleton_joint_name_t name, bool* tracked)
{
    ar_skeleton_joint_t joint = skeleton ? ar_hand_skeleton_get_joint_named(skeleton, name) : nullptr;
    if (!joint)
    {
        if (tracked) *tracked = false;
        return 0;
    }
    if (tracked) *tracked = ar_skeleton_joint_is_tracked(joint);
    return simd_mul(originFromAnchor, ar_skeleton_joint_get_anchor_from_joint_transform(joint)).columns[3].xyz;
}

// Both hands at the frame's time, once a frame.
void SampleHands()
{
    StartHandTracking();
    // Input is read before the frame's time is known: it takes the last frame's sample.
    const CFTimeInterval time = SharVisionOS::CurrentAnchorTime();
    if (time == gHandsSampledFor || (time <= 0 && gHandsSampledFor > 0)) return;
    gHandsSampledFor = time;
    gHands[kLeft] = gHands[kRight] = Hand();
    if (!gHandProvider || ar_data_provider_get_state(gHandProvider) != ar_data_provider_state_running) return;
    const bool predicted = time > 0 && ar_hand_tracking_provider_query_anchors_at_timestamp(
        gHandProvider, time, gHandAnchors[kLeft], gHandAnchors[kRight]) == ar_hand_anchor_query_status_success;
    if (!predicted && !ar_hand_tracking_provider_get_latest_anchors(gHandProvider, gHandAnchors[kLeft], gHandAnchors[kRight]))
        return;
    for (int hand = kLeft; hand <= kRight; ++hand)
    {
        ar_hand_anchor_t anchor = gHandAnchors[hand];
        if (!anchor || !ar_trackable_anchor_is_tracked(anchor)) continue;
        const simd_float4x4 origin = ar_anchor_get_origin_from_anchor_transform(anchor);
        ar_hand_skeleton_t skeleton = ar_hand_anchor_get_hand_skeleton(anchor);
        Hand& out = gHands[hand];
        out.tracked = true;
        bool index = false, middle = false;
        out.wrist = JointPosition(skeleton, origin, ar_hand_skeleton_joint_name_wrist, &out.wristTracked);
        out.thumbTip = JointPosition(skeleton, origin, ar_hand_skeleton_joint_name_thumb_tip, nullptr);
        out.indexTip = JointPosition(skeleton, origin, ar_hand_skeleton_joint_name_index_finger_tip, nullptr);
        out.middleTip = JointPosition(skeleton, origin, ar_hand_skeleton_joint_name_middle_finger_tip, &out.middleTipTracked);
        out.ringTip = JointPosition(skeleton, origin, ar_hand_skeleton_joint_name_ring_finger_tip, nullptr);
        out.littleTip = JointPosition(skeleton, origin, ar_hand_skeleton_joint_name_little_finger_tip, nullptr);
        out.indexKnuckle = JointPosition(skeleton, origin, ar_hand_skeleton_joint_name_index_finger_knuckle, &index);
        out.middleKnuckle = JointPosition(skeleton, origin, ar_hand_skeleton_joint_name_middle_finger_knuckle, &middle);
        out.knucklesTracked = index && middle;
    }
    static bool logged[2] = {false, false};
    for (int hand = kLeft; hand <= kRight; ++hand)
        if (gHands[hand].tracked && !logged[hand])
        {
            logged[hand] = true;
            NSLog(@"[SharVisionOS] %s hand tracked (bare hands play as a Touch controller)", hand == kLeft ? "left" : "right");
        }
}

struct Gestures
{
    float index = 0, middle = 0, ring = 0, little = 0, fist = 0;
};

Gestures GesturesOf(const Hand& hand)
{
    Gestures g;
    if (!hand.tracked) return g;
    g.index = Pinch(hand.thumbTip, hand.indexTip);
    g.middle = Pinch(hand.thumbTip, hand.middleTip);
    g.ring = Pinch(hand.thumbTip, hand.ringTip);
    g.little = Pinch(hand.thumbTip, hand.littleTip);
    if (hand.middleTipTracked && hand.wristTracked)
        g.fist = Clamp01((kCurlOpen - simd_distance(hand.middleTip, hand.wrist)) / (kCurlOpen - kCurlClosed));
    // One pinch at a time: the strongest finger's. And a pinch isn't a fist.
    const float best = std::max({g.index, g.middle, g.ring, g.little});
    if (best > 0)
    {
        if (g.index < best) g.index = 0;
        if (g.middle < best) g.middle = 0;
        if (g.ring < best) g.ring = 0;
        if (g.little < best) g.little = 0;
    }
    if (best > 0.3f) g.fist = 0;
    return g;
}

void UpdateClutch(int hand)
{
    Clutch& clutch = gClutches[hand];
    const Hand& h = gHands[hand];
    const bool walking = hand == kLeft;
    float pinch = 0;
    if (h.tracked)
    {
        pinch = Pinch(h.thumbTip, walking ? h.middleTip : h.littleTip);
        // Only this finger starts it (the index is the trigger); once held, a neighbour wobbling
        // closer doesn't end it.
        if (!clutch.active)
        {
            const float others = std::max({Pinch(h.thumbTip, h.indexTip), Pinch(h.thumbTip, h.ringTip),
                                           Pinch(h.thumbTip, walking ? h.littleTip : h.middleTip)});
            if (others > pinch) pinch = 0;
        }
    }
    const CFTimeInterval now = CACurrentMediaTime();
    if (!clutch.active)
    {
        if (pinch > kClutchStart)
        {
            const CFTimeInterval tapUntil = clutch.tapUntil;
            clutch = Clutch();
            clutch.active = true;
            clutch.start = h.thumbTip;
            clutch.began = now;
            clutch.tapUntil = tapUntil;
            simd_float4x4 head;
            if (SharVisionOS::CurrentHeadTransform(&head))
            {
                simd_float3 forward = -head.columns[2].xyz;
                forward.y = 0;
                if (simd_length(forward) > 1e-3f)
                {
                    clutch.forward = simd_normalize(forward);
                    clutch.right = simd_make_float3(-clutch.forward.z, 0, clutch.forward.x);
                }
            }
        }
        return;
    }
    if (pinch < kClutchEnd)
    {
        if (walking && now - clutch.began < kClutchTapSeconds && clutch.maxTravel < kClutchTapTravel)
            clutch.tapUntil = now + kClutchTapPressSeconds;
        clutch.active = false;
        clutch.stick = 0;
        return;
    }
    const simd_float3 moved = h.thumbTip - clutch.start;
    simd_float2 planar = simd_make_float2(simd_dot(moved, clutch.right), simd_dot(moved, clutch.forward));
    if (!walking) planar.y = 0;  // turning is sideways only
    const float travel = simd_length(planar);
    clutch.maxTravel = std::max(clutch.maxTravel, travel);
    clutch.stick = travel < kClutchDeadzone
        ? simd_make_float2(0, 0)
        : planar / travel * Clamp01((travel - kClutchDeadzone) / (kClutchRange - kClutchDeadzone));
}

// A hand's grip pose, as OpenXR defines it (the Touch grips the VR layer was tuned with): -Z where
// the index finger points (along its metacarpal), +X the palm's normal, into the palm of the
// right hand and away from the palm of the left (so to the right, both hands held upright), +Y
// towards the thumb; at the palm, between the wrist and the middle knuckle. From joint positions
// alone, so ARKit's own anchor axes never matter.
bool HandGrip(const Hand& hand, int index, simd_float4x4* originFromGrip)
{
    if (!hand.tracked || !hand.wristTracked || !hand.knucklesTracked) return false;
    simd_float3 forward = hand.indexKnuckle - hand.wrist;
    if (simd_length(forward) < 1e-4f) return false;
    forward = simd_normalize(forward);
    simd_float3 right = index == kRight ? hand.middleKnuckle - hand.indexKnuckle : hand.indexKnuckle - hand.middleKnuckle;
    if (simd_length(right) < 1e-4f) return false;
    right = simd_normalize(right);
    // A palm-down frame first (+Y out of the back of the hand), then rolled to OpenXR's grip.
    simd_float3 back = simd_cross(right, forward);
    if (simd_length(back) < 1e-4f) return false;
    back = simd_normalize(back);
    const simd_float3 z = -forward;
    const simd_float3 x = index == kRight ? back : -back;
    const simd_float3 y = simd_normalize(simd_cross(z, x));
    *originFromGrip = simd_matrix(simd_make_float4(x, 0), simd_make_float4(y, 0), simd_make_float4(z, 0),
                                  simd_make_float4((hand.wrist + hand.middleKnuckle) * 0.5f, 1));
    return true;
}

// Haptics: one engine per controller handle, created on first use. The rumble players loop a
// long continuous event whose intensity follows the game's rumble motors.
NSMutableDictionary<NSString*, CHHapticEngine*>* gHapticEngines = [NSMutableDictionary new];
id<CHHapticAdvancedPatternPlayer> gRumblePlayers[2] = {nil, nil};
CHHapticEngine* gRumbleEngines[2] = {nil, nil};
CFTimeInterval gLastPulse[2] = {0, 0};

// The controller and handle that vibrate for a hand: the Sense controller in that hand, else that
// side of a gamepad.
GCController* HapticController(int hand, GCHapticsLocality* locality)
{
    for (GCController* controller in GCController.controllers)
        if (IsSpatial(controller) && HandOfController(controller) == hand)
        {
            *locality = GCHapticsLocalityDefault;
            return controller;
        }
    for (GCController* controller in GCController.controllers)
        if (!IsSpatial(controller) && controller.extendedGamepad && controller.haptics)
        {
            *locality = hand == kLeft ? GCHapticsLocalityLeftHandle : GCHapticsLocalityRightHandle;
            if (![controller.haptics.supportedLocalities containsObject:*locality])
                *locality = GCHapticsLocalityDefault;
            return controller;
        }
    return nil;
}

CHHapticEngine* HapticEngine(int hand)
{
    GCHapticsLocality locality = GCHapticsLocalityDefault;
    GCController* controller = HapticController(hand, &locality);
    if (!controller.haptics) return nil;
    NSString* key = [NSString stringWithFormat:@"%p/%@", controller, locality];
    if (CHHapticEngine* engine = gHapticEngines[key]) return engine;

    CHHapticEngine* engine = [controller.haptics createEngineWithLocality:locality];
    if (!engine) return nil;
    engine.playsHapticsOnly = YES;
    __weak CHHapticEngine* weakEngine = engine;
    engine.resetHandler = ^{ [weakEngine startAndReturnError:nil]; };
    NSError* error = nil;
    if (![engine startAndReturnError:&error])
    {
        NSLog(@"[SharVisionOS] haptics unavailable on %@: %@", controller.vendorName, error);
        return nil;
    }
    NSLog(@"[SharVisionOS] haptics ready on %@ (%@)", controller.vendorName, locality);
    gHapticEngines[key] = engine;
    return engine;
}

CHHapticEvent* ContinuousEvent(float intensity, NSTimeInterval seconds)
{
    return [[CHHapticEvent alloc]
        initWithEventType:CHHapticEventTypeHapticContinuous
               parameters:@[[[CHHapticEventParameter alloc] initWithParameterID:CHHapticEventParameterIDHapticIntensity
                                                                          value:intensity],
                            [[CHHapticEventParameter alloc] initWithParameterID:CHHapticEventParameterIDHapticSharpness
                                                                          value:0.4f]]
             relativeTime:0
                 duration:seconds];
}

float Button(GCPhysicalInputProfile* profile, NSArray<NSString*>* names)
{
    for (NSString* name in names)
        if (GCControllerButtonInput* button = profile.buttons[name]) return button.value;
    return 0.0f;
}

GCControllerDirectionPad* Stick(GCPhysicalInputProfile* profile, NSArray<NSString*>* names)
{
    for (NSString* name in names)
        if (GCControllerDirectionPad* stick = profile.dpads[name]) return stick;
    return nil;
}
}

namespace SharVisionOS
{
bool ReadSpatialControllers(GamepadState* state)
{
    UpdateAccessories();
    RestartTrackingIfNeeded();

    GCController* hands[2] = {nil, nil};
    for (GCController* controller in GCController.controllers)
    {
        if (!IsSpatial(controller)) continue;
        const int hand = HandOfController(controller);
        if (hand >= 0 && !hands[hand]) hands[hand] = controller;
    }
    if (!hands[kLeft] && !hands[kRight]) return false;

    *state = {};
    // Sense to Touch: Square/Triangle are X/Y and Cross/Circle are A/B; L2/R2 are the triggers,
    // L1/R1 (under the middle finger) the grips, and Create/Options the menu button. Each half
    // names its elements generically ("Button A", "Trigger", "Grip", "Thumbstick"), so the left
    // half's A/B are its Square/Triangle; side-specific names are accepted too.
    if (GCPhysicalInputProfile* left = hands[kLeft].physicalInputProfile)
    {
        GCControllerDirectionPad* stick = Stick(left, @[GCInputLeftThumbstick, GCInputThumbstick]);
        state->leftX = stick.xAxis.value;
        state->leftY = stick.yAxis.value;
        state->x = Button(left, @[GCInputButtonX, GCInputButtonA]);
        state->y = Button(left, @[GCInputButtonY, GCInputButtonB]);
        state->leftTrigger = Button(left, @[GCInputLeftTrigger, GCInputTrigger]);
        state->leftShoulder = Button(left, @[@"Grip", GCInputLeftShoulder, GCInputLeftBumper]);
        state->leftStickClick = Button(left, @[GCInputLeftThumbstickButton, GCInputThumbstickButton]);
        state->menu = Button(left, @[GCInputButtonShare, GCInputButtonMenu, GCInputButtonOptions]);
    }
    if (GCPhysicalInputProfile* right = hands[kRight].physicalInputProfile)
    {
        GCControllerDirectionPad* stick = Stick(right, @[GCInputRightThumbstick, GCInputThumbstick]);
        state->rightX = stick.xAxis.value;
        state->rightY = stick.yAxis.value;
        state->a = Button(right, @[GCInputButtonA]);
        state->b = Button(right, @[GCInputButtonB]);
        state->rightTrigger = Button(right, @[GCInputRightTrigger, GCInputTrigger]);
        state->rightShoulder = Button(right, @[@"Grip", GCInputRightShoulder, GCInputRightBumper]);
        state->rightStickClick = Button(right, @[GCInputRightThumbstickButton, GCInputThumbstickButton]);
        state->menu = std::max(state->menu, Button(right, @[GCInputButtonOptions, GCInputButtonMenu]));
    }
    return true;
}

void PlayHaptic(int hand, float amplitude, double seconds)
{
    if (hand < kLeft || hand > kRight || amplitude <= 0 || seconds <= 0) return;
    // The VR layer can ask every frame (the steering wheel over bumps); a pulse is already playing.
    const CFTimeInterval now = CACurrentMediaTime();
    if (now - gLastPulse[hand] < 0.03) return;
    gLastPulse[hand] = now;

    CHHapticEngine* engine = HapticEngine(hand);
    if (!engine) return;
    NSError* error = nil;
    CHHapticPattern* pattern = [[CHHapticPattern alloc]
        initWithEvents:@[ContinuousEvent(std::min(amplitude, 1.0f), seconds)] parameters:@[] error:&error];
    id<CHHapticPatternPlayer> player = pattern ? [engine createPlayerWithPattern:pattern error:&error] : nil;
    [player startAtTime:CHHapticTimeImmediate error:&error];
}

void SetRumble(float left, float right)
{
    const float intensity[2] = {std::min(left, 1.0f), std::min(right, 1.0f)};
    for (int hand = kLeft; hand <= kRight; ++hand)
    {
        CHHapticEngine* engine = HapticEngine(hand);
        if (!engine) continue;
        if (gRumbleEngines[hand] != engine)
        {
            gRumbleEngines[hand] = engine;
            gRumblePlayers[hand] = nil;
            CHHapticPattern* pattern = [[CHHapticPattern alloc] initWithEvents:@[ContinuousEvent(1.0f, 30.0)]
                                                                    parameters:@[] error:nil];
            if (pattern) gRumblePlayers[hand] = [engine createAdvancedPlayerWithPattern:pattern error:nil];
            gRumblePlayers[hand].loopEnabled = YES;
        }
        id<CHHapticAdvancedPatternPlayer> player = gRumblePlayers[hand];
        if (intensity[hand] > 0)
        {
            CHHapticDynamicParameter* level = [[CHHapticDynamicParameter alloc]
                initWithParameterID:CHHapticDynamicParameterIDHapticIntensityControl value:intensity[hand] relativeTime:0];
            [player sendParameters:@[level] atTime:CHHapticTimeImmediate error:nil];
            [player startAtTime:CHHapticTimeImmediate error:nil];
        }
        else
            [player stopAtTime:CHHapticTimeImmediate error:nil];
    }
}

void LocateSpatialControllers(XrPosef poses[2], bool valid[2])
{
    valid[kLeft] = valid[kRight] = false;
    if (!gProvider || ar_data_provider_get_state(gProvider) != ar_data_provider_state_running) return;
    const CFTimeInterval time = CurrentAnchorTime();
    ar_accessory_tracking_provider_t provider = gProvider;
    ar_accessory_anchors_enumerate_anchors(ar_accessory_tracking_provider_get_latest_anchors(provider),
                                           ^bool(ar_accessory_anchor_t latest) {
        if (!ar_accessory_anchor_is_tracked(latest)) return true;
        // Predict each pose to when this frame is shown, as the head's is.
        ar_accessory_anchor_t anchor = latest;
        ar_accessory_anchor_t predicted = ar_accessory_anchor_create();
        if (time > 0 && ar_accessory_tracking_provider_predict_anchor_at_timestamp(provider, latest, time, predicted))
            anchor = predicted;

        int hand = HandOfChirality(ar_accessory_anchor_get_held_chirality(anchor));
        if (hand < 0) hand = HandOfChirality(ar_accessory_get_inherent_chirality(ar_accessory_anchor_get_accessory(anchor)));
        if (hand < 0 || valid[hand]) return true;
        const ar_accessory_anchor_tracking_state_t tracking = ar_accessory_anchor_get_tracking_state(anchor);
        if (tracking != ar_accessory_anchor_tracking_state_position_orientation_tracked &&
            tracking != ar_accessory_anchor_tracking_state_position_orientation_tracked_low_accuracy)
            return true;

        // ARKit's grip location is its counterpart of the OpenXR grip pose the shared layer uses.
        const simd_float4x4 originFromGrip = simd_mul(
            ar_accessory_anchor_get_origin_from_anchor_transform_with_correction(anchor, ar_transform_correction_rendered),
            ar_accessory_anchor_get_anchor_from_location_transform_with_correction(
                anchor, ar_accessory_location_name_grip, ar_transform_correction_rendered));
        poses[hand] = PoseFromTransform(originFromGrip);
        valid[hand] = true;
        return true;
    });

    static bool logged[2] = {false, false};
    for (int hand = kLeft; hand <= kRight; ++hand)
        if (valid[hand] && !logged[hand])
        {
            logged[hand] = true;
            NSLog(@"[SharVisionOS] %s controller tracked at %.2f %.2f %.2f, rotation %.2f %.2f %.2f %.2f",
                  hand == kLeft ? "left" : "right", poses[hand].position.x, poses[hand].position.y,
                  poses[hand].position.z, poses[hand].orientation.x, poses[hand].orientation.y,
                  poses[hand].orientation.z, poses[hand].orientation.w);
        }
}
}

namespace SharVisionOS
{
bool ReadBareHands(GamepadState* state)
{
    SampleHands();
    if (!gHands[kLeft].tracked && !gHands[kRight].tracked)
    {
        gClutches[kLeft] = gClutches[kRight] = Clutch();
        return false;
    }
    UpdateClutch(kLeft);
    UpdateClutch(kRight);
    Gestures left = GesturesOf(gHands[kLeft]), right = GesturesOf(gHands[kRight]);
    // A held clutch owns its hand: a loosened pinch with another fingertip near doesn't press it.
    if (gClutches[kLeft].active) left = Gestures();
    if (gClutches[kRight].active) right = Gestures();
    const CFTimeInterval now = CACurrentMediaTime();
    *state = {};
    state->leftX = gClutches[kLeft].stick.x;
    state->leftY = gClutches[kLeft].stick.y;
    state->leftStickClick = simd_length(gClutches[kLeft].stick) > 0.95f ? 1 : 0;
    state->rightX = gClutches[kRight].stick.x;
    state->leftTrigger = left.index;
    state->rightTrigger = right.index;
    state->leftShoulder = left.fist > kClick ? 1 : 0;
    state->rightShoulder = right.fist > kClick ? 1 : 0;
    // The left middle pinch is the walk clutch's: X only from a quick still tap.
    state->x = !gClutches[kLeft].active && now < gClutches[kLeft].tapUntil ? 1 : 0;
    state->y = left.ring > kClick ? 1 : 0;
    state->menu = left.little > kClick ? 1 : 0;
    state->a = right.middle > kClick ? 1 : 0;
    state->b = right.ring > kClick ? 1 : 0;
    return true;
}

void LocateBareHands(XrPosef poses[2], bool valid[2])
{
    SampleHands();
    for (int hand = kLeft; hand <= kRight; ++hand)
    {
        simd_float4x4 grip;
        if (!valid[hand] && HandGrip(gHands[hand], hand, &grip))
        {
            poses[hand] = PoseFromTransform(grip);
            valid[hand] = true;
        }
    }
}
}

namespace
{
// PlayStation controllers (Sense, DualSense, DualShock) label their face buttons with shapes; the
// rest use Xbox letters, which is also how the game names them.
bool PlayStationLabels()
{
    for (GCController* controller in GCController.controllers)
    {
        if (IsSpatial(controller)) return true;
        GCExtendedGamepad* pad = controller.extendedGamepad;
        if ([pad isKindOfClass:[GCDualSenseGamepad class]] || [pad isKindOfClass:[GCDualShockGamepad class]])
            return true;
    }
    return false;
}

// Expands {A} {B} {X} {Y} (face buttons) and {R} (right grip or shoulder) for the controller in use.
std::string ExpandButtons(const char* text)
{
    const bool playStation = PlayStationLabels();
    std::string out;
    for (const char* c = text; *c; ++c)
    {
        if (c[0] != '{' || !c[1] || c[2] != '}')
        {
            out += *c;
            continue;
        }
        switch (c[1])
        {
            case 'A': out += playStation ? "[CROSS]" : "[A]"; break;
            case 'B': out += playStation ? "[CIRCLE]" : "[B]"; break;
            case 'X': out += playStation ? "[SQUARE]" : "[X]"; break;
            case 'Y': out += playStation ? "[TRIANGLE]" : "[Y]"; break;
            case 'R': out += playStation ? "[R1]" : "[RB]"; break;
        }
        c += 2;
    }
    return out;
}
}

namespace SharVisionOS
{
// The layouts come from charactermappable.cpp and vehiclemappable.cpp. On foot, VR mode acts with
// A or Y, jumps with B, sprints on a left-stick click, and attacks with a swing of the tracked hand;
// Original mode jumps with A, sprints with B, attacks with X and acts with Y. Driving uses the right
// trigger (or A) for gas and the left trigger to brake or reverse; the handbrake is B in VR mode and
// the right grip in both. Line breaks follow the PC text: "\\" is a break and a blank line.
const char* ControllerTutorialText(int index, bool vrMode)
{
    const char* text = nullptr;
    switch (index)
    {
        case 0:
            text = vrMode ? "TO DESTROY WASP CAMERAS, JUMP\\\\INTO THE AIR WITH {B}\\\\AND SWING YOUR HAND\\\\TO HIT THE WASP"
                          : "TO DESTROY WASP CAMERAS, JUMP\\\\INTO THE AIR WITH {A}\\\\AND THEN PRESS {X}\\\\TO KICK THE WASP";
            break;
        case 2:
            text = vrMode ? "USE THE LEFT STICK TO MOVE AROUND\\\\PRESS {B} TO JUMP\\\\CLICK AND HOLD THE LEFT STICK TO RUN"
                          : "USE THE LEFT STICK TO MOVE AROUND\\\\PRESS {A} TO JUMP\\\\PRESS AND HOLD {B} TO RUN";
            break;
        case 3:
            text = vrMode ? "PULL THE RIGHT TRIGGER TO ACCELERATE\\\\USE THE LEFT STICK TO STEER\\\\PULL THE LEFT TRIGGER TO BRAKE\\\\PRESS {B} TO HANDBRAKE"
                          : "PULL THE RIGHT TRIGGER TO ACCELERATE\\\\USE THE LEFT STICK TO STEER\\\\PULL THE LEFT TRIGGER TO BRAKE\\\\PRESS {R} TO HANDBRAKE";
            break;
        case 4:
        case 10:
        case 18:
            text = vrMode ? "PRESS {A} TO GET INTO THE CAR" : "PRESS {Y} TO GET INTO THE CAR";
            break;
        case 9:
            text = vrMode ? "PRESS {A} TO USE THE TELEPHONE BOOTH" : "PRESS {Y} TO USE THE TELEPHONE BOOTH";
            break;
        case 11:
            text = vrMode ? "SWING YOUR HAND AT THE BOX\\\\TO KICK IT" : "PRESS {X} TO KICK THE BOX";
            break;
        case 13:
            text = vrMode ? "PRESS {A} TO GO INSIDE" : "PRESS {Y} TO GO INSIDE";
            break;
    }
    if (!text) return nullptr;
    static std::string expanded;
    expanded = ExpandButtons(text);
    return expanded.c_str();
}

const char* DisableTutorialsText()
{
    static std::string label;
    label = ExpandButtons("{X} Disable Tutorials");
    return label.c_str();
}
}
