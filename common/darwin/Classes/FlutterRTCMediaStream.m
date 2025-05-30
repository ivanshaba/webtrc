#import <objc/runtime.h>
#import "AudioUtils.h"
#import "CameraUtils.h"
#import "FlutterRTCFrameCapturer.h"
#import "FlutterRTCMediaStream.h"
#import "FlutterRTCPeerConnection.h"
#import "VideoProcessingAdapter.h"
#import "LocalVideoTrack.h"
#import "LocalAudioTrack.h"

@implementation RTCMediaStreamTrack (Flutter)

- (id)settings {
  return objc_getAssociatedObject(self, _cmd);
}

- (void)setSettings:(id)settings {
  objc_setAssociatedObject(self, @selector(settings), settings, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}
@end

@implementation AVCaptureDevice (Flutter)

- (NSString*)positionString {
  switch (self.position) {
    case AVCaptureDevicePositionUnspecified:
      return @"unspecified";
    case AVCaptureDevicePositionBack:
      return @"back";
    case AVCaptureDevicePositionFront:
      return @"front";
  }
  return nil;
}

@end

@implementation FlutterWebRTCPlugin (RTCMediaStream)

/**
 * {@link https://www.w3.org/TR/mediacapture-streams/#navigatorusermediaerrorcallback}
 */
typedef void (^NavigatorUserMediaErrorCallback)(NSString* errorType, NSString* errorMessage);

/**
 * {@link https://www.w3.org/TR/mediacapture-streams/#navigatorusermediasuccesscallback}
 */
typedef void (^NavigatorUserMediaSuccessCallback)(RTCMediaStream* mediaStream);

- (NSDictionary*)defaultVideoConstraints {
    return @{@"minWidth" : @"1280", @"minHeight" : @"720", @"minFrameRate" : @"30"};
}

- (NSDictionary*)defaultAudioConstraints {
    return @{};
}

- (RTCMediaConstraints*)defaultMediaStreamConstraints {
  RTCMediaConstraints* constraints =
      [[RTCMediaConstraints alloc] initWithMandatoryConstraints:[self defaultVideoConstraints]
                                            optionalConstraints:nil];
  return constraints;
}

- (NSArray<AVCaptureDevice*> *)captureDevices {
    if (@available(iOS 13.0, macOS 10.15, macCatalyst 14.0, *)) {
        NSMutableArray<AVCaptureDeviceType> *deviceTypes = [NSMutableArray arrayWithObjects:
#if TARGET_OS_IPHONE
            AVCaptureDeviceTypeBuiltInTripleCamera,
            AVCaptureDeviceTypeBuiltInDualCamera,
            AVCaptureDeviceTypeBuiltInDualWideCamera,
            AVCaptureDeviceTypeBuiltInWideAngleCamera,
            AVCaptureDeviceTypeBuiltInTelephotoCamera,
            AVCaptureDeviceTypeBuiltInUltraWideCamera,
#else
            AVCaptureDeviceTypeBuiltInWideAngleCamera,
#endif
            nil];
        
#if !defined(TARGET_OS_IPHONE)
        if (@available(macOS 13.0, *)) {
            [deviceTypes addObject:AVCaptureDeviceTypeDeskViewCamera];
        }
#endif

        return [AVCaptureDeviceDiscoverySession discoverySessionWithDeviceTypes:deviceTypes
                                                                      mediaType:AVMediaTypeVideo
                                                                       position:AVCaptureDevicePositionUnspecified].devices;
    }
    return @[];
}

/**
 * Initializes a new {@link RTCAudioTrack} which satisfies specific constraints,
 * adds it to a specific {@link RTCMediaStream}, and reports success to a
 * specific callback. Implements the audio-specific counterpart of the
 * {@code getUserMedia()} algorithm.
 */
- (void)getUserAudio:(NSDictionary*)constraints
     successCallback:(NavigatorUserMediaSuccessCallback)successCallback
       errorCallback:(NavigatorUserMediaErrorCallback)errorCallback
         mediaStream:(RTCMediaStream*)mediaStream {
  id audioConstraints = constraints[@"audio"];
  NSString* audioDeviceId = @"";
  RTCMediaConstraints *rtcConstraints;
  if ([audioConstraints isKindOfClass:[NSDictionary class]]) {
    NSString* deviceId = audioConstraints[@"deviceId"];

    if (deviceId) {
      audioDeviceId = deviceId;
    }

    rtcConstraints = [self parseMediaConstraints:audioConstraints];
    id optionalConstraints = audioConstraints[@"optional"];
    if (optionalConstraints && [optionalConstraints isKindOfClass:[NSArray class]] &&
        !deviceId) {
      NSArray* options = optionalConstraints;
      for (id item in options) {
        if ([item isKindOfClass:[NSDictionary class]]) {
          NSString* sourceId = ((NSDictionary*)item)[@"sourceId"];
          if (sourceId) {
            audioDeviceId = sourceId;
          }
        }
      }
    }
  } else {
      rtcConstraints = [self parseMediaConstraints:[self defaultAudioConstraints]];
  }

#if !defined(TARGET_OS_IPHONE)
  if (audioDeviceId != nil) {
    [self selectAudioInput:audioDeviceId result:nil];
  }
#endif

  NSString* trackId = [[NSUUID UUID] UUIDString];
  RTCAudioSource *audioSource = [self.peerConnectionFactory audioSourceWithConstraints:rtcConstraints];
  RTCAudioTrack* audioTrack = [self.peerConnectionFactory audioTrackWithSource:audioSource trackId:trackId];
  LocalAudioTrack *localAudioTrack = [[LocalAudioTrack alloc] initWithTrack:audioTrack];

  audioTrack.settings = @{
    @"deviceId" : audioDeviceId,
    @"kind" : @"audioinput",
    @"autoGainControl" : @YES,
    @"echoCancellation" : @YES,
    @"noiseSuppression" : @YES,
    @"channelCount" : @1,
    @"latency" : @0,
  };

  [mediaStream addAudioTrack:audioTrack];

  [self.localTracks setObject:localAudioTrack forKey:trackId];

  [self ensureAudioSession];

  successCallback(mediaStream);
}

- (void)getUserMedia:(NSDictionary*)constraints result:(FlutterResult)result {
  NSString* mediaStreamId = [[NSUUID UUID] UUIDString];
  RTCMediaStream* mediaStream = [self.peerConnectionFactory mediaStreamWithStreamId:mediaStreamId];

  [self getUserMedia:constraints
      successCallback:^(RTCMediaStream* mediaStream) {
        NSString* mediaStreamId = mediaStream.streamId;

        NSMutableArray* audioTracks = [NSMutableArray array];
        NSMutableArray* videoTracks = [NSMutableArray array];

        for (RTCAudioTrack* track in mediaStream.audioTracks) {
          [audioTracks addObject:@{
            @"id" : track.trackId,
            @"kind" : track.kind,
            @"label" : track.trackId,
            @"enabled" : @(track.isEnabled),
            @"remote" : @(YES),
            @"readyState" : @"live",
            @"settings" : track.settings
          }];
        }

        for (RTCVideoTrack* track in mediaStream.videoTracks) {
          [videoTracks addObject:@{
            @"id" : track.trackId,
            @"kind" : track.kind,
            @"label" : track.trackId,
            @"enabled" : @(track.isEnabled),
            @"remote" : @(YES),
            @"readyState" : @"live",
            @"settings" : track.settings
          }];
        }

        self.localStreams[mediaStreamId] = mediaStream;
        result(@{
          @"streamId" : mediaStreamId,
          @"audioTracks" : audioTracks,
          @"videoTracks" : videoTracks
        });
      }
      errorCallback:^(NSString* errorType, NSString* errorMessage) {
        result([FlutterError errorWithCode:[NSString stringWithFormat:@"Error %@", errorType]
                                   message:errorMessage
                                   details:nil]);
      }
      mediaStream:mediaStream];
}

- (void)getUserMedia:(NSDictionary*)constraints
     successCallback:(NavigatorUserMediaSuccessCallback)successCallback
       errorCallback:(NavigatorUserMediaErrorCallback)errorCallback
         mediaStream:(RTCMediaStream*)mediaStream {
  if (mediaStream.audioTracks.count == 0) {
    id audioConstraints = constraints[@"audio"];
    BOOL constraintsIsDictionary = [audioConstraints isKindOfClass:[NSDictionary class]];
    if (audioConstraints && (constraintsIsDictionary || [audioConstraints boolValue])) {
      [self requestAccessForMediaType:AVMediaTypeAudio
                          constraints:constraints
                      successCallback:successCallback
                        errorCallback:errorCallback
                          mediaStream:mediaStream];
      return;
    }
  }

  if (mediaStream.videoTracks.count == 0) {
    id videoConstraints = constraints[@"video"];
    if (videoConstraints) {
      BOOL requestAccessForVideo = [videoConstraints isKindOfClass:[NSNumber class]]
                                       ? [videoConstraints boolValue]
                                       : [videoConstraints isKindOfClass:[NSDictionary class]];
#if !TARGET_IPHONE_SIMULATOR
      if (requestAccessForVideo) {
        [self requestAccessForMediaType:AVMediaTypeVideo
                            constraints:constraints
                        successCallback:successCallback
                          errorCallback:errorCallback
                            mediaStream:mediaStream];
        return;
      }
#endif
    }
  }

  successCallback(mediaStream);
}

- (int)getConstrainInt:(NSDictionary*)constraints forKey:(NSString*)key {
  if (![constraints isKindOfClass:[NSDictionary class]]) {
    return 0;
  }

  id constraint = constraints[key];
  if ([constraint isKindOfClass:[NSNumber class]]) {
    return [constraint intValue];
  } else if ([constraint isKindOfClass:[NSString class]]) {
    int possibleValue = [constraint intValue];
    if (possibleValue != 0) {
      return possibleValue;
    }
  } else if ([constraint isKindOfClass:[NSDictionary class]]) {
    id idealConstraint = constraint[@"ideal"];
    if ([idealConstraint isKindOfClass:[NSString class]]) {
      int possibleValue = [idealConstraint intValue];
      if (possibleValue != 0) {
        return possibleValue;
      }
    }
  }

  return 0;
}

/**
 * Initializes a new {@link RTCVideoTrack} which satisfies specific constraints,
 * adds it to a specific {@link RTCMediaStream}, and reports success to a
 * specific callback. Implements the video-specific counterpart of the
 * {@code getUserMedia()} algorithm.
 */
- (void)getUserVideo:(NSDictionary*)constraints
     successCallback:(NavigatorUserMediaSuccessCallback)successCallback
       errorCallback:(NavigatorUserMediaErrorCallback)errorCallback
         mediaStream:(RTCMediaStream*)mediaStream {
  id videoConstraints = constraints[@"video"];
  AVCaptureDevice* videoDevice;
  NSString* videoDeviceId = nil;
  NSString* facingMode = nil;
  NSArray<AVCaptureDevice*>* captureDevices = [self captureDevices];

  if ([videoConstraints isKindOfClass:[NSDictionary class]]) {
    NSString* deviceId = videoConstraints[@"deviceId"];

    if (deviceId) {
        for (AVCaptureDevice *device in captureDevices) {
            if( [deviceId isEqualToString:device.uniqueID]) {
                videoDevice = device;
                videoDeviceId = deviceId;
            }
        }
    }

    id optionalVideoConstraints = videoConstraints[@"optional"];
    if (optionalVideoConstraints && [optionalVideoConstraints isKindOfClass:[NSArray class]] &&
        !videoDevice) {
      NSArray* options = optionalVideoConstraints;
      for (id item in options) {
        if ([item isKindOfClass:[Dictionary class]]) {
          NSString* sourceId = ((NSDictionary*)item)[@"sourceId"];
          if (sourceId) {
              for (AVCaptureDevice *device in captureDevices) {
                  if( [sourceId isEqualToString:device.uniqueID]) {
                      videoDevice = device;
                      videoDeviceId = sourceId;
                  }
              }
            if (videoDevice) {
              break;
            }
          }
        }
      }
    }

    if (!videoDevice) {
      facingMode = videoConstraints[@"facingMode"];
      if (facingMode && [facingMode isKindOfClass:[NSString class]]) {
        AVCaptureDevicePosition position;
        if ([facingMode isEqualToString:@"environment"]) {
          self._usingFrontCamera = NO;
          position = AVCaptureDevicePositionBack;
        } else if ([facingMode isEqualToString:@"user"]) {
          self._usingFrontCamera = YES;
          position = AVCaptureDevicePositionFront;
        } else {
          self._usingFrontCamera = NO;
          position = AVCaptureDevicePositionUnspecified;
        }
        videoDevice = [self findDeviceForPosition:position];
      }
    }
  }

  if ([videoConstraints isKindOfClass:[NSNumber class]]) {
    videoConstraints = @{@"mandatory": [self defaultVideoConstraints]};
  }

  NSInteger targetWidth = 0;
  NSInteger targetHeight = 0;
  NSInteger targetFps = 0;

  if (!videoDevice) {
    videoDevice = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeVideo];
  }

  int possibleWidth = [self getConstrainInt:videoConstraints forKey:@"width"];
  if (possibleWidth != 0) {
    targetWidth = possibleWidth;
  }

  int possibleHeight = [self getConstrainInt:videoConstraints forKey:@"height"];
  if (possibleHeight != 0) {
    targetHeight = possibleHeight;
  }

  int possibleFps = [self getConstrainInt:videoConstraints forKey:@"frameRate"];
  if (possibleFps != 0) {
    targetFps = possibleFps;
  }

  id mandatory =
      [videoConstraints isKindOfClass:[Dictionary class]] ? videoConstraints[@"mandatory"] : nil;

  if (mandatory && [mandatory isKindOfClass:[Dictionary class]]) {
    id widthConstraint = mandatory[@"minWidth"];
    if ([widthConstraint isKindOfClass:[NSString class]] ||
        [widthConstraint isKindOfClass:[NSNumber class]]) {
      int possibleWidth = [widthConstraint intValue];
      if (possibleWidth != 0) {
        targetWidth = possibleWidth;
      }
    }
    id heightConstraint = mandatory[@"minHeight"];
    if ([heightConstraint isKindOfClass:[NSString class]] ||
        [heightConstraint isKindOfClass:[NSNumber class]]) {
      int possibleHeight = [heightConstraint intValue];
      if (possibleHeight != 0) {
        targetHeight = possibleHeight;
      }
    }
    id fpsConstraint = mandatory[@"minFrameRate"];
    if ([fpsConstraint isKindOfClass:[NSString class]] ||
        [fpsConstraint isKindOfClass:[NSNumber class]]) {
      int possibleFps = [fpsConstraint intValue];
      if (possibleFps != 0) {
        targetFps = possibleFps;
      }
    }
  }

  if (videoDevice) {
    RTCVideoSource* videoSource = [self.peerConnectionFactory videoSource];
#if TARGET_OS_OSX
    if (self.videoCapturer) {
      [self.videoCapturer stopCapture];
    }
#endif
      
    VideoProcessingAdapter *videoProcessingAdapter = [[VideoProcessingAdapter alloc] initWithRTCVideoSource:videoSource];
    self.videoCapturer = [[RTCCameraVideoCapturer alloc] initWithDelegate:videoProcessingAdapter];
      
    AVCaptureDeviceFormat* selectedFormat = [self selectFormatForDevice:videoDevice
                                                            targetWidth:targetWidth
                                                           targetHeight:targetHeight];

    CMVideoDimensions selectedDimension = CMVideoFormatDescriptionGetDimensions(selectedFormat.formatDescription);
    NSInteger selectedWidth = (NSInteger) selectedDimension.width;
    NSInteger selectedHeight = (NSInteger) selectedDimension.height;
    NSInteger selectedFps = [self selectFpsForFormat:selectedFormat targetFps:targetFps];

    self._lastTargetFps = selectedFps;
    self._lastTargetWidth = targetWidth;
    self._lastTargetHeight = targetHeight;
    
    NSLog(@"target format %ldx%ld, targetFps: %ld, selected format: %ldx%ld, selected fps %ld", targetWidth, targetHeight, targetFps, selectedWidth, selectedHeight, selectedFps);

    if ([videoDevice lockForConfiguration:NULL]) {
      @try {
        videoDevice.activeVideoMaxFrameDuration = CMTimeMake(1, (int32_t)selectedFps);
        videoDevice.activeVideoMinFrameDuration = CMTimeMake(1, (int32_t)selectedFps);
      } @catch (NSException* exception) {
        NSLog(@"Failed to set active frame rate!\n User info:%@", exception.userInfo);
      }
      [videoDevice unlockForConfiguration];
    }

    [self.videoCapturer startCaptureWithDevice:videoDevice
                                        format:selectedFormat
                                           fps:selectedFps
                             completionHandler:^(NSError* error) {
                               if (error) {
                                 NSLog(@"Start capture error: %@", [error localizedDescription]);
                               }
                             }];

    NSString* trackUUID = [[NSUUID UUID] UUIDString];
    RTCVideoTrack* videoTrack = [self.peerConnectionFactory videoTrackWithSource:videoSource
                                                                        trackId:trackUUID];
    LocalVideoTrack *localVideoTrack = [[LocalVideoTrack alloc] initWithTrack:videoTrack videoProcessing:videoProcessingAdapter];
      
    __weak RTCCameraVideoCapturer* capturer = self.videoCapturer;
    self.videoCapturerStopHandlers[videoTrack.trackId] = ^(CompletionHandler handler) {
      NSLog(@"Stop video capturer, trackID %@", videoTrack.trackId);
      [capturer stopCaptureWithCompletionHandler:handler];
    };

    if (!videoDeviceId) {
      videoDeviceId = videoDevice.uniqueID;
    }

    if (!facingMode) {
      facingMode = videoDevice.position == AVCaptureDevicePositionBack    ? @"environment"
                   : videoDevice.position == AVCaptureDevicePositionFront ? @"user"
                                                                          : @"unspecified";
    }

    videoTrack.settings = @{
      @"deviceId" : videoDeviceId,
      @"kind" : @"videoinput",
      @"width" : [NSNumber numberWithInteger:selectedWidth],
      @"height" : [NSNumber numberWithInteger:selectedHeight],
      @"frameRate" : [NSNumber numberWithInteger:selectedFps],
      @"facingMode" : facingMode,
    };

    [mediaStream addVideoTrack:videoTrack];

    [self.localTracks setObject:localVideoTrack forKey:trackUUID];

    successCallback(mediaStream);
  } else {
    errorCallback(@"OverconstrainedError", nil);
  }
}

