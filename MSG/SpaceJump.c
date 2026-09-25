#include <ApplicationServices/ApplicationServices.h>
#include <CoreFoundation/CoreFoundation.h>
#include <mach/mach_time.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/sysctl.h>
#include <unistd.h>

static const CGEventField kEventTypeField = (CGEventField)55;
static const CGEventField kGestureHIDType = (CGEventField)110;
static const CGEventField kGestureMotion = (CGEventField)123;
static const CGEventField kGestureProgress = (CGEventField)124;
static const CGEventField kGesturePositionX = (CGEventField)125;
static const CGEventField kGestureVelocityX = (CGEventField)129;
static const CGEventField kGesturePhase = (CGEventField)132;
static const CGEventField kGesturePhaseAlias = (CGEventField)134;
static const CGEventField kGestureZoomDeltaY = (CGEventField)138;
static const CGEventField kSourceProcessAlias = (CGEventField)169;
static const uint16_t kRawIOHIDPayloadField = 4205;

enum { kEventGesture = 29, kEventDockControl = 30 };
enum { kHIDDockSwipe = 23, kMotionHorizontal = 1 };
enum { kPhaseBegan = 1, kPhaseChanged = 2, kPhaseEnded = 4 };

#pragma pack(push, 1)
typedef struct {
    uint32_t size;
    uint32_t type;
    uint32_t options;
    uint8_t depth;
    uint8_t reserved[3];
} MSGIOHIDEventBase;

typedef struct {
    MSGIOHIDEventBase base;
    int32_t positionX;
    int32_t positionY;
    int32_t positionZ;
    uint32_t swipeMask;
    uint16_t gestureMotion;
    uint16_t gestureFlavor;
    int32_t swipeProgress;
} MSGIOHIDFluidTouchGesture;

typedef struct {
    MSGIOHIDEventBase base;
    int32_t velocityX;
    int32_t velocityY;
    int32_t velocityZ;
} MSGIOHIDVelocityEvent;

typedef struct {
    uint64_t timestamp;
    uint64_t senderID;
    uint32_t options;
    uint32_t attributeLength;
    uint32_t eventCount;
} MSGIOHIDQueueHeader;
#pragma pack(pop)

_Static_assert(sizeof(MSGIOHIDEventBase) == 16, "unexpected IOHID event base layout");
_Static_assert(sizeof(MSGIOHIDFluidTouchGesture) == 40, "unexpected fluid gesture layout");
_Static_assert(sizeof(MSGIOHIDVelocityEvent) == 28, "unexpected velocity layout");
_Static_assert(sizeof(MSGIOHIDQueueHeader) == 28, "unexpected IOHID queue layout");

static int32_t fixed1616(double value) {
    int32_t fixed = (int32_t)(value * 65536.0);
    if (fixed == 0 && value != 0.0) return value > 0.0 ? 1 : -1;
    return fixed;
}

static bool requiresAugmentation(void) {
    char version[32] = {0};
    size_t size = sizeof(version);
    if (sysctlbyname("kern.osproductversion", version, &size, NULL, 0) != 0) return false;
    return strtol(version, NULL, 10) >= 27;
}

static uint8_t *makePayload(CGEventRef event, size_t *outLength) {
    int64_t phase = CGEventGetIntegerValueField(event, kGesturePhase);
    double progress = CGEventGetDoubleValueField(event, kGestureProgress);
    double positionX = CGEventGetDoubleValueField(event, kGesturePositionX);
    double velocityX = CGEventGetDoubleValueField(event, kGestureVelocityX);
    bool includeVelocity = phase == kPhaseEnded;
    size_t length = sizeof(MSGIOHIDQueueHeader) + sizeof(MSGIOHIDFluidTouchGesture)
        + (includeVelocity ? sizeof(MSGIOHIDVelocityEvent) : 0);
    uint8_t *payload = calloc(1, length);
    if (!payload) return NULL;

    MSGIOHIDQueueHeader *header = (MSGIOHIDQueueHeader *)payload;
    uint64_t timestamp = CGEventGetTimestamp(event);
    header->timestamp = timestamp ? timestamp : mach_absolute_time();
    header->eventCount = includeVelocity ? 2 : 1;

    MSGIOHIDFluidTouchGesture *fluid = (MSGIOHIDFluidTouchGesture *)(payload + sizeof(*header));
    fluid->base.size = sizeof(*fluid);
    fluid->base.type = 23;
    fluid->base.options = (uint32_t)((phase & 0xff) << 24);
    fluid->positionX = fixed1616(positionX);
    fluid->gestureMotion = kMotionHorizontal;
    fluid->gestureFlavor = 3;
    fluid->swipeProgress = fixed1616(progress);

    if (includeVelocity) {
        MSGIOHIDVelocityEvent *velocity = (MSGIOHIDVelocityEvent *)
            (payload + sizeof(*header) + sizeof(*fluid));
        velocity->base.size = sizeof(*velocity);
        velocity->base.type = 9;
        velocity->base.depth = 1;
        velocity->velocityX = fixed1616(velocityX);
    }
    *outLength = length;
    return payload;
}

