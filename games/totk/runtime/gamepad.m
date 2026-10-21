/* Native macOS controllers feed the same FullKey state as the keyboard. */
#import <Foundation/Foundation.h>
#import <GameController/GameController.h>
#include <TargetConditionals.h>
#if TARGET_OS_OSX
#import <IOKit/hid/IOHIDManager.h>
#endif
#include <math.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include "runtime.h"
#include "gamepad_layout.h"   // face buttons by position (PlayStation, Xbox) or label (Nintendo)
#include "controller_map.h"   // the player's button layout (controls.txt)

static pthread_mutex_t gamepadLock = PTHREAD_MUTEX_INITIALIZER;
static RuntimeGamepadState gamepadState;
static uint64_t pressedEdges;
static BOOL started;
static uint16_t controllerMap[CONTROLLER_BUTTONS];
static uint8_t controllerModes[CONTROLLER_BUTTONS];
static uint64_t physicalPrev;
static uint64_t tapUntil[CONTROLLER_BUTTONS];   /* ns, for tap */
static int toggleOn[CONTROLLER_BUTTONS];        /* for toggle */
static int toggleMoved[CONTROLLER_BUTTONS];     /* the stick moved since the toggle went on */
static void refresh_gamepads(void);

/* The player's button layout (controller_map.h): TOTK_CONTROLS names the file (the launcher: <data>/controls.txt and
   checks it first). No file: the default layout. */
static void load_controller_map(void) {
    controller_map_default(controllerMap, controllerModes);
    const char *path = getenv("TOTK_CONTROLS");
    FILE *f = path && *path ? fopen(path, "rb") : NULL;
    if (!f) { fprintf(stderr, "[totk-input] controller layout: default\n"); return; }
    char text[16384]; size_t n = fread(text, 1, sizeof text - 1, f); int whole = feof(f); fclose(f);
    if (!whole) runtime_fail("controller layout file too large");
    text[n] = 0;
    const char *error = NULL; int line = controller_map_parse(text, controllerMap, controllerModes, &error);
    if (line) { fprintf(stderr, "[totk-input] %s line %d: %s\n", path, line, error); runtime_fail("controller layout file"); }
    uint16_t defaults[CONTROLLER_BUTTONS]; uint8_t defaultModes[CONTROLLER_BUTTONS]; controller_map_default(defaults, defaultModes);
    int changed = 0; for (int i = 0; i < CONTROLLER_BUTTONS; i++) changed += controllerMap[i] != defaults[i];
    fprintf(stderr, "[totk-input] controller layout: %s (%d buttons changed)\n", path, changed);
}

static int32_t stick_axis(float value) {
    const float deadzone = 0.12f;
    float magnitude = fabsf(value);
    if (magnitude <= deadzone) return 0;
    if (magnitude > 1.0f) magnitude = 1.0f;
    int32_t result = (int32_t)((magnitude - deadzone) / (1.0f - deadzone) * 32767.0f);
    return value < 0 ? -result : result;
}

static int32_t stronger_axis(int32_t a, int32_t b) {
    return abs(b) > abs(a) ? b : a;
}

static int face_by_position(GCController *controller) {
    return gamepad_face_by_position(controller.productCategory.UTF8String, controller.vendorName.UTF8String);
}

/* The physical buttons held, bit i = controller_physical_names[i]; the face buttons by where they sit
   (gamepad_face_positions), so one layout file means the same buttons on every controller. */