- (void)mediaStreamRelease:(RTCMediaStream*)stream {
  if (stream) {
    for (RTCVideoTrack* track in stream.videoTracks) {
      [self.localTracks removeObjectForKey:track.trackId];
    }
    for (RTCAudioTrack* track in stream.audioTracks) {
      [self.localTracks removeObjectForKey:track.trackId];
    }
    [self.localStreams removeObjectForKey:stream.streamId];
  }
}

- (void)requestAccessForMediaType:(NSString*)mediaType
                      constraints:(Dictionary*)constraints
                  successCallback:(NavigatorUserMediaSuccessCallback)successCallback
                    errorCallback:(NavigatorUserMediaErrorCallback)errorCallback
                      mediaStream:(RTCMediaStream*)mediaStream {
  if (mediaType == AVMediaTypeVideo && [self captureDevices].count == 0) {
    dispatch_async(dispatch_get_main_queue(), ^{
      errorCallback(@"DOMException", @"NotFoundError");
    });
    return;
  }

#if TARGET_OS_OSX
  if (@available(macOS 10.14, *)) {
#endif
    [AVCaptureDevice requestAccessForMediaType:mediaType
                             completionHandler:^(BOOL granted) {
                               dispatch_async(dispatch_get_main_queue(), ^{
                                 if (granted) {
                                   NavigatorUserMediaSuccessCallback scb =
                                       ^(RTCMediaStream* mediaStream) {
                                         [self getUserMedia:constraints
                                             successCallback:successCallback
                                               errorCallback:errorCallback
                                                 mediaStream:mediaStream];
                                       };

                                   if (mediaType == AVMediaTypeAudio) {
                                     [self getUserAudio:constraints
                                         successCallback:scb
                                           errorCallback:errorCallback
                                             mediaStream:mediaStream];
                                   } else if (mediaType == AVMediaTypeVideo) {
                                     [self getUserVideo:constraints
                                         successCallback:scb
                                           errorCallback:errorCallback
                                             mediaStream:mediaStream];
                                   }
                                 } else {
                                   errorCallback(@"DOMException", @"NotAllowedError");
                                 }
                               });
                             }];
#if TARGET_OS_OSX
  } else {
    NavigatorUserMediaSuccessCallback scb = ^(RTCMediaStream* mediaStream) {
      [self getUserMedia:constraints
          successCallback:successCallback
            errorCallback:errorCallback
              mediaStream:mediaStream];
    };
    if (mediaType == AVMediaTypeAudio) {
      [self getUserAudio:constraints
          successCallback:scb
            errorCallback:errorCallback
              mediaStream:mediaStream];
    } else if (mediaType == AVMediaTypeVideo) {
      [self getUserVideo:constraints
          successCallback:scb
            errorCallback:errorCallback
              mediaStream:mediaStream];
    }
  }
#endif
}

