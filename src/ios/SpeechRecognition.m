//
//  Created by jcesarmobile on 30/11/14.
//  Updates and enhancements by Wayne Fisher (Fisherlea Systems) 2018-2019.
//

// REFERENCE: https://github.com/csdcorp/speech_to_text/blob/main/speech_to_text/ios/Classes/SwiftSpeechToTextPlugin.swift

#import "SpeechRecognition.h"
#import <Speech/Speech.h>

#if 1
#define DBG(a)          NSLog(a)
#define DBG1(a, b)      NSLog(a, b)
#define DBG2(a, b, c)   NSLog(a, b, c)
#else
#define DBG(a)
#define DBG1(a, b)
#define DBG2(a, b, c)
#endif

@implementation SpeechRecognition

const NSNotificationName SpeechSynthesisNotification = @"SPEECHSYNTHESIS.STATECHANGE";

- (void) pluginInitialize {
    
    DBG(@"[sr] pluginInitialize()");
    
    // We need to be notified of route changes to know when a
    // Bluetooth headset becomes active. The audioEngine needs to be
    // re-initialized in this case.
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(routeChanged:) name:AVAudioSessionRouteChangeNotification object:nil];
    
    // Listen for changes from our SpeechSynthesis Controller;
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(handleTalkingNotification:) name:SpeechSynthesisNotification object:nil];
    
    // Configure mode;
    self.sessionCategory = AVAudioSessionCategoryPlayAndRecord;
    /*
     NSString * output = [self.commandDelegate.settings objectForKey:[@"speechRecognitionAllowAudioOutput" lowercaseString]];
     if(output && [output caseInsensitiveCompare:@"true"] == NSOrderedSame) {
        // If the allow audio output preference is set, the need to change the session category.
        // This allows for speech recognition and speech synthesis to be used in the same app.
        self.sessionCategory = AVAudioSessionCategoryPlayAndRecord;
    } else {
        // Maintain the original functionality for backwards compatibility.
        self.sessionCategory = AVAudioSessionCategoryRecord;
    }*/

    self.resetAudioEngine = NO;
    self.audioEngine = [[AVAudioEngine alloc] init];
    self.audioSession = [AVAudioSession sharedInstance];
}

- (void)routeChanged:(NSNotification *)notification {
    BOOL resetAudioEngine = NO;

    NSNumber *reason = [notification.userInfo objectForKey:AVAudioSessionRouteChangeReasonKey];

    DBG(@"[sr] routeChanged()");
    
    AVAudioSessionRouteDescription *route;
    AVAudioSessionPortDescription *port;

    if ([reason unsignedIntegerValue] == AVAudioSessionRouteChangeReasonNewDeviceAvailable) {
        DBG(@"[sr] AVAudioSessionRouteChangeReasonNewDeviceAvailable");
        resetAudioEngine = YES;

        route = self.audioSession.currentRoute;
        if (route.inputs.count > 0) {
            port = route.inputs[0];
            DBG1(@"[sr] New device is %@", port.portType);
        } else {
            DBG(@"[sr] Device removed");
        }
    } else if ([reason unsignedIntegerValue] == AVAudioSessionRouteChangeReasonOldDeviceUnavailable) {
        DBG(@"[sr] AVAudioSessionRouteChangeReasonOldDeviceUnavailable");
        resetAudioEngine = YES;

        route = [notification.userInfo objectForKey:AVAudioSessionRouteChangePreviousRouteKey];
        if (route.inputs.count > 0) {
            port = route.inputs[0];
            DBG1(@"[sr] Removed device %@", port.portType);
            route = self.audioSession.currentRoute;
            port = route.inputs[0];
            DBG1(@"[sr] Now using device %@", port.portType);
        } else {
            DBG(@"[sr] Device removed");
        }
    } else if ([reason unsignedIntegerValue] == AVAudioSessionRouteChangeReasonCategoryChange) {
        DBG(@"[sr] AVAudioSessionRouteChangeReasonCategoryChange");
        
        AVAudioSessionCategory category = [self.audioSession category];
        
        DBG1(@"[sr] AVAudioSession category: %@", category);
        
        if(![category isEqualToString:AVAudioSessionCategoryRecord] &&
           ![category isEqualToString:AVAudioSessionCategoryPlayAndRecord]) {
            if([category isEqualToString:AVAudioSessionCategoryPlayback]) {
                category = AVAudioSessionCategoryPlayAndRecord;
            } else {
                category = self.sessionCategory;
            }
            
            if ([self.audioSession category] != category) {
                [self.audioSession setCategory:category error:nil];
            }
        }
    }

    if(resetAudioEngine) {
        // If a Bluetooth device has been added or removed, we need to
        // re-initialize the audioEngine to adapt to the different
        // sampling rate of the Bluetooth headset (8kHz) vs the mic (44.1kHz).

        DBG(@"[sr] Need to reset audioEngine");
        self.resetAudioEngine = YES;

        // If we are currently running, we need to stop and release the
        // existing recognition tasks. Otherwise, nothing gets received.
        [self stopAndRelease];
    }
}

