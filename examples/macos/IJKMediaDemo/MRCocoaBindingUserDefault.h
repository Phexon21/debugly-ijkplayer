//
//  MRCocoaBindingUserDefault.h
//  IJKMediaMacDemo
//
//  Created by Reach Matt on 2024/1/25.
//  Copyright © 2024 IJK Mac. All rights reserved.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface MRCocoaBindingUserDefault : NSObject

+ (void)initUserDefaults;
+ (void)setValue:(id)value forKey:(NSString *)key;
+ (void)resetValueForKey:(NSString *)key;
+ (id)anyForKey:(NSString *)key;
+ (BOOL)boolForKey:(NSString *)key;
+ (NSString *)stringForKey:(NSString *)key;
+ (MRCocoaBindingUserDefault *)sharedDefault;
//block BOOL means after invoke wheather stop ovserve and remove the observer
- (void)onChange:(void(^)(id,BOOL*))observer forKey:(NSString *)keyPath;
- (void)onChange:(void(^)(id,BOOL*))observer forKey:(NSString *)key init:(BOOL)init;
@end

@interface MRCocoaBindingUserDefault (util)

+ (NSString *)log_level;

+ (float)color_adjust_brightness;
+ (float)color_adjust_saturation;
+ (float)color_adjust_contrast;

+ (int)picture_fill_mode;
+ (int)picture_wh_ratio;
+ (int)picture_ratate_mode;
+ (int)picture_flip_mode;

+ (float)volume;
+ (void)setVolume:(float)aVolume;
+ (BOOL)copy_hw_frame;
+ (BOOL)use_hw;
+ (float)subtitle_font_ratio;
+ (float)subtitle_bottom_margin;
+ (NSString *)overlay_format;
+ (BOOL)accurate_seek;
+ (BOOL)use_opengl;
+ (int)snapshot_type;
+ (int)seek_step;

@end

NS_ASSUME_NONNULL_END