- (void)createLocalMediaStream:(FlutterResult)result {
  NSString* mediaStreamId = [[NSUUID UUID] UUIDString];
  RTCMediaStream* mediaStream = [self.peerConnectionFactory mediaStreamWithStreamId:mediaStreamId];

  self.localStreams[mediaStreamId] = mediaStream;
  result(@{@"streamId" : [mediaStream streamId]});
}

- (void)getSources:(FlutterResult)result {
  NSMutableArray* sources = [NSMutableArray array];
  NSArray* videoDevices =  [self captureDevices];
  for (AVCaptureDevice* device in videoDevices) {
    [sources addObject:@{
      @"facing" : device.positionString,
      @"deviceId" : device.uniqueID,
      @"label" : device.localizedName,
      @"kind" : @"videoinput",
    }];
  }
#if TARGET_OS_IPHONE

  RTCAudioSession* session = [RTCAudioSession sharedInstance];
  for (AVAudioSessionPortDescription* port in session.session.availableInputs) {
    [sources addObject:@{
      @"deviceId" : port.UID,
      @"label" : port.portName,
      @"groupId" : port.portType,
      @"kind" : @"audioinput",
    }];
  }

  for (AVAudioSessionPortDescription* port in session.currentRoute.outputs) {
    if (session.currentRoute.outputs.count == 1 && ![port.UID isEqualToString:@"Speaker"]) {
      [sources addObject:@{
        @"deviceId" : @"Speaker",
        @"label" : @"Speaker",
        @"groupId" : @"Speaker",
        @"kind" : @"audiooutput",
      }];
    }
    [sources addObject:@{
      @"deviceId" : port.UID,
      @"label" : port.portName,
      @"groupId" : port.portType,
      @"kind" : @"audiooutput",
    }];
  }
#endif
#if TARGET_OS_OSX
  RTCAudioDeviceModule* audioDeviceModule = [self.peerConnectionFactory audioDeviceModule];

  NSArray* inputDevices = [audioDeviceModule inputDevices];
  for (RTCIODevice* device in inputDevices) {
    [sources addObject:@{
      @"deviceId" : device.deviceId,
      @"label" : device.name,
      @"kind" : @"audioinput",
    }];
  }

  NSArray* outputDevices = [audioDeviceModule outputDevices];
  for (RTCIODevice* device in outputDevices) {
    [sources addObject:@{
      @"deviceId" : device.deviceId,
      @"label" : device.name,
      @"kind" : @"audiooutput",
    }];
  }
#endif
  result(@{@"sources" : sources});
}

