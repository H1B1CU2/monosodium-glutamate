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
// Modes (MSG_MR_MODE env var):
//   "stream"  (default) — emit one JSON line per now-playing change:
//             {"playing":bool,"title":..,"artist":..,"pid":int,"art":base64}
//   "command" — send MSG_MR_CMD (kMRMediaRemote command code) and exit.

#import <Foundation/Foundation.h>
#import <dlfcn.h>

typedef void (*MRGetInfoFunc)(dispatch_queue_t, void (^)(CFDictionaryRef));
typedef void (*MRGetPIDFunc)(dispatch_queue_t, void (^)(int));
typedef void (*MRRegisterFunc)(dispatch_queue_t);
typedef Boolean (*MRSendCommandFunc)(uint32_t, CFDictionaryRef);

static MRGetInfoFunc gGetInfo;
static MRGetPIDFunc gGetPID;
static dispatch_queue_t gQueue;
static NSString *gLastLine;

static void emitState(void) {
    gGetPID(gQueue, ^(int pid) {
        gGetInfo(gQueue, ^(CFDictionaryRef cfInfo) {
            NSDictionary *info = (__bridge NSDictionary *)cfInfo;
            NSMutableDictionary *out = [NSMutableDictionary dictionary];

            NSNumber *rate = info[@"kMRMediaRemoteNowPlayingInfoPlaybackRate"];
            NSString *title = info[@"kMRMediaRemoteNowPlayingInfoTitle"];
            NSString *artist = info[@"kMRMediaRemoteNowPlayingInfoArtist"];
            BOOL playing = rate != nil ? rate.doubleValue > 0.01 : title.length > 0;

            out[@"playing"] = @(playing);
            out[@"pid"] = @(pid);
            if ([title isKindOfClass:[NSString class]])  out[@"title"]  = title;
            if ([artist isKindOfClass:[NSString class]]) out[@"artist"] = artist;

            NSData *art = info[@"kMRMediaRemoteNowPlayingInfoArtworkData"];
            if (![art isKindOfClass:[NSData class]]) {
                for (id val in info.allValues) {
                    if ([val isKindOfClass:[NSData class]] && [val length] > 1000) { art = val; break; }
                }
            }
            if ([art isKindOfClass:[NSData class]]) {
                out[@"art"] = [art base64EncodedStringWithOptions:0];
            }

            NSData *json = [NSJSONSerialization dataWithJSONObject:out options:0 error:NULL];
            if (!json) return;
            NSString *line = [[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding];
            if (!line || [line isEqualToString:gLastLine]) return;
            gLastLine = line;
            printf("%s\n", line.UTF8String);
            fflush(stdout);
        });
    });
}

__attribute__((constructor))
static void MSGMediaRemoteMain(void) {
    @autoreleasepool {
        void *h = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW);
        gGetInfo = (MRGetInfoFunc)dlsym(h, "MRMediaRemoteGetNowPlayingInfo");
        gGetPID = (MRGetPIDFunc)dlsym(h, "MRMediaRemoteGetNowPlayingApplicationPID");
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
                                                          usingBlock:^(NSNotification *n) { emitState(); }];
        }

        emitState();

        // Heartbeat: catch changes whose notifications were missed, and exit
        // when MSG is gone (perl gets reparented to launchpid 1).
        dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, gQueue);
        dispatch_source_set_timer(timer, DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC, NSEC_PER_SEC / 4);
        dispatch_source_set_event_handler(timer, ^{
            if (getppid() == 1) exit(0);
            emitState();
        });
        dispatch_resume(timer);

        dispatch_main();
    }
}