- (void) init:(CDVInvokedUrlCommand*)command
{
    // This may be called multiple times by different instances of the Javascript SpeechRecognition object.
    DBG(@"[sr] init()");

    self.pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK];
    [self.commandDelegate sendPluginResult:self.pluginResult callbackId:command.callbackId];
}

- (void) start:(CDVInvokedUrlCommand*)command
{
    DBG(@"[sr] start()");
    if (!NSClassFromString(@"SFSpeechRecognizer")) {
        [self sendErrorWithMessage:@"No speech recognizer service available." andCode:4];
        return;
    }

    self.command = command;
    [self sendEvent:(NSString *)@"start"];
    
    if(self.resetAudioEngine) {
        NSLog(@"[sr] Reseting audioEngine");
        self.audioEngine = [self.audioEngine init];
        self.resetAudioEngine = NO;
    }

    [self recognize];
}

- (void) recognize
{
    DBG(@"[sr] recognize()");
    NSString * lang = [self.command argumentAtIndex:0];
    if (lang && [lang isEqualToString:@"en"]) {
        lang = @"en-US";
    }

    if (![self permissionIsSet]) {
        [SFSpeechRecognizer requestAuthorization:^(SFSpeechRecognizerAuthorizationStatus status){
            dispatch_async(dispatch_get_main_queue(), ^{
                if (status == SFSpeechRecognizerAuthorizationStatusAuthorized) {
                    [self recordAndRecognizeWithLang:lang];
                } else {
                    [self sendErrorWithMessage:@"Permission not allowed" andCode:4];
                }
            });
        }];
    } else {
        [self recordAndRecognizeWithLang:lang];
    }
}

- (void) recordAndRecognizeWithLang:(NSString *) lang
{
    DBG1(@"[sr] recordAndRecognizeWithLang(%@)", lang);
    NSLocale *locale = [[NSLocale alloc] initWithLocaleIdentifier:lang];
    if (self.sfSpeechRecognizer != nil) self.sfSpeechRecognizer = nil;
    self.sfSpeechRecognizer = [[SFSpeechRecognizer alloc] initWithLocale:locale];
    if (!self.sfSpeechRecognizer) {
        [self sendErrorWithMessage:@"The language is not supported" andCode:7];
    } else {
        [self startRecognitionProcess];
    }
}