- (void)selectAudioInput:(NSString*)deviceId result:(FlutterResult)result {
#if TARGET_OS_OSX
  RTCAudioDeviceModule* audioDeviceModule = [self.peerConnectionFactory audioDeviceModule];
  NSArray* inputDevices = [audioDeviceModule inputDevices];
  for (RTCIODevice* device in inputDevices) {
    if ([deviceId isEqualToString:device.deviceId]) {
      [audioDeviceModule setInputDevice:device];
      if (result)
        result(nil);
      return;
    }
  }
#endif
#if TARGET_OS_IPHONE
  RTCAudioSession* session = [RTCAudioSession sharedInstance];
  for (AVAudioSessionPortDescription* port in session.session.availableInputs) {
    if ([port.UID isEqualToString:deviceId]) {
      if (self.preferredInput != port.portType) {
        self.preferredInput = port.portType;
        [AudioUtils selectAudioInput:self.preferredInput];
      }
      break;
    }
  }
  if (result)
    result(nil);
#endif
  if (result)
    result([FlutterError errorWithCode:@"selectAudioInputFailed"
                               message:[NSString stringWithFormat:@"Error: deviceId not found!"]
                               details:nil]);
}

- (void)selectAudioOutput:(NSString*)deviceId result:(FlutterResult)result {
#if TARGET_OS_OSX
  RTCAudioDeviceModule* audioDeviceModule = [self.peerConnectionFactory audioDeviceModule];
  NSArray* outputDevices = [audioDeviceModule outputDevices];
  for (RTCIODevice* device in outputDevices) {
    if ([deviceId isEqualToString:device.deviceId]) {
      [audioDeviceModule setOutputDevice:device];
      result(nil);
      return;
    }
  }
#endif
#if TARGET_OS_IPHONE
  RTCAudioSession* session = [RTCAudioSession sharedInstance];
  NSError* setCategoryError = nil;

  if ([deviceId isEqualToString:@"Speaker"]) {
    [session.session overrideOutputAudioPort:kAudioSessionOverrideAudioRoute_Speaker
                                       error:&setCategoryError];
  } else {
    [session.session overrideOutputAudioPort:kAudioSessionOverrideAudioRoute_None
                                       error:&setCategoryError];
  }

  if (setCategoryError == nil) {
    result(nil);
    return;
  }

  result([FlutterError
      errorWithCode:@"selectAudioOutputFailed"
            message:[NSString
                        stringWithFormat:@"Error: %@", [setCategoryError localizedFailureReason]]
            details:nil]);

#endif
  result([FlutterError errorWithCode:@"selectAudioOutputFailed"
                             message:[NSString stringWithFormat:@"Error: deviceId not found!"]
                             details:nil]);
}