// macOS 27 validates synthetic Dock gestures against a serialized IOHID queue
// stored in private CGEvent field 4205. Append that payload to the event data.
static CGEventRef augmentedEvent(CGEventRef event) {
    CFDataRef data = CGEventCreateData(kCFAllocatorDefault, event);
    if (!data) return NULL;
    const uint8_t *bytes = CFDataGetBytePtr(data);
    CFIndex originalLength = CFDataGetLength(data);
    if (originalLength < 4 || bytes[0] != 0 || bytes[1] != 0 ||
        bytes[2] != 0 || bytes[3] != 2) {
        CFRelease(data);
        return NULL;
    }

    size_t payloadLength = 0;
    uint8_t *payload = makePayload(event, &payloadLength);
    if (!payload) { CFRelease(data); return NULL; }
    size_t newLength = (size_t)originalLength + 4 + payloadLength;
    uint8_t *newBytes = malloc(newLength);
    if (!newBytes) { free(payload); CFRelease(data); return NULL; }
    memcpy(newBytes, bytes, (size_t)originalLength);
    newBytes[originalLength] = (uint8_t)(payloadLength >> 8);
    newBytes[originalLength + 1] = (uint8_t)payloadLength;
    newBytes[originalLength + 2] = (uint8_t)(kRawIOHIDPayloadField >> 8);
    newBytes[originalLength + 3] = (uint8_t)kRawIOHIDPayloadField;
    memcpy(newBytes + originalLength + 4, payload, payloadLength);
    free(payload);
    CFRelease(data);

    CFDataRef augmentedData = CFDataCreate(kCFAllocatorDefault, newBytes, (CFIndex)newLength);
    free(newBytes);
    if (!augmentedData) return NULL;
    CGEventRef result = CGEventCreateFromData(kCFAllocatorDefault, augmentedData);
    CFRelease(augmentedData);
    return result;
}

static CGEventRef makeModernDockEvent(int phase, bool right, double velocity) {
    CGEventRef event = CGEventCreate(NULL);
    if (!event) return NULL;
    double sign = right ? -1.0 : 1.0;
    CGEventSetIntegerValueField(event, kEventTypeField, kEventDockControl);
    CGEventSetIntegerValueField(event, kGestureHIDType, kHIDDockSwipe);
    CGEventSetIntegerValueField(event, kGestureMotion, kMotionHorizontal);
    CGEventSetIntegerValueField(event, kGesturePhase, phase);
    CGEventSetIntegerValueField(event, kGesturePhaseAlias, phase);
    CGEventSetDoubleValueField(event, kGestureProgress, sign * 0.000016);
    CGEventSetDoubleValueField(event, kGestureZoomDeltaY, 3.0);
    CGEventSetDoubleValueField(event, kSourceProcessAlias, (double)mach_absolute_time());
    CGEventSetDoubleValueField(event, kGesturePositionX, 0.1);
    if (phase == kPhaseEnded) {
        CGEventSetDoubleValueField(event, kGestureVelocityX, sign * velocity);
    }
    return event;
}

static bool postModernPhase(int phase, bool right, double velocity) {
    CGEventRef base = makeModernDockEvent(phase, right, velocity);
    if (!base) return false;
    CGEventRef dock = augmentedEvent(base);
    CFRelease(base);
    if (!dock) return false;
    CGEventRef companion = CGEventCreate(NULL);
    if (!companion) { CFRelease(dock); return false; }
    CGEventSetIntegerValueField(companion, kEventTypeField, kEventGesture);
    CGEventPost(kCGSessionEventTap, dock);
    CGEventPost(kCGSessionEventTap, companion);
    CFRelease(dock);
    CFRelease(companion);
    return true;
}

static bool postModernJump(bool right, int32_t steps) {
    double velocity = 2000.0 * steps;
    for (int32_t step = 0; step < steps; ++step) {
        if (!postModernPhase(kPhaseBegan, right, velocity)) return false;
        usleep(10000);
        if (!postModernPhase(kPhaseChanged, right, velocity)) return false;
        usleep(10000);
        if (!postModernPhase(kPhaseEnded, right, velocity)) return false;
    }
    return true;
}

static bool postLegacyJump(bool right, int32_t steps) {
    CGEventRef event = CGEventCreate(NULL);
    if (!event) return false;
    double sign = right ? 1.0 : -1.0;
    CGEventSetIntegerValueField(event, kEventTypeField, kEventDockControl);
    CGEventSetIntegerValueField(event, kGestureHIDType, kHIDDockSwipe);
    CGEventSetIntegerValueField(event, kGestureMotion, kMotionHorizontal);
    CGEventSetDoubleValueField(event, kGestureProgress, sign);
    CGEventSetDoubleValueField(event, kGestureVelocityX, sign * 9999.0);
    for (int32_t step = 0; step < steps; ++step) {
        CGEventSetIntegerValueField(event, kGesturePhase, kPhaseBegan);
        CGEventPost(kCGSessionEventTap, event);
        CGEventSetIntegerValueField(event, kGesturePhase, kPhaseEnded);
        CGEventPost(kCGSessionEventTap, event);
    }
    CFRelease(event);
    return true;
}

int32_t MSGPostSpaceJump(int32_t direction, int32_t steps) {
    if (steps <= 0 || !CGPreflightPostEventAccess()) return 0;
    bool right = direction > 0;
    bool posted = requiresAugmentation()
        ? postModernJump(right, steps)
        : postLegacyJump(right, steps);
    return posted ? 1 : 0;
}