static uint64_t gamepad_buttons(GCExtendedGamepad *pad, int by_position) {
    uint64_t buttons = gamepad_face_positions(pad.buttonA.isPressed, pad.buttonB.isPressed, pad.buttonX.isPressed, pad.buttonY.isPressed, by_position);
    if (pad.leftThumbstickButton.isPressed) buttons |= 1ULL << 4;
    if (pad.rightThumbstickButton.isPressed) buttons |= 1ULL << 5;
    if (pad.leftShoulder.isPressed) buttons |= 1ULL << 6;
    if (pad.rightShoulder.isPressed) buttons |= 1ULL << 7;
    if (pad.leftTrigger.isPressed) buttons |= 1ULL << 8;
    if (pad.rightTrigger.isPressed) buttons |= 1ULL << 9;
    if (pad.buttonMenu.isPressed) buttons |= 1ULL << 10;
    if (pad.buttonOptions.isPressed) buttons |= 1ULL << 11;
    if (pad.dpad.left.isPressed) buttons |= 1ULL << 12;
    if (pad.dpad.up.isPressed) buttons |= 1ULL << 13;
    if (pad.dpad.right.isPressed) buttons |= 1ULL << 14;
    if (pad.dpad.down.isPressed) buttons |= 1ULL << 15;
    if ([pad isKindOfClass:GCDualSenseGamepad.class] && ((GCDualSenseGamepad *)pad).touchpadButton.isPressed) buttons |= 1ULL << 16;
    if ([pad isKindOfClass:GCDualShockGamepad.class] && ((GCDualShockGamepad *)pad).touchpadButton.isPressed) buttons |= 1ULL << 16;
    return buttons;
}

#if TARGET_OS_OSX
/* Raw HID gamepads that GameController does not take (TOTK_HID_GAMEPADS=0 turns this off). An 8BitDo Ultimate 2C Wireless
   over Bluetooth LE (2dc8:301b) is a plain HID gamepad that GCController never lists, so it would be ignored. Only
   controllers with a known report layout are read: a wrong layout would press the wrong buttons. 8BitDo's DirectInput
   layout (measured on the Ultimate 2C): buttons 1 A, 2 B, 4 X, 5 Y (Xbox positions: A bottom, B right, X left, Y top),
   7 LB, 8 RB, 9 LT, 10 RT, 11 Select, 12 Start, 13 Home, 14 L3, 15 R3; hat 0 = up, clockwise, 8+ = centred; sticks X/Y and
   Z/Rz, 0..255, down positive. Read on the main queue, like GameController's handlers. */
enum { HID_PADS = 4, HID_BUTTONS = 16 };
static struct hid_pad {
    IOHIDDeviceRef device;
    char name[128];
    uint8_t button[HID_BUTTONS + 1];
    int hat;
    float lx, ly, rx, ry;   // -1..1, up positive
} hidPads[HID_PADS];
static IOHIDManagerRef hidManager;

static int hid_layout_known(IOHIDDeviceRef device) {
    CFTypeRef vendor = IOHIDDeviceGetProperty(device, CFSTR(kIOHIDVendorIDKey));
    int vid = 0; if (vendor) CFNumberGetValue(vendor, kCFNumberIntType, &vid);
    return vid == 0x2dc8;   // 8BitDo
}

/* GameController takes this controller itself (a later firmware or mode may make it an MFi or Xbox controller). */
static int hid_taken_by_gamecontroller(const struct hid_pad *pad) {
    for (GCController *controller in GCController.controllers)
        if (controller.extendedGamepad && controller.vendorName && !strcmp(controller.vendorName.UTF8String, pad->name)) return 1;
    return 0;
}

static float hid_axis(IOHIDElementRef element, long value) {
    long lo = IOHIDElementGetLogicalMin(element), hi = IOHIDElementGetLogicalMax(element);
    if (hi <= lo) return 0;
    float v = (float)(value - lo) / (float)(hi - lo) * 2.0f - 1.0f;
    return v < -1 ? -1 : v > 1 ? 1 : v;
}

static struct hid_pad *hid_slot(IOHIDDeviceRef device) {
    for (int i = 0; i < HID_PADS; i++) if (hidPads[i].device == device) return &hidPads[i];
    return NULL;
}