-(void) startRecognitionProcess
{
    DBG(@"[sr] startRecognitionProcess");
    
    // Cancel the previous task if it's running.
    if (self.isSpeaking) {
        DBG(@"[sr] startRecognitionProcess::: isSpeaking:: waiting");
        return;
    } else if (self.recognitionTask) {
        DBG(@"[sr] startRecognitionProcess::: recognitionTask already running");
        [self initAudioSession];
        return;
    }
    [self initAudioSession];
    
    self.recognitionRequest = [[SFSpeechAudioBufferRecognitionRequest alloc] init];
    if (@available(iOS 13, *))
        if (self.sfSpeechRecognizer.supportsOnDeviceRecognition)
            self.recognitionRequest.requiresOnDeviceRecognition = YES;
    self.recognitionRequest.shouldReportPartialResults = true; // [[self.command argumentAtIndex:1] boolValue];
    
    self.speechStartSent = FALSE;
    
    __weak __typeof(self) weakSelf = self;
    self.recognitionTask = [self.sfSpeechRecognizer recognitionTaskWithRequest:self.recognitionRequest resultHandler:^(SFSpeechRecognitionResult *result, NSError *error) {
        
        DBG(@"[sr] startRecognitionProcess::: resultHandler");
        
        if (error) {
            DBG2(@"[sr] resultHandler error (%d) %@", (int) error.code, error.description);
            [weakSelf stopAndRelease];
            [weakSelf sendErrorWithMessage:error.localizedDescription andCode:3];
            return;
        }
        if(!weakSelf.speechStartSent) {
            [weakSelf sendEvent:(NSString *)@"speechstart"];
            weakSelf.speechStartSent = TRUE;
        }
        // Set a timer to send what we got after a nominal time
        if (result) {
            NSMutableArray *alternatives = [[NSMutableArray alloc] init];
            int maxAlternatives = [[weakSelf.command argumentAtIndex:2] intValue];
            for ( SFTranscription *transcription in result.transcriptions ) {
                if (alternatives.count < maxAlternatives) {
                    float confMed = 0, confidence;
                    for ( SFTranscriptionSegment *transcriptionSegment in transcription.segments ) {
                        DBG1(@"[sr] resultHandler transcriptionSegment.confidence %f", transcriptionSegment.confidence);
                        confMed +=transcriptionSegment.confidence;
                    }
                    NSMutableDictionary * resultDict = [[NSMutableDictionary alloc]init];
                    NSString *string = transcription.formattedString;
                    DBG2(@"[sr] resultHandler transcription (final %d): %@", result.isFinal, string);
                    
                    [resultDict setValue:string forKey:@"transcript"];
                    [resultDict setValue:[NSNumber numberWithBool:result.isFinal] forKey:@"final"];
                    if(transcription.segments.count == 0) {
                        DBG(@"[sr] resultHandler *** No transcriptions for result!");
                        confidence = 0;
                    } else {
                        confidence = confMed/transcription.segments.count;
                    }
                    [resultDict setValue:[NSNumber numberWithFloat:confidence] forKey:@"confidence"];
                    [alternatives addObject:resultDict];
                }
            }
            
            // Now send back the results;
            if (weakSelf.timer != nil) {
                [weakSelf.timer invalidate];
                weakSelf.timer = nil;
            }
            if ( result.isFinal ) {
                DBG(@"[sr] resultHandler isFinal, sending results");
                [weakSelf sendRecognitionResults:alternatives];
                [weakSelf stopAndRelease];
            } else {
                DBG(@"[sr] resultHandler setting timer to send results");
                self.timer = [NSTimer scheduledTimerWithTimeInterval:0.75 repeats:NO block:^(NSTimer * _Nonnull timer) {
                    DBG(@"[sr] resultHandler setting timer complete");
                    [timer invalidate];
                    weakSelf.timer = nil;
                    [weakSelf sendRecognitionResults:alternatives];
                    [weakSelf stopAndRelease];
                }];
            }
            
        }
    }];
    
    // Tidy up Tap incase we missed it;
    [self.audioEngine.inputNode removeTapOnBus:0];
    [self.audioEngine reset];
    
    NSError *error = nil;
    if(![self.audioSession setCategory:self.sessionCategory
                                  mode:AVAudioSessionModeMeasurement
                               options:(AVAudioSessionCategoryOptionDefaultToSpeaker|
                                        AVAudioSessionCategoryOptionAllowBluetooth|
                                        AVAudioSessionCategoryOptionAllowBluetoothA2DP)
                                 error:&error]) {
        DBG1(@"[sr] Unable to setCategory: %@", error);
    }
    
    // Get the sampling rate of the input node
    AVAudioFormat *format = [self.audioEngine.inputNode outputFormatForBus:0];
    double hardwareSampleRate = [self.audioSession sampleRate];
    AVAudioFormat *recordingFormat = [[AVAudioFormat alloc] initWithCommonFormat:format.commonFormat
                                                                      sampleRate:hardwareSampleRate
                                                                        channels:format.channelCount
                                                                     interleaved:format.isInterleaved];
    DBG2(@"[sr] recordingFormat: rates: %1f v.s. %1f", hardwareSampleRate, format.sampleRate);
    
    @try {
        [self.audioEngine.inputNode installTapOnBus:0 bufferSize:1024 format:recordingFormat block:^(AVAudioPCMBuffer * _Nonnull buffer, AVAudioTime * _Nonnull when) {
            [self.recognitionRequest appendAudioPCMBuffer:buffer];
        }];
    } @catch (NSException *exception) {
        DBG1(@"[sr] installTapOnBus: exception: %@", exception.reason);
        [self stopAndRelease];
        return;
    }
    [self.audioEngine prepare];
    
    if (![self.audioEngine startAndReturnError:&error]) {
        DBG1(@"[sr] Error: %@", [error localizedDescription]);
        [self sendErrorWithMessage:@"unable to start." andCode:5];
    } else {
        [self sendEvent:(NSString *)@"audiostart"];
    }

}

