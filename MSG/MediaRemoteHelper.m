// MediaRemoteHelper.m
//
// Compiled into Resources/libMSGMediaRemote.dylib by a build phase (see
// build.sh and the "Compile MediaRemote Helper" phase in the Xcode project).
// It is NOT part of the app target's sources.
//
// macOS 15.4+ only serves MediaRemote now-playing data to processes that hold
// the com.apple.mediaremote.fetch-now-playing-info entitlement — and AMFI
// kills self-signed binaries that claim it. Platform (Apple-signed) binaries
// still pass the check, so MSG loads this dylib into /usr/bin/perl via
// DynaLoader; the constructor below runs inside that process and talks to MSG
// over stdout.
//
// The streaming model mirrors ungive/mediaremote-adapter: keep an accumulated
// snapshot of the now-playing item ("live data"), update it from the three
// MediaRemote notifications, and only ever emit when something changes. Two
// rules keep the snapshot honest:
//   * "playing" comes from MRMediaRemoteGetNowPlayingApplicationIsPlaying (an
//     authoritative bool) rather than the playback rate, which some players
//     leave stale while paused.
//   * title/artist are replaced from fresh info on every info change, and the
//     whole snapshot is reset when the now-playing PID changes — so a new item
//     that exposes no title never inherits the previous track's title.
// Artwork is carried across same-item updates because MediaRemote briefly
// unloads it (e.g. while seeking).
//
// Modes (MSG_MR_MODE env var):
//   "stream"  (default) — emit one JSON line per now-playing change:
//             {"playing":bool,"title":..,"artist":..,"pid":int,"art":base64}
//   "command" — send MSG_MR_CMD (kMRMediaRemote command code) and exit.

#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <objc/message.h>
#import <signal.h>
#import <stdlib.h>
#import <unistd.h>

typedef void (*MRGetInfoFunc)(dispatch_queue_t, void (^)(CFDictionaryRef));
typedef void (*MRGetPIDFunc)(dispatch_queue_t, void (^)(int));
typedef void (*MRGetIsPlayingFunc)(dispatch_queue_t, void (^)(Boolean));
typedef void (*MRGetPlaybackStateFunc)(dispatch_queue_t, void (^)(int));
typedef void (*MRRegisterFunc)(dispatch_queue_t);
typedef Boolean (*MRSendCommandFunc)(uint32_t, CFDictionaryRef);

static MRGetInfoFunc gGetInfo;
static MRGetPIDFunc gGetPID;
static MRGetIsPlayingFunc gGetIsPlaying;
static MRGetPlaybackStateFunc gGetPlaybackState;
static dispatch_queue_t gQueue;
static dispatch_source_t gTimer;

// Accumulated now-playing snapshot. Only ever touched on gQueue.
static int       gPid = -1;
static BOOL      gPlaying = NO;
static NSString *gTitle = nil;
static NSString *gArtist = nil;
static NSData   *gArt = nil;
static NSString *gLastLine = nil;

// Notification userInfo keys, resolved from the framework at launch (with
// literal fallbacks — for MediaRemote the symbol value equals its name).
static NSString *gPidKey = @"kMRMediaRemoteNowPlayingApplicationPIDUserInfoKey";
static NSString *gIsPlayingKey = @"kMRMediaRemoteNowPlayingApplicationIsPlayingUserInfoKey";

// dlsym an `extern NSString *` symbol; fall back to a literal if unavailable.
static NSString *mrKey(void *h, const char *sym, NSString *fallback) {
    NSString *__unsafe_unretained *p = (NSString *__unsafe_unretained *)dlsym(h, sym);
    if (p && *p) return *p;
    return fallback;
}

static NSString *stringValueForMediaKey(NSDictionary *info, NSArray<NSString *> *exactKeys, NSString *keyFragment) {
    for (NSString *key in exactKeys) {
        id value = info[key];
        if ([value isKindOfClass:[NSString class]] && [(NSString *)value length] > 0) {
            return value;
        }
    }

    for (id rawKey in info.allKeys) {
        if (![rawKey isKindOfClass:[NSString class]]) continue;
        NSString *key = (NSString *)rawKey;
        if ([key rangeOfString:keyFragment options:NSCaseInsensitiveSearch].location == NSNotFound) continue;
        id value = info[key];
        if ([value isKindOfClass:[NSString class]] && [(NSString *)value length] > 0) {
            return value;
        }
    }

    return nil;
}

