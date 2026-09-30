// Minimal MediaRemote reader, written from scratch for the spike.
// Loaded two ways: in-process by NowPlayingSpike ("direct" route) and by
// /usr/bin/perl through DynaLoader ("perl" route). Comparing the two tells us
// whether macOS 27 still restricts MediaRemote to allow-listed clients.

#import <Foundation/Foundation.h>
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include "NowPlayingBridge.h"

typedef void (*MRGetInfoFn)(dispatch_queue_t, void (^)(CFDictionaryRef));
typedef void (*MRGetIsPlayingFn)(dispatch_queue_t, void (^)(Boolean));
typedef void (*MRGetPIDFn)(dispatch_queue_t, void (^)(int));
typedef void (*MRRegisterFn)(dispatch_queue_t);

static void *mr(void) {
    static void *h = NULL;
    if (!h) h = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW);
    return h;
}

static id jsonSafe(id v) {
    if (!v || v == [NSNull null]) return [NSNull null];
    if ([v isKindOfClass:[NSString class]] || [v isKindOfClass:[NSNumber class]]) return v;
    if ([v isKindOfClass:[NSDate class]]) return @([(NSDate *)v timeIntervalSince1970]);
    if ([v isKindOfClass:[NSData class]]) return @{@"bytes": @([(NSData *)v length])};
    if ([v isKindOfClass:[NSArray class]]) {
        NSMutableArray *a = [NSMutableArray array];
        for (id x in (NSArray *)v) [a addObject:jsonSafe(x)];
        return a;
    }
    if ([v isKindOfClass:[NSDictionary class]]) {
        NSMutableDictionary *d = [NSMutableDictionary dictionary];
        [(NSDictionary *)v enumerateKeysAndObjectsUsingBlock:^(id k, id obj, BOOL *stop) {
            d[[k description]] = jsonSafe(obj);
        }];
        return d;
    }
    return [v description];
}

char *np_fetch_json(double timeoutSeconds) {
    @autoreleasepool {
        NSDate *start = [NSDate date];
        NSMutableDictionary *out = [NSMutableDictionary dictionary];
        void *h = mr();
        if (!h) {
            out[@"ok"] = @NO;
            out[@"error"] = @"dlopen MediaRemote failed";
        } else {
            MRGetInfoFn getInfo = (MRGetInfoFn)dlsym(h, "MRMediaRemoteGetNowPlayingInfo");
            MRGetIsPlayingFn getPlaying = (MRGetIsPlayingFn)dlsym(h, "MRMediaRemoteGetNowPlayingApplicationIsPlaying");
            MRGetPIDFn getPID = (MRGetPIDFn)dlsym(h, "MRMediaRemoteGetNowPlayingApplicationPID");
            dispatch_queue_t q = dispatch_queue_create("np.fetch", DISPATCH_QUEUE_SERIAL);
            dispatch_group_t g = dispatch_group_create();
            __block NSDictionary *info = nil;
            __block NSNumber *playing = nil;
            __block NSNumber *pid = nil;
            if (getInfo) {
                dispatch_group_enter(g);
                getInfo(q, ^(CFDictionaryRef d) {
                    info = d ? [(__bridge NSDictionary *)d copy] : nil;
                    dispatch_group_leave(g);
                });
            }
            if (getPlaying) {
                dispatch_group_enter(g);
                getPlaying(q, ^(Boolean p) { playing = @(p ? YES : NO); dispatch_group_leave(g); });
            }
            if (getPID) {
                dispatch_group_enter(g);
                getPID(q, ^(int p) { pid = @(p); dispatch_group_leave(g); });
            }
            long timedOut = dispatch_group_wait(g, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(timeoutSeconds * NSEC_PER_SEC)));
            NSMutableDictionary *clean = nil;
            if (info) {
                clean = [NSMutableDictionary dictionary];
                [info enumerateKeysAndObjectsUsingBlock:^(id k, id v, BOOL *stop) {
                    NSString *key = [[k description] stringByReplacingOccurrencesOfString:@"kMRMediaRemoteNowPlayingInfo" withString:@""];
                    clean[key] = jsonSafe(v);
                }];
            }
            out[@"ok"] = @(timedOut == 0);
            out[@"symbols"] = @{@"info": @(getInfo != NULL), @"isPlaying": @(getPlaying != NULL), @"pid": @(getPID != NULL)};
            out[@"isPlaying"] = playing ?: [NSNull null];
            out[@"pid"] = pid ?: [NSNull null];
            out[@"info"] = clean ?: [NSNull null];
        }
        out[@"clientPID"] = @(getpid());
        out[@"elapsedMs"] = @((int)(-[start timeIntervalSinceNow] * 1000));
        NSData *data = [NSJSONSerialization dataWithJSONObject:out options:NSJSONWritingSortedKeys error:nil];
        NSString *s = data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : @"{\"ok\":false,\"error\":\"json\"}";
        return strdup(s.UTF8String);
    }
}

static void emit(const char *event) {
    char *j = np_fetch_json(3.0);
    printf("{\"event\":\"%s\",\"at\":%.3f,\"state\":%s}\n", event, [[NSDate date] timeIntervalSince1970], j);
    fflush(stdout);
    free(j);
}

void np_run(void *interp, void *cv) {
    (void)interp; (void)cv;
    const char *modeC = getenv("NP_MODE");
    NSString *mode = modeC ? @(modeC) : @"once";
    if (![mode hasPrefix:@"stream:"]) {
        emit("once");
        exit(0);
    }
    double seconds = [[mode substringFromIndex:7] doubleValue];
    if (seconds <= 0) seconds = 20;
    void *h = mr();
    MRRegisterFn reg = h ? (MRRegisterFn)dlsym(h, "MRMediaRemoteRegisterForNowPlayingNotifications") : NULL;
    if (reg) reg(dispatch_get_main_queue());
    const char *names[] = {
        "kMRMediaRemoteNowPlayingInfoDidChangeNotification",
        "kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification",
        "kMRMediaRemoteNowPlayingApplicationDidChangeNotification",
    };
    for (int i = 0; i < 3; i++) {
        CFStringRef *sym = h ? (CFStringRef *)dlsym(h, names[i]) : NULL;
        NSString *name = sym && *sym ? (__bridge NSString *)*sym : @(names[i]);
        const char *label = names[i] + 24; // strip "kMRMediaRemoteNowPlaying"
        [[NSNotificationCenter defaultCenter] addObserverForName:name object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *n) {
            emit(label);
        }];
    }
    emit("start");
    CFRunLoopRunInMode(kCFRunLoopDefaultMode, seconds, false);
    emit("end");
    exit(0);
}
