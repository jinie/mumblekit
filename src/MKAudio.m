// Copyright 2009-2012 The MumbleKit Developers. All rights reserved.
// Use of this source code is governed by a BSD-style
// license that can be found in the LICENSE file.

#import <MumbleKit/MKAudio.h>
#import "MKUtils.h"
#import "MKAudioInput.h"
#import "MKAudioOutput.h"

@interface MKAudio () {
    MKAudioInput     *_audioInput;
    MKAudioOutput    *_audioOutput;
    MKAudioSettings   _audioSettings;
    BOOL              _running;
}

- (id) init;
- (void) dealloc;

@end

#if TARGET_OS_IPHONE == 1
static void MKAudio_InterruptCallback(void *udata, UInt32 interrupt) {
    MKAudio *audio = (MKAudio *) udata;

    if (interrupt == kAudioSessionBeginInterruption) {
        [audio stop];
    } else if (interrupt == kAudioSessionEndInterruption) {
        [audio start];
    }
}

static void MKAudio_AudioInputAvailableCallback(MKAudio *audio, AudioSessionPropertyID prop, UInt32 len, uint32_t *avail) {
    BOOL audioInputAvailable;
    UInt32 val;
    OSStatus err;

    if (avail) {
        audioInputAvailable = *avail;
        val = audioInputAvailable ? kAudioSessionCategory_PlayAndRecord : kAudioSessionCategory_MediaPlayback;
        err = AudioSessionSetProperty(kAudioSessionProperty_AudioCategory, sizeof(val), &val);
        if (err != kAudioSessionNoError) {
            NSLog(@"MKAudio: unable to set AudioCategory property.");
            return;
        }

        if (val == kAudioSessionCategory_PlayAndRecord) {
            val = 1;
            err = AudioSessionSetProperty(kAudioSessionProperty_OverrideCategoryDefaultToSpeaker, sizeof(val), &val);
            if (err != kAudioSessionNoError) {
                NSLog(@"MKAudio: unable to set OverrideCategoryDefaultToSpeaker property.");
                return;
            }
        }

        [audio restart];
    }
}

static void MKAudio_AudioRouteChangedCallback(MKAudio *audio, AudioSessionPropertyID prop, UInt32 len, NSDictionary *dict) {
    NSLog(@"MKAudio: audio route changed.");

}
#endif

@implementation MKAudio

+ (MKAudio *) sharedAudio {
    static dispatch_once_t pred;
    static MKAudio *audio;

    dispatch_once(&pred, ^{
        audio = [[MKAudio alloc] init];
    });

    return audio;
}

- (id) init {
    Float64 fval;
    BOOL audioInputAvailable = YES;

    self = [super init];
    if (self == nil)
        return nil;

#if TARGET_OS_IPHONE == 1
    OSStatus err;
    UInt32 val, valSize;

    // Initialize Audio Session
    err = AudioSessionInitialize(CFRunLoopGetMain(), kCFRunLoopDefaultMode, MKAudio_InterruptCallback, self);
    if (err != kAudioSessionNoError) {
        NSLog(@"MKAudio: unable to initialize AudioSession.");
        return nil;
    }

    // Listen for audio route changes
    err = AudioSessionAddPropertyListener(kAudioSessionProperty_AudioRouteChange,
                                          (AudioSessionPropertyListener)MKAudio_AudioRouteChangedCallback,
                                          self);
    if (err != kAudioSessionNoError) {
        NSLog(@"MKAudio: unable to register property listener for AudioRouteChange.");
        return nil;
    }

    // Listen for audio input availability changes
    err = AudioSessionAddPropertyListener(kAudioSessionProperty_AudioInputAvailable,
                                          (AudioSessionPropertyListener)MKAudio_AudioInputAvailableCallback,
                                          self);
    if (err != kAudioSessionNoError) {
        NSLog(@"MKAudio: unable to register property listener for AudioInputAvailable.");
        return nil;
    }

    // To be able to select the correct category, we must query whethe audio input is available.
    valSize = sizeof(UInt32);
    err = AudioSessionGetProperty(kAudioSessionProperty_AudioInputAvailable, &valSize, &val);
    if (err != kAudioSessionNoError || valSize != sizeof(UInt32)) {
        NSLog(@"MKAudio: unable to query for input availability.");
    }

    // Set the correct category for our Audio Session depending on our current audio input situation.
    audioInputAvailable = (BOOL) val;
    val = audioInputAvailable ? kAudioSessionCategory_PlayAndRecord : kAudioSessionCategory_MediaPlayback;
    err = AudioSessionSetProperty(kAudioSessionProperty_AudioCategory, sizeof(val), &val);
    if (err != kAudioSessionNoError) {
        NSLog(@"MKAudio: unable to set AudioCategory property.");
        return nil;
    }

    if (audioInputAvailable) {
        // The OverrideCategoryDefaultToSpeaker property makes us output to the speakers of the iOS device
        // as long as there's not a headset connected.
        val = TRUE;
        err = AudioSessionSetProperty(kAudioSessionProperty_OverrideCategoryDefaultToSpeaker, sizeof(val), &val);
        if (err != kAudioSessionNoError) {
            NSLog(@"MKAudio: unable to set OverrideCategoryDefaultToSpeaker property.");
            return nil;
        }
    }

    // Do we want to be mixed with other applications?
    val = TRUE;
    err = AudioSessionSetProperty(kAudioSessionProperty_OverrideCategoryMixWithOthers, sizeof(val), &val);
    if (err != kAudioSessionNoError) {
        NSLog(@"MKAudio: unable to set MixWithOthers property.");
        return nil;
    }

     // Set the preferred hardware sample rate.
     //
     // fixme(mkrautz): The AudioSession *can* reject this, in which case we need
     // to be able to handle whatever input sampling rate is chosen for us. This is
     // apparently 8KHz on a 1st gen iPhone.
    fval = SAMPLE_RATE;
    err = AudioSessionSetProperty(kAudioSessionProperty_PreferredHardwareSampleRate, sizeof(Float64), &fval);
    if (err != kAudioSessionNoError) {
        NSLog(@"MKAudio: unable to set preferred hardware sample rate.");
        return nil;
    }

    if (audioInputAvailable) {
        // Allow input from Bluetooth devices.
        val = 1;
        err = AudioSessionSetProperty(kAudioSessionProperty_OverrideCategoryEnableBluetoothInput, sizeof(val), &val);
        if (err != kAudioSessionNoError) {
            NSLog(@"MKAudio: unable to enable bluetooth input.");
            return nil;
        }
    }

#elif TARGET_OS_MAC == 1
    audioInputAvailable = YES;
#endif

    return self;
}