static void hid_value(void *context, IOReturn result, void *sender, IOHIDValueRef value) {
    (void)context; (void)result; (void)sender;
    IOHIDElementRef element = IOHIDValueGetElement(value);
    struct hid_pad *pad = hid_slot(IOHIDElementGetDevice(element));
    if (!pad) return;
    uint32_t page = IOHIDElementGetUsagePage(element), usage = IOHIDElementGetUsage(element);
    long v = IOHIDValueGetIntegerValue(value);
    if (page == kHIDPage_Button) { if (usage >= 1 && usage <= HID_BUTTONS) pad->button[usage] = v != 0; else return; }
    else if (page == kHIDPage_GenericDesktop && usage == kHIDUsage_GD_Hatswitch) pad->hat = (int)(v - IOHIDElementGetLogicalMin(element));
    else if (page == kHIDPage_GenericDesktop && usage == kHIDUsage_GD_X) pad->lx = hid_axis(element, v);
    else if (page == kHIDPage_GenericDesktop && usage == kHIDUsage_GD_Y) pad->ly = -hid_axis(element, v);
    else if (page == kHIDPage_GenericDesktop && usage == kHIDUsage_GD_Z) pad->rx = hid_axis(element, v);
    else if (page == kHIDPage_GenericDesktop && usage == kHIDUsage_GD_Rz) pad->ry = -hid_axis(element, v);
    else return;   // battery, analog trigger depth (the trigger buttons already report the press)
    refresh_gamepads();
}

static void hid_attach(void *context, IOReturn result, void *sender, IOHIDDeviceRef device) {
    (void)context; (void)result; (void)sender;
    if (!hid_layout_known(device) || hid_slot(device)) return;
    struct hid_pad *pad = hid_slot(NULL);
    if (!pad) return;
    *pad = (struct hid_pad){.device = device, .hat = 8};
    CFTypeRef product = IOHIDDeviceGetProperty(device, CFSTR(kIOHIDProductKey));
    if (!product || !CFStringGetCString(product, pad->name, sizeof pad->name, kCFStringEncodingUTF8)) snprintf(pad->name, sizeof pad->name, "HID gamepad");
    fprintf(stderr, "[totk-input] HID gamepad connected: %s (8BitDo DirectInput layout)%s\n", pad->name,
            hid_taken_by_gamecontroller(pad) ? ", read through GameController instead" : "");
    refresh_gamepads();
}

static void hid_detach(void *context, IOReturn result, void *sender, IOHIDDeviceRef device) {
    (void)context; (void)result; (void)sender;
    struct hid_pad *pad = hid_slot(device);
    if (!pad) return;
    fprintf(stderr, "[totk-input] HID gamepad disconnected: %s\n", pad->name);
    *pad = (struct hid_pad){0};
    refresh_gamepads();
}

static void hid_start(void) {
    const char *e = getenv("TOTK_HID_GAMEPADS");
    if (e && !strcmp(e, "0")) return;
    hidManager = IOHIDManagerCreate(kCFAllocatorDefault, kIOHIDOptionsTypeNone);
    NSArray *matching = @[@{@kIOHIDDeviceUsagePageKey: @(kHIDPage_GenericDesktop), @kIOHIDDeviceUsageKey: @(kHIDUsage_GD_GamePad)},
                          @{@kIOHIDDeviceUsagePageKey: @(kHIDPage_GenericDesktop), @kIOHIDDeviceUsageKey: @(kHIDUsage_GD_Joystick)}];
    IOHIDManagerSetDeviceMatchingMultiple(hidManager, (__bridge CFArrayRef)matching);
    IOHIDManagerRegisterDeviceMatchingCallback(hidManager, hid_attach, NULL);
    IOHIDManagerRegisterDeviceRemovalCallback(hidManager, hid_detach, NULL);
    IOHIDManagerRegisterInputValueCallback(hidManager, hid_value, NULL);
    IOHIDManagerSetDispatchQueue(hidManager, dispatch_get_main_queue());
    IOReturn r = IOHIDManagerOpen(hidManager, kIOHIDOptionsTypeNone);   // before Activate: IOKit traps on callbacks set up after it
    if (r != kIOReturnSuccess) fprintf(stderr, "[totk-input] HID gamepads unavailable (IOHIDManagerOpen 0x%x)\n", r);
    IOHIDManagerActivate(hidManager);
}

