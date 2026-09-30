// NowPlayingBridge: reads and controls Now Playing through the private
// MediaRemote framework.
//
// macOS 15.4+ only answers allow-listed clients, so the app never loads this
// library itself. It runs `/usr/bin/perl np.pl`, which loads this dylib and
// calls np_run(). See Spikes/RESULTS.md.
//
// Protocol
//   stdout: one JSON object per line
//     {"event":…, "at":…, "artworkKey":…, "artwork":<base64, only when changed>,
//      "state":{"ok":…, "isPlaying":…, "pid":…, "info":{…}}}
//   stdin: one command per line
//     toggle | play | pause | next | previous | seek <seconds>
// The process exits when stdin closes (the app quit) or after NP_MODE's duration.

#import <Foundation/Foundation.h>
#include <CommonCrypto/CommonDigest.h>
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>

typedef void (*MRGetInfoFn)(dispatch_queue_t, void (^)(CFDictionaryRef));
typedef void (*MRGetIsPlayingFn)(dispatch_queue_t, void (^)(Boolean));
typedef void (*MRGetPIDFn)(dispatch_queue_t, void (^)(int));
typedef void (*MRRegisterFn)(dispatch_queue_t);
typedef Boolean (*MRSendCommandFn)(int, CFDictionaryRef);
typedef void (*MRSetElapsedFn)(double);

enum { kMRPlay = 0, kMRPause = 1, kMRTogglePlayPause = 2, kMRNextTrack = 4, kMRPreviousTrack = 5 };

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
        [(NSDictionary *)v enumerateKeysAndObjectsUsingBlock:^(id k, id obj, BOOL *stop) { d[[k description]] = jsonSafe(obj); }];
        return d;
    }
    return [v description];
}

static NSString *digest(NSData *data) {
    unsigned char out[CC_SHA1_DIGEST_LENGTH];
    CC_SHA1(data.bytes, (CC_LONG)data.length, out);
    NSMutableString *s = [NSMutableString string];
    for (int i = 0; i < 8; i++) [s appendFormat:@"%02x", out[i]];
    return s;
}

/// Fetches the current state. `artwork` receives the raw artwork, if any.
static NSDictionary *fetchState(double timeout, NSData **artwork) {
    NSMutableDictionary *out = [NSMutableDictionary dictionary];
    void *h = mr();
    if (!h) { out[@"ok"] = @NO; out[@"error"] = @"dlopen MediaRemote failed"; return out; }
    MRGetInfoFn getInfo = (MRGetInfoFn)dlsym(h, "MRMediaRemoteGetNowPlayingInfo");
    MRGetIsPlayingFn getPlaying = (MRGetIsPlayingFn)dlsym(h, "MRMediaRemoteGetNowPlayingApplicationIsPlaying");
    MRGetPIDFn getPID = (MRGetPIDFn)dlsym(h, "MRMediaRemoteGetNowPlayingApplicationPID");
    dispatch_queue_t q = dispatch_queue_create("np.fetch", DISPATCH_QUEUE_SERIAL);
    dispatch_group_t g = dispatch_group_create();
    __block NSDictionary *info = nil;
    __block NSNumber *playing = nil, *pid = nil;
    if (getInfo) { dispatch_group_enter(g); getInfo(q, ^(CFDictionaryRef d) { info = d ? [(__bridge NSDictionary *)d copy] : nil; dispatch_group_leave(g); }); }
    if (getPlaying) { dispatch_group_enter(g); getPlaying(q, ^(Boolean p) { playing = p ? @YES : @NO; dispatch_group_leave(g); }); }
    if (getPID) { dispatch_group_enter(g); getPID(q, ^(int p) { pid = @(p); dispatch_group_leave(g); }); }
    long timedOut = dispatch_group_wait(g, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(timeout * NSEC_PER_SEC)));
    NSMutableDictionary *clean = nil;
    __block NSData *foundArtwork = nil;
    if (info) {
        clean = [NSMutableDictionary dictionary];
        [info enumerateKeysAndObjectsUsingBlock:^(id k, id v, BOOL *stop) {
            NSString *key = [[k description] stringByReplacingOccurrencesOfString:@"kMRMediaRemoteNowPlayingInfo" withString:@""];
            if ([key isEqualToString:@"ArtworkData"] && [v isKindOfClass:[NSData class]]) foundArtwork = v;
            clean[key] = jsonSafe(v);
        }];
    }
    if (artwork) *artwork = foundArtwork;
    out[@"ok"] = timedOut == 0 ? @YES : @NO;
    out[@"isPlaying"] = playing ?: [NSNull null];
    out[@"pid"] = pid ?: [NSNull null];
    out[@"info"] = clean ?: [NSNull null];
    return out;
}

char *np_fetch_json(double timeoutSeconds) {
    @autoreleasepool {
        NSDictionary *state = fetchState(timeoutSeconds, NULL);
        NSData *data = [NSJSONSerialization dataWithJSONObject:state options:NSJSONWritingSortedKeys error:nil];
        return strdup(data ? (const char *)[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding].UTF8String : "{}");
    }
}

