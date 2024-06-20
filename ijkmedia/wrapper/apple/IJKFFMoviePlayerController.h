/*
 * IJKFFMoviePlayerController.h
 *
 * Copyright (c) 2013 Bilibili
 * Copyright (c) 2013 Zhang Rui <bbcallen@gmail.com>
 *
 * This file is part of ijkPlayer.
 *
 * ijkPlayer is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Lesser General Public
 * License as published by the Free Software Foundation; either
 * version 2.1 of the License, or (at your option) any later version.
 *
 * ijkPlayer is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
 * Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public
 * License along with ijkPlayer; if not, write to the Free Software
 * Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA
 */

#import "IJKMediaPlayback.h"
#import "IJKFFMonitor.h"
#import "IJKFFOptions.h"
#import "IJKVideoRenderingProtocol.h"

// media meta
#define k_IJKM_KEY_FORMAT               @"format"
#define k_IJKM_KEY_DURATION_US          @"duration_us"
#define k_IJKM_KEY_START_US             @"start_us"
#define k_IJKM_KEY_BITRATE              @"bitrate"
#define k_IJKM_KEY_ENCODER              @"encoder"
#define k_IJKM_KEY_MINOR_VER            @"minor_version"
#define k_IJKM_KEY_COMPATIBLE_BRANDS    @"compatible_brands"
#define k_IJKM_KEY_MAJOR_BRAND          @"major_brand"
#define k_IJKM_KEY_LYRICS               @"LYRICS"
#define k_IJKM_KEY_ARTIST               @"artist"
#define k_IJKM_KEY_ALBUM                @"album"
#define k_IJKM_KEY_TYER                 @"TYER"


// stream meta
#define k_IJKM_KEY_TYPE           @"type"
#define k_IJKM_VAL_TYPE__VIDEO    @"video"
#define k_IJKM_VAL_TYPE__AUDIO    @"audio"
#define k_IJKM_VAL_TYPE__SUBTITLE @"timedtext"
#define k_IJKM_VAL_TYPE__UNKNOWN  @"unknown"

#define k_IJKM_KEY_CODEC_NAME      @"codec_name"
#define k_IJKM_KEY_CODEC_PROFILE   @"codec_profile"
#define k_IJKM_KEY_CODEC_LONG_NAME @"codec_long_name"
#define k_IJKM_KEY_STREAM_IDX      @"stream_idx"

// stream: video
#define k_IJKM_KEY_WIDTH          @"width"
#define k_IJKM_KEY_HEIGHT         @"height"
#define k_IJKM_KEY_FPS_NUM        @"fps_num"
#define k_IJKM_KEY_FPS_DEN        @"fps_den"
#define k_IJKM_KEY_TBR_NUM        @"tbr_num"
#define k_IJKM_KEY_TBR_DEN        @"tbr_den"
#define k_IJKM_KEY_SAR_NUM        @"sar_num"
#define k_IJKM_KEY_SAR_DEN        @"sar_den"
// stream: audio
#define k_IJKM_KEY_SAMPLE_RATE    @"sample_rate"
#define k_IJKM_KEY_DESCRIBE       @"describe"
//audio meta also has "title" and "language" key
//#define k_IJKM_KEY_TITLE          @"title"
//#define k_IJKM_KEY_LANGUAGE       @"language"

// stream: subtitle
#define k_IJKM_KEY_TITLE          @"title"
#define k_IJKM_KEY_LANGUAGE       @"language"
#define k_IJKM_KEY_EX_SUBTITLE_URL @"ex_subtile_url"

#define kk_IJKM_KEY_STREAMS       @"streams"

typedef enum IJKLogLevel {
    k_IJK_LOG_UNKNOWN = 0,
    k_IJK_LOG_DEFAULT = 1,

    k_IJK_LOG_VERBOSE = 2,
    k_IJK_LOG_DEBUG   = 3,
    k_IJK_LOG_INFO    = 4,
    k_IJK_LOG_WARN    = 5,
    k_IJK_LOG_ERROR   = 6,
    k_IJK_LOG_FATAL   = 7,
    k_IJK_LOG_SILENT  = 8,
} IJKLogLevel;

@interface IJKFFMoviePlayerController : NSObject <IJKMediaPlayback>