static uint64_t hid_buttons(const struct hid_pad *pad) {
    const uint8_t *b = pad->button;
    uint64_t buttons = gamepad_face_positions(b[1], b[2], b[4], b[5], gamepad_face_by_position(NULL, pad->name));
    static const struct { uint8_t hid; uint8_t bit; } rest[] = {{14, 4}, {15, 5}, {7, 6}, {8, 7}, {9, 8}, {10, 9}, {12, 10}, {11, 11}};
    for (size_t i = 0; i < sizeof rest / sizeof *rest; i++) if (b[rest[i].hid]) buttons |= 1ULL << rest[i].bit;
    int h = pad->hat;   // 0 up, 1 up-right, ... 7 up-left
    if (h >= 0 && h < 8) {
        if (h == 7 || h == 0 || h == 1) buttons |= 1ULL << 13;
        if (h >= 1 && h <= 3) buttons |= 1ULL << 14;
        if (h >= 3 && h <= 5) buttons |= 1ULL << 15;
        if (h >= 5 && h <= 7) buttons |= 1ULL << 12;
    }
    return buttons;
}
#endif   // TARGET_OS_OSX

static void refresh_gamepads(void) {
    RuntimeGamepadState next = {0};
    uint64_t physical = 0;
    for (GCController *controller in GCController.controllers) {
        GCExtendedGamepad *pad = controller.extendedGamepad;
        if (!pad) continue;
        next.connected = 1;
        physical |= gamepad_buttons(pad, face_by_position(controller));
        next.lx = stronger_axis(next.lx, stick_axis(pad.leftThumbstick.xAxis.value));
        next.ly = stronger_axis(next.ly, stick_axis(pad.leftThumbstick.yAxis.value));
        next.rx = stronger_axis(next.rx, stick_axis(pad.rightThumbstick.xAxis.value));
        next.ry = stronger_axis(next.ry, stick_axis(pad.rightThumbstick.yAxis.value));
    }
#if TARGET_OS_OSX
    for (int i = 0; i < HID_PADS; i++) {
        const struct hid_pad *pad = &hidPads[i];
        if (!pad->device || hid_taken_by_gamecontroller(pad)) continue;
        next.connected = 1;
        physical |= hid_buttons(pad);
        next.lx = stronger_axis(next.lx, stick_axis(pad->lx));
        next.ly = stronger_axis(next.ly, stick_axis(pad->ly));
        next.rx = stronger_axis(next.rx, stick_axis(pad->rx));
        next.ry = stronger_axis(next.ry, stick_axis(pad->ry));
    }
#endif
    /* Modes work on the physical buttons, not on the mapped ones: two physical buttons may share a Switch button
       (X and L3 both running), and a mapped edge would be lost while the other one is held. */
    uint64_t now = runtime_now_ns(), edges = physical & ~physicalPrev, synthetic = 0, suppressed = 0;
    int moving = next.lx || next.ly;
    physicalPrev = physical;
    for (int i = 0; i < CONTROLLER_BUTTONS; i++) {
        uint64_t bit = 1ULL << i;
        int kind = controller_mode_kind(controllerModes[i]);
        if (kind == CONTROLLER_TAP && (edges & bit)) {
            tapUntil[i] = now + 400000000ULL;
            /* Release the pulse even if the controller sends no further event. */
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(400 * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{ refresh_gamepads(); });
        }
        if (kind == CONTROLLER_TOGGLE) {
            if (edges & bit) { toggleOn[i] = !toggleOn[i]; toggleMoved[i] = moving; }
            if (toggleOn[i] && moving) toggleMoved[i] = 1;
            /* A toggle ends when the stick returns to center after moving, or the controller goes away; clicking at rest
               waits for the first move, and attacking while running does not stop it. */
            if (toggleOn[i] && ((toggleMoved[i] && !moving) || !next.connected)) toggleOn[i] = 0;
        }
        if (kind == CONTROLLER_AIM && (physical & bit)) {
            /* Aim: the Switch button is held while drawing, released while the fire button is down (the shot), and its
               fire button does nothing else meanwhile. */
            uint64_t fire = 1ULL << controller_mode_fire(controllerModes[i]);
            suppressed |= fire;
            if (!(physical & fire)) synthetic |= controllerMap[i];
        }
        int active = kind == CONTROLLER_TAP ? now < tapUntil[i] : kind == CONTROLLER_TOGGLE ? toggleOn[i] : 0;
        if (active) synthetic |= controllerMap[i];
    }
    uint64_t held = physical & ~suppressed;
    for (int i = 0; i < CONTROLLER_BUTTONS; i++) if (controllerModes[i] != CONTROLLER_HOLD) held &= ~(1ULL << i);
    next.buttons |= controller_map_apply(controllerMap, held) | synthetic;
    pthread_mutex_lock(&gamepadLock);
    pressedEdges |= next.buttons & ~gamepadState.buttons;
    gamepadState = next;
    pthread_mutex_unlock(&gamepadLock);
}