- (void)mediaStreamTrackRelease:(RTCMediaStream*)mediaStream track:(RTCMediaStreamTrack*)track {
  if (mediaStream && track) {
    track.isEnabled = NO;
    if ([track.kind isEqualToString:@"audio"]) {
      [mediaStream removeAudioTrack:(RTCAudioTrack*)track];
    } else if ([track.kind isEqualToString:@"video"]) {
      [mediaStream removeVideoTrack:(RTCVideoTrack*)track];
    }
  }
}

- (void)mediaStreamTrackHasTorch:(RTCMediaStreamTrack*)track result:(FlutterResult)result {
  if (!self.videoCapturer) {
    result(@NO);
    return;
  }
  if (self.videoCapturer.captureSession.inputs.count == 0) {
    result(@NO);
    return;
  }

  AVCaptureDeviceInput* deviceInput = [self.videoCapturer.captureSession.inputs objectAtIndex:0];
  AVCaptureDevice* device = deviceInput.device;

  result(@([device isTorchModeSupported:AVCaptureTorchModeOn]));
}

- (void)mediaStreamTrackSetTorch:(RTCMediaStreamTrack*)track
                           torch:(BOOL)torch
                          result:(FlutterResult)result {
  if (!self.videoCapturer) {
    NSLog(@"Video capturer is null. Can't set torch");
    return;
  }
  if (self.videoCapturer.captureSession.inputs.count == 0) {
    NSLog(@"Video capturer is missing an input. Can't set torch");
    return;
  }

  AVCaptureDeviceInput* deviceInput = [self.videoCapturer.captureSession.inputs objectAtIndex:0];
  AVCaptureDevice* device = deviceInput.device;

  if (![device isTorchModeSupported:AVCaptureTorchModeOn]) {
    NSLog(@"Current capture device does not support torch. Can't set torch");
    return;
  }

  NSError* error;
  if ([device lockForConfiguration:&error] == NO) {
    NSLog(@"Failed to aquire configuration lock. %@", error.localizedDescription);
    return;
  }

  device.torchMode = torch ? AVCaptureTorchModeOn : AVCaptureTorchModeOff;
  [device unlockForConfiguration];

  result(nil);
}