- (void) dealloc {
    [_audioInput release];
    [_audioOutput release];

    [super dealloc];
}

// Get the audio input engine
- (MKAudioInput *) audioInput {
    return _audioInput;
}

// Get the audio output engine
- (MKAudioOutput *) audioOutput {
    return _audioOutput;
}

// Get current audio engine settings
- (MKAudioSettings *) audioSettings {
    return &_audioSettings;
}

// Set new settings for the audio engine
- (void) updateAudioSettings:(MKAudioSettings *)settings {
    memcpy(&_audioSettings, settings, sizeof(MKAudioSettings));
#ifdef ARCH_ARMV6
    // fixme(mkrautz): Unconditionally disable preprocessor for ARMv6
    _audioSettings.enablePreprocessor = NO;
#endif
}

// Has MKAudio been started?
- (BOOL) isRunning {
    return _running;
}

// Stop the audio engine
- (void) stop {
    [_audioInput release];
    _audioInput = nil;
    [_audioOutput release];
    _audioOutput = nil;
#if TARGET_OS_IPHONE == 1
    AudioSessionSetActive(NO);
#endif
    _running = NO;
}

// Start the audio engine
- (void) start {
#if TARGET_OS_IPHONE == 1
    AudioSessionSetActive(YES);
#endif

    _audioInput = [[MKAudioInput alloc] initWithSettings:&_audioSettings];
    _audioOutput = [[MKAudioOutput alloc] initWithSettings:&_audioSettings];
    [_audioInput setupDevice];
    [_audioOutput setupDevice];
    _running = YES;
}

// Restart the audio engine
- (void) restart {
    [self stop];
    [self start];
}

- (void) addFrameToBufferWithSession:(NSUInteger)session data:(NSData *)data sequence:(NSUInteger)seq type:(MKUDPMessageType)msgType {
    [_audioOutput addFrameToBufferWithSession:session data:data sequence:seq type:msgType];
}

- (MKTransmitType) transmitType {
    return _audioSettings.transmitType;
}

- (BOOL) forceTransmit {
    return [_audioInput forceTransmit];
}

- (void) setForceTransmit:(BOOL)flag {
    [_audioInput setForceTransmit:flag];
}

- (NSString *) currentAudioRoute {
#if TARGET_OS_IPHONE == 1
    // Query for the actual sample rate we're to cope with.
    NSString *route;
    UInt32 len = sizeof(NSString *);
    OSStatus err = AudioSessionGetProperty(kAudioSessionProperty_AudioRoute, &len, &route);
    if (err != kAudioSessionNoError) {
        NSLog(@"MKAudio: unable to query for current audio route.");
        return @"Unknown";
    }
    return route;
#else
    return @"Unknown";
#endif
}

- (float) speechProbablity {
    return [_audioInput speechProbability];
}

- (float) peakCleanMic {
    return [_audioInput peakCleanMic];
}

- (void) setSelfMuted:(BOOL)selfMuted {
    [_audioInput setSelfMuted:selfMuted];
}

- (void) setSuppressed:(BOOL)suppressed {
    [_audioInput setSuppressed:suppressed];
}

- (void) setMuted:(BOOL)muted {
    [_audioInput setMuted:muted];
}

@end