- (id)initWithContentURL:(NSURL *)aUrl
             withOptions:(IJKFFOptions *)options;

- (id)initWithMoreContent:(NSURL *)aUrl
              withOptions:(IJKFFOptions *)options
               withGLView:(UIView<IJKVideoRenderingProtocol> *)glView;

- (void)prepareToPlay;
- (void)play;
- (void)pause;
- (void)stop;
- (BOOL)isPlaying;
- (int64_t)trafficStatistic;
- (float)dropFrameRate;
- (int)dropFrameCount;
- (void)setPauseInBackground:(BOOL)pause;
- (void)setHudValue:(NSString *)value forKey:(NSString *)key;

+ (void)setLogReport:(BOOL)preferLogReport;
+ (void)setLogLevel:(IJKLogLevel)logLevel;
+ (void)setLogHandler:(void (^)(IJKLogLevel level, NSString *tag, NSString *msg))handler;

+ (NSDictionary *)supportedDecoders;
+ (BOOL)checkIfFFmpegVersionMatch:(BOOL)showAlert;
+ (BOOL)checkIfPlayerVersionMatch:(BOOL)showAlert
                            version:(NSString *)version;

@property(nonatomic, readonly) CGFloat fpsInMeta;
@property(nonatomic, readonly) CGFloat fpsAtOutput;
@property(nonatomic) BOOL shouldShowHudView;
//when sampleSize is -1,means needs reset and refresh ui.
@property(nonatomic, copy) void (^audioSamplesCallback)(int16_t *samples, int sampleSize, int sampleRate, int channels);

- (NSDictionary *)allHudItem;

- (void)setOptionValue:(NSString *)value
                forKey:(NSString *)key
            ofCategory:(IJKFFOptionCategory)category;

- (void)setOptionIntValue:(int64_t)value
                   forKey:(NSString *)key
               ofCategory:(IJKFFOptionCategory)category;



- (void)setFormatOptionValue:       (NSString *)value forKey:(NSString *)key;
- (void)setCodecOptionValue:        (NSString *)value forKey:(NSString *)key;
- (void)setSwsOptionValue:          (NSString *)value forKey:(NSString *)key;
- (void)setPlayerOptionValue:       (NSString *)value forKey:(NSString *)key;

- (void)setFormatOptionIntValue:    (int64_t)value forKey:(NSString *)key;
- (void)setCodecOptionIntValue:     (int64_t)value forKey:(NSString *)key;
- (void)setSwsOptionIntValue:       (int64_t)value forKey:(NSString *)key;
- (void)setPlayerOptionIntValue:    (int64_t)value forKey:(NSString *)key;

@property (nonatomic, retain) id<IJKMediaUrlOpenDelegate> segmentOpenDelegate;
@property (nonatomic, retain) id<IJKMediaUrlOpenDelegate> tcpOpenDelegate;
@property (nonatomic, retain) id<IJKMediaUrlOpenDelegate> httpOpenDelegate;
@property (nonatomic, retain) id<IJKMediaUrlOpenDelegate> liveOpenDelegate;

@property (nonatomic, retain) id<IJKMediaNativeInvokeDelegate> nativeInvokeDelegate;

- (void)didShutdown;

#pragma mark KVO properties
@property (nonatomic, readonly) IJKFFMonitor *monitor;

- (void)exchangeSelectedStream:(int)streamIdx;
// k_IJKM_VAL_TYPE__VIDEO, k_IJKM_VAL_TYPE__AUDIO, k_IJKM_VAL_TYPE__SUBTITLE
- (void)closeCurrentStream:(NSString *)streamType;
- (void)enableAccurateSeek:(BOOL)open;
- (void)stepToNextFrame;

@end

#define IJK_FF_IO_TYPE_READ (1)
void IJKFFIOStatDebugCallback(const char *url, int type, int bytes);
void IJKFFIOStatRegister(void (*cb)(const char *url, int type, int bytes));

void IJKFFIOStatCompleteDebugCallback(const char *url,
                                      int64_t read_bytes, int64_t total_size,
                                      int64_t elpased_time, int64_t total_duration);
void IJKFFIOStatCompleteRegister(void (*cb)(const char *url,
                                            int64_t read_bytes, int64_t total_size,
                                            int64_t elpased_time, int64_t total_duration));