- (void)mediaStreamTrackSetZoom:(RTCMediaStreamTrack*)track
                           zoomLevel:(double)zoomLevel
                          result:(FlutterResult)result {
#if TARGET_OS_OSX
  NSLog(@"Not supported on macOS. Can't set zoom");
  return;
#endif
#if TARGET_OS_IPHONE
  if (!self.videoCapturer) {
    NSLog(@"Video capturer is null. Can't set zoom");
    return;
  }
  if (self.videoCapturer.captureSession.inputs.count == 0) {
    NSLog(@"Video capturer is missing an input. Can't set zoom");
    return;
  }

  AVCaptureDeviceInput* deviceInput = [self.videoCapturer.captureSession.inputs objectAtIndex:0];
  AVCaptureDevice* device = deviceInput.device;

  NSError* error;
  if ([device lockForConfiguration:&error] == NO) {
    NSLog(@"Failed to acquire configuration lock. %@", error.localizedDescription);
    return;
  }
  
  CGFloat desiredZoomFactor = (CGFloat)zoomLevel;
  device.videoZoomFactor = MAX(1.0, MIN(desiredZoomFactor, device.activeFormat.videoMaxZoomFactor));
  [device unlockForConfiguration];

  result(nil);
#endif
}

- (void)mediaStreamTrackCaptureFrame:(RTCVideoTrack*)track
                              toPath:(NSString*)path
                              result:(FlutterResult)result {
  self.frameCapturer = [[FlutterRTCFrameCapturer alloc] initWithTrack:track
                                                               toPath:path
                                                               result:result];
}