static NSString *lastArtworkKey = nil;

static void emit(const char *event) {
    @autoreleasepool {
        NSData *artwork = nil;
        NSDictionary *state = fetchState(3.0, &artwork);
        NSMutableDictionary *line = [@{@"event": @(event), @"at": @([[NSDate date] timeIntervalSince1970]), @"state": state} mutableCopy];
        NSString *key = artwork.length ? digest(artwork) : nil;
        if (key) line[@"artworkKey"] = key;
        if (key && ![key isEqualToString:lastArtworkKey]) line[@"artwork"] = [artwork base64EncodedStringWithOptions:0];
        lastArtworkKey = key;
        NSData *data = [NSJSONSerialization dataWithJSONObject:line options:0 error:nil];
        if (!data) return;
        fwrite(data.bytes, 1, data.length, stdout);
        fputc('\n', stdout);
        fflush(stdout);
    }
}

static void handleCommand(NSString *line) {
    void *h = mr();
    if (!h) return;
    MRSendCommandFn send = (MRSendCommandFn)dlsym(h, "MRMediaRemoteSendCommand");
    MRSetElapsedFn setElapsed = (MRSetElapsedFn)dlsym(h, "MRMediaRemoteSetElapsedTime");
    NSArray<NSString *> *parts = [[line stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] componentsSeparatedByString:@" "];
    NSString *cmd = parts.firstObject ?: @"";
    if (!send) return;
    if ([cmd isEqualToString:@"toggle"]) send(kMRTogglePlayPause, NULL);
    else if ([cmd isEqualToString:@"play"]) send(kMRPlay, NULL);
    else if ([cmd isEqualToString:@"pause"]) send(kMRPause, NULL);
    else if ([cmd isEqualToString:@"next"]) send(kMRNextTrack, NULL);
    else if ([cmd isEqualToString:@"previous"]) send(kMRPreviousTrack, NULL);
    else if ([cmd isEqualToString:@"seek"] && parts.count > 1 && setElapsed) setElapsed(parts[1].doubleValue);
}

void np_run(void *interp, void *cv) {
    (void)interp; (void)cv;
    const char *modeC = getenv("NP_MODE");
    NSString *mode = modeC ? @(modeC) : @"once";
    if (![mode hasPrefix:@"stream:"]) { emit("once"); exit(0); }
    double seconds = [[mode substringFromIndex:7] doubleValue];

    void *h = mr();
    MRRegisterFn reg = h ? (MRRegisterFn)dlsym(h, "MRMediaRemoteRegisterForNowPlayingNotifications") : NULL;
    if (reg) reg(dispatch_get_main_queue());

    // Several notifications usually arrive together; coalesce them.
    __block dispatch_block_t pending = nil;
    void (^schedule)(const char *) = ^(const char *label) {
        if (pending) dispatch_block_cancel(pending);
        pending = dispatch_block_create(0, ^{ emit(label); });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 120 * NSEC_PER_MSEC), dispatch_get_main_queue(), pending);
    };
    const char *names[] = {
        "kMRMediaRemoteNowPlayingInfoDidChangeNotification",
        "kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification",
        "kMRMediaRemoteNowPlayingApplicationDidChangeNotification",
    };
    for (int i = 0; i < 3; i++) {
        CFStringRef *sym = h ? (CFStringRef *)dlsym(h, names[i]) : NULL;
        NSString *name = sym && *sym ? (__bridge NSString *)*sym : @(names[i]);
        const char *label = names[i] + 24; // drop "kMRMediaRemoteNowPlaying"
        [[NSNotificationCenter defaultCenter] addObserverForName:name object:nil queue:[NSOperationQueue mainQueue]
                                                      usingBlock:^(NSNotification *n) { schedule(label); }];
    }

    // Commands on stdin; EOF means the app went away, so exit.
    dispatch_source_t input = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, STDIN_FILENO, 0, dispatch_get_main_queue());
    __block NSMutableString *buffer = [NSMutableString string];
    dispatch_source_set_event_handler(input, ^{
        char chunk[512];
        ssize_t n = read(STDIN_FILENO, chunk, sizeof chunk);
        if (n <= 0) exit(0);
        [buffer appendString:[[NSString alloc] initWithBytes:chunk length:(NSUInteger)n encoding:NSUTF8StringEncoding] ?: @""];
        NSRange r;
        while ((r = [buffer rangeOfString:@"\n"]).location != NSNotFound) {
            NSString *line = [buffer substringToIndex:r.location];
            [buffer deleteCharactersInRange:NSMakeRange(0, r.location + 1)];
            handleCommand(line);
            schedule("command");
        }
    });
    dispatch_resume(input);

    emit("start");
    if (seconds > 0) {
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, seconds, false);
        emit("end");
        exit(0);
    }
    CFRunLoopRun();
    exit(0);
}