- (void) sendRecognitionResults:(NSMutableArray *)alternatives
{
    DBG(@"[sr] sendRecognitionResults");
    
    [self sendResults:@[alternatives]];
    if(self.speechStartSent) {
        [self sendEvent:(NSString *)@"speechend"];
        self.speechStartSent = FALSE;
    }
    
    // [self startRecognitionProcess]; // Start a new listener;
    if (self.recognitionTask != nil) {
        [self.recognitionTask cancel];
        self.recognitionTask = nil;
    }
    [self recognize]; // Start a new listener;
}

- (void) initAudioSession
{
    NSError *error;
    DBG(@"[sr] initAudioSession");
    if(self.audioSession && ![self.audioSession setActive:YES withOptions:AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation error:&error]) {
        DBG1(@"[sr] Unable to setActive:YES: %@", error);
    }
}

- (void) deactivateAudioSession
{
    NSError *error;
    DBG(@"[sr] deactivateAudioSession");
    if(self.audioSession && ![self.audioSession setActive:NO withOptions:AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation error:&error]) {
        DBG1(@"[sr] Unable to setActive:NO: %@", error);
    }
}

- (BOOL) permissionIsSet
{
    SFSpeechRecognizerAuthorizationStatus status = [SFSpeechRecognizer authorizationStatus];
    return status != SFSpeechRecognizerAuthorizationStatusNotDetermined;
}

-(void) sendResults:(NSArray *) results
{
    NSMutableDictionary * event = [[NSMutableDictionary alloc]init];
    DBG(@"[sr] sendResults()");
    [event setValue:@"result" forKey:@"type"];
    [event setValue:nil forKey:@"emma"];
    [event setValue:nil forKey:@"interpretation"];
    [event setValue:[NSNumber numberWithInt:0] forKey:@"resultIndex"];
    [event setValue:results forKey:@"results"];

    self.pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsDictionary:event];
    [self.pluginResult setKeepCallbackAsBool:YES];
    [self.commandDelegate sendPluginResult:self.pluginResult callbackId:self.command.callbackId];
    // DBG(@"[sr] sendResults() complete");
}