- (void)mediaStreamTrackStop:(RTCMediaStreamTrack*)track {
  if (track) {
    track.isEnabled = NO;
    [self.localTracks removeObjectForKey:track.trackId];
  }
}

- (AVCaptureDevice*)findDeviceForPosition:(AVCaptureDevicePosition)position {
  if (position == AVCaptureDevicePositionUnspecified) {
    return [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeVideo];
  }
  NSArray<AVCaptureDevice*>* captureDevices = [RTCCameraVideoCapturer captureDevices];
  for (AVCaptureDevice* device in captureDevices) {
    if (device.position == position) {
      return device;
    }
  }
  if(captureDevices.count > 0) {
    return captureDevices[0];
  }
  return nil;
}

- (AVCaptureDeviceFormat*)selectFormatForDevice:(AVCaptureDevice*)device
                                    targetWidth:(NSInteger)targetWidth
                                   targetHeight:(NSInteger)targetHeight {
  NSArray<AVCaptureDeviceFormat*>* formats =
      [RTCCameraVideoCapturer supportedFormatsForDevice:device];
  AVCaptureDeviceFormat* selectedFormat = nil;
  long currentDiff = INT_MAX;
  for (AVCaptureDeviceFormat* format in formats) {
    CMVideoDimensions dimension = CMVideoFormatDescriptionGetDimensions(format.formatDescription);
    FourCharCode pixelFormat = CMFormatDescriptionGetMediaSubType(format.formatDescription);
#if TARGET_OS_IPHONE
    if (@available(iOS 13.0, *)) {
      if(format.isMultiCamSupported != AVCaptureMultiCamSession.multiCamSupported) {
        continue;
      }
    }
#endif
    long diff = labs(targetWidth - dimension.width) + labs(targetHeight - dimension.height);
    if (diff < currentDiff) {
      selectedFormat = format;
      currentDiff = diff;
    } else if (diff == currentDiff &&
               pixelFormat == [self.videoCapturer preferredOutputPixelFormat]) {
      selectedFormat = format;
    }
  }
  return selectedFormat;
}

- (NSInteger)selectFpsForFormat:(AVCaptureDeviceFormat*)format targetFps:(NSInteger)targetFps {
  Float64 maxSupportedFramerate = 0;
  for (AVFrameRateRange* fpsRange in format.videoSupportedFrameRateRanges) {
    maxSupportedFramerate = fmax(maxSupportedFramerate, fpsRange.maxFrameRate);
  }
  return fmin(maxSupportedFramerate, targetFps);
}

@end