static void attach_gamepad(GCController *controller) {
    GCExtendedGamepad *pad = controller.extendedGamepad;
    if (!pad) return;
    pad.valueChangedHandler = ^(GCExtendedGamepad *changed, GCControllerElement *element) {
        (void)changed; (void)element;
        refresh_gamepads();
    };
    fprintf(stderr, "[totk-input] native gamepad connected: %s (%s), face buttons by %s\n",
            (controller.vendorName ?: @"unknown").UTF8String,
            (controller.productCategory ?: @"unknown").UTF8String, face_by_position(controller) ? "position" : "label");
    runtime_feedback_attach(controller);
    refresh_gamepads();
}

void runtime_gamepad_start(void) {
    if (started) return;
    started = YES;
    load_controller_map();
    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
    [center addObserverForName:GCControllerDidConnectNotification object:nil queue:NSOperationQueue.mainQueue
                   usingBlock:^(NSNotification *notification) { attach_gamepad(notification.object); }];
    [center addObserverForName:GCControllerDidDisconnectNotification object:nil queue:NSOperationQueue.mainQueue
                   usingBlock:^(NSNotification *notification) {
                       GCController *controller = notification.object;
                       fprintf(stderr, "[totk-input] native gamepad disconnected: %s\n",
                               (controller.vendorName ?: @"unknown").UTF8String);
                       runtime_feedback_detach(controller);
                       refresh_gamepads();
                   }];
    for (GCController *controller in GCController.controllers) attach_gamepad(controller);
    [GCController startWirelessControllerDiscoveryWithCompletionHandler:nil];
#if TARGET_OS_OSX
    hid_start();
#endif
}

void runtime_gamepad_clear(void) {
    runtime_feedback_quiet();
    physicalPrev = 0;
    memset(tapUntil, 0, sizeof tapUntil);
    memset(toggleOn, 0, sizeof toggleOn);
    memset(toggleMoved, 0, sizeof toggleMoved);
    pthread_mutex_lock(&gamepadLock);
    gamepadState = (RuntimeGamepadState){0};
    pressedEdges = 0;
    pthread_mutex_unlock(&gamepadLock);
}

/* On-screen touch controls (iPhone, ios/app/Sources/touch_controls.m) feed a second state merged with the physical
   controllers: buttons are OR-ed (a tap shorter than one game frame is latched like a controller press), each stick
   axis takes the stronger value. */
static RuntimeGamepadState touchState;
void runtime_touch_pad_set(const RuntimeGamepadState *s) {
    pthread_mutex_lock(&gamepadLock);
    pressedEdges |= s->buttons & ~touchState.buttons;
    touchState = *s;
    pthread_mutex_unlock(&gamepadLock);
}

void runtime_gamepad_read(RuntimeGamepadState *out) {
    pthread_mutex_lock(&gamepadLock);
    *out = gamepadState;
    out->buttons |= touchState.buttons | pressedEdges;
    out->lx = stronger_axis(out->lx, touchState.lx); out->ly = stronger_axis(out->ly, touchState.ly);
    out->rx = stronger_axis(out->rx, touchState.rx); out->ry = stronger_axis(out->ry, touchState.ry);
    if (touchState.connected) out->connected = 1;
    pressedEdges = 0;
    pthread_mutex_unlock(&gamepadLock);
}