// Pull title/artist/artwork out of a fresh info dict and store them, REPLACING
// the previous values (nil when the current item lacks them). Artwork is kept
// when the update carries none, since MediaRemote briefly unloads it.
static void applyInfo(NSDictionary *info) {
    NSString *title = stringValueForMediaKey(info, @[
        @"kMRMediaRemoteNowPlayingInfoTitle",
        @"MRMediaRemoteNowPlayingInfoTitle",
        @"Title",
    ], @"Title");
    NSString *artist = stringValueForMediaKey(info, @[
        @"kMRMediaRemoteNowPlayingInfoArtist",
        @"MRMediaRemoteNowPlayingInfoArtist",
        @"Artist",
    ], @"Artist");

    gTitle = (title.length > 0) ? title : nil;
    gArtist = (artist.length > 0) ? artist : nil;

    NSData *art = info[@"kMRMediaRemoteNowPlayingInfoArtworkData"];
    if (![art isKindOfClass:[NSData class]]) {
        art = nil;
        for (id val in info.allValues) {
            if ([val isKindOfClass:[NSData class]] && [val length] > 1000) { art = val; break; }
        }
    }
    if (art != nil) gArt = art;   // keep prior artwork when this update has none
}

// A different app became "now playing" — drop the previous item's metadata so
// it can't be shown against the new source.
static void setPid(int pid) {
    if (pid == gPid) return;
    gPid = pid;
    gTitle = nil;
    gArtist = nil;
    gArt = nil;
}