-(void) sendErrorWithMessage:(NSString *)errorMessage andCode:(NSInteger) code
{
    NSMutableDictionary * event = [[NSMutableDictionary alloc]init];
    DBG2(@"[sr] sendErrorWithMessage: (%d) %@", (int) code, errorMessage);
    [event setValue:@"error" forKey:@"type"];
    [event setValue:[NSNumber numberWithInteger:code] forKey:@"error"];
    [event setValue:errorMessage forKey:@"message"];
    self.pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsDictionary:event];
    [self.pluginResult setKeepCallbackAsBool:NO];
    [self.commandDelegate sendPluginResult:self.pluginResult callbackId:self.command.callbackId];
    // DBG(@"[sr] sendErrorWithMessage() complete");
}

-(void) sendEvent:(NSString *) eventType
{
    NSMutableDictionary * event = [[NSMutableDictionary alloc]init];
    DBG1(@"[sr] sendEvent: %@", eventType);
    [event setValue:eventType forKey:@"type"];
    self.pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsDictionary:event];
    [self.pluginResult setKeepCallbackAsBool:YES];
    [self.commandDelegate sendPluginResult:self.pluginResult callbackId:self.command.callbackId];
    // DBG(@"[sr] sendEvent() complete");
}

-(void) stop:(CDVInvokedUrlCommand*)command
{
    DBG(@"[sr] stop()");
    [self stopOrAbort];
    [self stopAndRelease];
}

-(void) abort:(CDVInvokedUrlCommand*)command
{
    DBG(@"[sr] abort()");
    [self stopOrAbort];
}

-(void) stopOrAbort
{
    DBG(@"[sr] stopOrAbort()");
    if (self.audioEngine.isRunning) {
        [self.audioEngine stop];
        [self.audioEngine.inputNode removeTapOnBus:0];
        [self sendEvent:(NSString *)@"audioend"];

        if(self.recognitionRequest) {
            [self.recognitionRequest endAudio];
        }
    }
}

-(void) stopAndRelease
{
    DBG(@"[sr] stopAndRelease()");
    if (self.audioEngine.isRunning) {
        [self.audioEngine stop];
        [self sendEvent:(NSString *)@"audioend"];
    }
    [self.audioEngine.inputNode removeTapOnBus:0];

    if(self.recognitionRequest) {
        [self.recognitionRequest endAudio];
        self.recognitionRequest = nil;
    }

    if(self.recognitionTask) {
        if(self.recognitionTask.state != SFSpeechRecognitionTaskStateCompleted) {
            [self.recognitionTask cancel];
        }
        self.recognitionTask = nil;
    }

    /* TODO: Disabled for now.
     * Maybe should be performed by HeadsetControl.disconnect???
     * Or maybe allow use of a plugin parameter/option to disable this???
    if(self.audioSession) {
        [self deactivateAudioSession];
    }
    */

    [self sendEvent:(NSString *)@"end"];
}

- (void)handleTalkingNotification:(NSNotification *)notification {
    NSString *state = notification.userInfo[@"state"]; // starting, start, end, pause, resume
    DBG1(@"[sr] handleTalkingNotification: state: %@", state);
    self.isSpeaking = [state isEqualToString:@"start"] || [state isEqualToString:@"resume"] || [state isEqualToString:@"starting"];
    
    // Do we need to stop or start our listener?
    if (!self.audioEngine) {
        DBG(@"[sr] handleTalkingNotification: not active");
    } else if ([state isEqualToString:@"start"] || [state isEqualToString:@"resume"]) {
        // Handle start or resume state
        [self.audioEngine stop];
        if (self.recognitionTask != nil) {
            [self.recognitionTask cancel];
            self.recognitionTask = nil;
        }
    } else if ([state isEqualToString:@"end"] || [state isEqualToString:@"pause"]) {
        // Handle end or pause state
        [self startRecognitionProcess];
    } else {
        DBG1(@"[sr] handleTalkingNotification: Unexpected state: %@", state);
    }
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self name:SpeechSynthesisNotification object:nil];
}

@end
