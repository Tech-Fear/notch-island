// System-wide Now Playing for Notch Island.
//
// Since macOS 15.4 MediaRemote only answers Apple-signed processes, so this library is loaded into
// /usr/bin/perl (see MusicTile.swift). It prints one JSON line per second on stdout and reads
// commands on stdin: "toggle", "next", "prev", "seek <seconds>". It exits when stdin closes.
#import <Foundation/Foundation.h>
#include <dlfcn.h>

typedef void (*GetInfoFn)(dispatch_queue_t, void (^)(CFDictionaryRef));
typedef void (*GetPidFn)(dispatch_queue_t, void (^)(int));
typedef void (*GetPlayingFn)(dispatch_queue_t, void (^)(Boolean));
typedef Boolean (*SendCommandFn)(int, CFDictionaryRef);
typedef void (*SetElapsedFn)(double);

static GetInfoFn getInfo;
static GetPidFn getPid;
static GetPlayingFn getPlaying;
static SendCommandFn sendCommand;
static SetElapsedFn setElapsed;
static NSString *lastArtKey;

enum { kTogglePlayPause = 2, kNextTrack = 4, kPreviousTrack = 5 };

static void emit(NSDictionary *d) {
    NSData *json = [NSJSONSerialization dataWithJSONObject:d options:0 error:nil];
    if (!json) return;
    fwrite(json.bytes, 1, json.length, stdout);
    fputc('\n', stdout);
    fflush(stdout);
}

static void poll(void) {
    dispatch_queue_t q = dispatch_get_main_queue();
    getPid(q, ^(int pid) {
        if (pid <= 0) { lastArtKey = nil; emit(@{@"pid": @0}); return; }
        getPlaying(q, ^(Boolean playing) {
            getInfo(q, ^(CFDictionaryRef ref) {
                NSDictionary *info = (__bridge NSDictionary *)ref;
                NSMutableDictionary *out = [NSMutableDictionary dictionary];
                out[@"pid"] = @(pid);
                out[@"playing"] = @(playing);
                out[@"title"] = info[@"kMRMediaRemoteNowPlayingInfoTitle"] ?: @"";
                out[@"artist"] = info[@"kMRMediaRemoteNowPlayingInfoArtist"] ?: @"";
                out[@"album"] = info[@"kMRMediaRemoteNowPlayingInfoAlbum"] ?: @"";
                out[@"duration"] = info[@"kMRMediaRemoteNowPlayingInfoDuration"] ?: @0;
                out[@"elapsed"] = info[@"kMRMediaRemoteNowPlayingInfoElapsedTime"] ?: @0;
                out[@"rate"] = info[@"kMRMediaRemoteNowPlayingInfoPlaybackRate"] ?: @(playing ? 1 : 0);
                NSDate *ts = info[@"kMRMediaRemoteNowPlayingInfoTimestamp"];
                out[@"at"] = @((ts ?: [NSDate date]).timeIntervalSince1970);
                // Artwork only when the track changes: it can be hundreds of KB.
                NSString *key = [NSString stringWithFormat:@"%d|%@|%@", pid, out[@"title"], out[@"artist"]];
                NSData *art = info[@"kMRMediaRemoteNowPlayingInfoArtworkData"];
                if (art && ![key isEqualToString:lastArtKey]) {
                    out[@"artwork"] = [art base64EncodedStringWithOptions:0];
                    lastArtKey = key;
                }
                emit(out);
            });
        });
    });
}

static void handle(NSString *line) {
    if ([line isEqualToString:@"toggle"]) sendCommand(kTogglePlayPause, NULL);
    else if ([line isEqualToString:@"next"]) sendCommand(kNextTrack, NULL);
    else if ([line isEqualToString:@"prev"]) sendCommand(kPreviousTrack, NULL);
    else if ([line hasPrefix:@"seek "]) setElapsed([[line substringFromIndex:5] doubleValue]);
    poll();
}

// Called from perl as an XSUB; the perl arguments are ignored. Never returns.
void ni_nowplaying(void *perl, void *cv) {
    void *h = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW);
    getInfo = (GetInfoFn)dlsym(h, "MRMediaRemoteGetNowPlayingInfo");
    getPid = (GetPidFn)dlsym(h, "MRMediaRemoteGetNowPlayingApplicationPID");
    getPlaying = (GetPlayingFn)dlsym(h, "MRMediaRemoteGetNowPlayingApplicationIsPlaying");
    sendCommand = (SendCommandFn)dlsym(h, "MRMediaRemoteSendCommand");
    setElapsed = (SetElapsedFn)dlsym(h, "MRMediaRemoteSetElapsedTime");
    if (!getInfo || !getPid || !getPlaying || !sendCommand || !setElapsed) { emit(@{@"error": @"MediaRemote symbols missing"}); exit(1); }

    dispatch_source_t in = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, STDIN_FILENO, 0, dispatch_get_main_queue());
    __block NSMutableData *buf = [NSMutableData data];
    dispatch_source_set_event_handler(in, ^{
        char chunk[1024];
        ssize_t n = read(STDIN_FILENO, chunk, sizeof chunk);
        if (n <= 0) exit(0); // the app quit
        [buf appendBytes:chunk length:n];
        NSString *s = [[NSString alloc] initWithData:buf encoding:NSUTF8StringEncoding];
        NSArray *lines = [s componentsSeparatedByString:@"\n"];
        for (NSUInteger i = 0; i + 1 < lines.count; i++) handle(lines[i]);
        buf = [[lines.lastObject dataUsingEncoding:NSUTF8StringEncoding] mutableCopy];
    });
    dispatch_resume(in);

    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(timer, DISPATCH_TIME_NOW, NSEC_PER_SEC, NSEC_PER_SEC / 10);
    dispatch_source_set_event_handler(timer, ^{ poll(); });
    dispatch_resume(timer);
    dispatch_main();
}