static void emitLine(void) {
    NSMutableDictionary *out = [NSMutableDictionary dictionary];
    out[@"playing"] = @(gPlaying);
    out[@"pid"] = @(gPid > 0 ? gPid : 0);
    if (gTitle)  out[@"title"]  = gTitle;
    if (gArtist) out[@"artist"] = gArtist;
    if (gArt)    out[@"art"]    = [gArt base64EncodedStringWithOptions:0];

    NSData *json = [NSJSONSerialization dataWithJSONObject:out options:0 error:NULL];
    if (!json) return;
    NSString *line = [[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding];
    if (!line || [line isEqualToString:gLastLine]) return;
    gLastLine = line;
    printf("%s\n", line.UTF8String);
    fflush(stdout);
}

static void requestPid(void) {
    if (!gGetPID) return;
    gGetPID(gQueue, ^(int pid) { setPid(pid); emitLine(); });
}

static void requestInfo(void) {
    if (!gGetInfo) return;
    gGetInfo(gQueue, ^(CFDictionaryRef ci) {
        applyInfo((__bridge NSDictionary *)ci);
        emitLine();
    });
}

static void requestIsPlaying(void) {
    if (gGetIsPlaying) {
        gGetIsPlaying(gQueue, ^(Boolean p) { gPlaying = p; emitLine(); });
    } else if (gGetPlaybackState) {
        // Fallback: playback state 1 == playing, 2 == paused.
        gGetPlaybackState(gQueue, ^(int st) { gPlaying = (st == 1); emitLine(); });
    }
}

// Handle any of the now-playing notifications and the heartbeat: apply
// whatever the notification carried directly (fast path), then refresh the
// authoritative signals and metadata.
static void handleUpdate(NSNotification *n) {
    NSDictionary *ui = n.userInfo;
    id pidVal = ui[gPidKey];
    BOOL havePid = [pidVal isKindOfClass:[NSNumber class]];
    if (havePid) setPid([pidVal intValue]);

    id playingVal = ui[gIsPlayingKey];
    BOOL havePlaying = [playingVal isKindOfClass:[NSNumber class]];
    if (havePlaying) gPlaying = [playingVal boolValue];

    emitLine();   // reflect pid/playing from the notification immediately

    if (!havePid) requestPid();
    if (!havePlaying) requestIsPlaying();
    requestInfo();   // always refresh title/artist/artwork
}

static void refreshAll(void) {
    requestPid();
    requestIsPlaying();
    requestInfo();
}

__attribute__((constructor))
static void MSGMediaRemoteMain(void) {
    @autoreleasepool {
        void *h = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW);
        gGetInfo = (MRGetInfoFunc)dlsym(h, "MRMediaRemoteGetNowPlayingInfo");
        gGetPID = (MRGetPIDFunc)dlsym(h, "MRMediaRemoteGetNowPlayingApplicationPID");
        gGetIsPlaying = (MRGetIsPlayingFunc)dlsym(h, "MRMediaRemoteGetNowPlayingApplicationIsPlaying");
        gGetPlaybackState = (MRGetPlaybackStateFunc)dlsym(h, "MRMediaRemoteGetNowPlayingApplicationPlaybackState");
        MRRegisterFunc reg = (MRRegisterFunc)dlsym(h, "MRMediaRemoteRegisterForNowPlayingNotifications");
        MRSendCommandFunc send = (MRSendCommandFunc)dlsym(h, "MRMediaRemoteSendCommand");
        if (!gGetInfo || !gGetPID) {
            printf("{\"error\":\"symbols\"}\n");
            fflush(stdout);
            exit(1);
        }

        const char *mode = getenv("MSG_MR_MODE");
        if (mode && strcmp(mode, "command") == 0) {
            const char *cmd = getenv("MSG_MR_CMD");
            Boolean ok = send && cmd ? send((uint32_t)atoi(cmd), NULL) : false;
            // Give the XPC message time to reach mediaremoted before exiting.
            [NSThread sleepForTimeInterval:0.3];
            exit(ok ? 0 : 1);
        }

        // One-shot read (the poll path, modelled on kernoeb/mac-now-playing):
        // gather PID + authoritative isPlaying + info once, print a single JSON
        // line, and exit. A fresh process per poll can never go stale the way a
        // long-lived notification stream does.
        //
        // Prefer the SYNCHRONOUS MRNowPlayingRequest class (localIsPlaying /
        // localNowPlayingItem). The async C API (MRMediaRemoteGetNowPlayingInfo)
        // is unusable here: on rapid fresh spawns its XPC completion frequently
        // never fires, so the read times out with no title.
        if (mode && strcmp(mode, "get") == 0) {
            Class Req = NSClassFromString(@"MRNowPlayingRequest");
            if (Req) {
                gPlaying = ((BOOL (*)(id, SEL))objc_msgSend)(Req, @selector(localIsPlaying));

                id item = ((id (*)(id, SEL))objc_msgSend)(Req, @selector(localNowPlayingItem));
                if (item) {
                    id info = ((id (*)(id, SEL))objc_msgSend)(item, @selector(nowPlayingInfo));
                    if ([info isKindOfClass:[NSDictionary class]]) applyInfo(info);
                }

                id path = ((id (*)(id, SEL))objc_msgSend)(Req, @selector(localNowPlayingPlayerPath));
                if (path) {
                    id client = ((id (*)(id, SEL))objc_msgSend)(path, @selector(client));
                    if (client) {
                        int pid = ((int (*)(id, SEL))objc_msgSend)(client, @selector(processIdentifier));
                        gPid = (pid > 0) ? pid : 0;
                    }
                }

                emitLine();
                exit(0);
            }

            // Fallback: the async C API, guarded by a timeout. Completions run on
            // the serial gQueue, so the counter is safe.
            gQueue = dispatch_queue_create("msg.mediaremote.get", NULL);
            dispatch_semaphore_t sem = dispatch_semaphore_create(0);
            __block int pending = 3;
            void (^done)(void) = ^{ if (--pending == 0) dispatch_semaphore_signal(sem); };

            if (gGetPID) {
                gGetPID(gQueue, ^(int pid) { gPid = (pid > 0) ? pid : 0; done(); });
            } else { done(); }

            if (gGetIsPlaying) {
                gGetIsPlaying(gQueue, ^(Boolean p) { gPlaying = p; done(); });
            } else if (gGetPlaybackState) {
                gGetPlaybackState(gQueue, ^(int st) { gPlaying = (st == 1); done(); });
            } else { done(); }

            if (gGetInfo) {
                gGetInfo(gQueue, ^(CFDictionaryRef ci) { applyInfo((__bridge NSDictionary *)ci); done(); });
            } else { done(); }

            dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC));
            emitLine();
            exit(0);
        }

        gPidKey = mrKey(h, "kMRMediaRemoteNowPlayingApplicationPIDUserInfoKey", gPidKey);
        gIsPlayingKey = mrKey(h, "kMRMediaRemoteNowPlayingApplicationIsPlayingUserInfoKey", gIsPlayingKey);

        gQueue = dispatch_queue_create("msg.mediaremote", NULL);
        if (reg) reg(gQueue);

        NSArray *names = @[
            @"kMRMediaRemoteNowPlayingInfoDidChangeNotification",
            @"kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification",
            @"kMRMediaRemoteNowPlayingApplicationDidChangeNotification",
        ];
        for (NSString *name in names) {
            [[NSNotificationCenter defaultCenter] addObserverForName:name
                                                              object:nil
                                                               queue:nil
                                                          usingBlock:^(NSNotification *n) {
                dispatch_async(gQueue, ^{ handleUpdate(n); });
            }];
        }

        dispatch_async(gQueue, ^{ refreshAll(); });

        // Heartbeat: catch changes whose notifications were missed, and exit
        // when MSG is gone (perl gets reparented to launchpid 1).
        gTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, gQueue);
        dispatch_source_set_timer(gTimer, DISPATCH_TIME_NOW, NSEC_PER_SEC, NSEC_PER_SEC / 10);
        dispatch_source_set_event_handler(gTimer, ^{
            const char *parent = getenv("MSG_PARENT_PID");
            if (parent && parent[0] != '\0') {
                pid_t parentPID = (pid_t)atoi(parent);
                if (parentPID > 1 && kill(parentPID, 0) != 0) exit(0);
            }
            if (getppid() == 1) exit(0);
            refreshAll();
        });
        dispatch_resume(gTimer);

        dispatch_main();
    }
}
