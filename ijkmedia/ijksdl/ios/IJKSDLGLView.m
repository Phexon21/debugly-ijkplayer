/*
 * IJKSDLGLView.m
 *
 * Copyright (c) 2013 Bilibili
 * Copyright (c) 2013 Zhang Rui <bbcallen@gmail.com>
 *
 * based on https://github.com/kolyvan/kxmovie
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

#import "IJKSDLGLView.h"
#include "ijksdl/ijksdl_timer.h"
#include "ijksdl/apple/ijksdl_ios.h"
#include "ijksdl/ijksdl_gles2.h"
#import "IJKSDLTextureString.h"
#import "IJKMediaPlayback.h"
#import "../gles2/internal.h"

#define kHDRAnimationMaxCount 90

typedef NS_ENUM(NSInteger, IJKSDLGLViewApplicationState) {
    IJKSDLGLViewApplicationUnknownState = 0,
    IJKSDLGLViewApplicationForegroundState = 1,
    IJKSDLGLViewApplicationBackgroundState = 2
};

@interface _IJKSDLSubTexture : NSObject

@property(nonatomic) GLuint texture;
@property(nonatomic) int w;
@property(nonatomic) int h;

@end

@implementation _IJKSDLSubTexture

- (void)dealloc
{
    if (_texture) {
        glDeleteTextures(1, &_texture);
    }
}

- (GLuint)texture
{
    return _texture;
}

- (instancetype)initWithCVPixelBuffer:(CVPixelBufferRef)pixelBuff
{
    self = [super init];
    if (self) {
        
        self.w = (int)CVPixelBufferGetWidth(pixelBuff);
        self.h = (int)CVPixelBufferGetHeight(pixelBuff);
        
        // Create a texture object that you apply to the model.
        glGenTextures(1, &_texture);
        glActiveTexture(GL_TEXTURE0);
        glBindTexture(GL_TEXTURE_2D, _texture);
        
        int texutres[3] = {_texture,0,0};
        ijk_upload_texture_with_cvpixelbuffer(pixelBuff, texutres);
// glTexImage2D 不能处理字节对齐问题！会找成字幕倾斜显示，实际上有多余的padding填充，读取有误产生错行导致的
//        // Set up filter and wrap modes for the texture object.
//        glTexParameteri(GL_TEXTURE_RECTANGLE, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
//        glTexParameteri(GL_TEXTURE_RECTANGLE, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
//        glTexParameteri(GL_TEXTURE_RECTANGLE, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
//        glTexParameteri(GL_TEXTURE_RECTANGLE, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
//
//        GLsizei width  = (GLsizei)CVPixelBufferGetWidth(pixelBuff);
//        GLsizei height = (GLsizei)CVPixelBufferGetHeight(pixelBuff);
//        CVPixelBufferLockBaseAddress(pixelBuff, kCVPixelBufferLock_ReadOnly);
//        void *src = CVPixelBufferGetBaseAddress(pixelBuff);
//        glTexImage2D(GL_TEXTURE_RECTANGLE, 0, GL_RGBA, width, height, 0, GL_BGRA, GL_UNSIGNED_BYTE, src);
//        CVPixelBufferUnlockBaseAddress(pixelBuff, kCVPixelBufferLock_ReadOnly);
        glBindTexture(GL_TEXTURE_2D, 0);
    }
    return self;
}

+ (instancetype)generate:(CVPixelBufferRef)pixel
{
    return [[self alloc] initWithCVPixelBuffer:pixel];
}

@end

@interface IJKSDLGLView()

@property(atomic) IJKOverlayAttach *currentAttach;
@property(atomic,strong) NSRecursiveLock *glActiveLock;
@property(atomic) BOOL glActivePaused;
@property(nonatomic) NSInteger videoDegrees;
@property(nonatomic) CGSize videoNaturalSize;
//display window size / screen
@property(atomic) float displayScreenScale;
//display window size / video size
@property(atomic) float displayVideoScale;
@property(atomic) GLint backingWidth;
@property(atomic) GLint backingHeight;
@property(atomic) BOOL subtitlePreferenceChanged;
@property(atomic,getter=isRenderBufferInvalidated) BOOL renderBufferInvalidated;
@property(assign) int hdrAnimationFrameCount;

@end

@implementation IJKSDLGLView {
    EAGLContext     *_context;
    GLuint          _framebuffer;
    GLuint          _renderbuffer;
    GLint           _backingWidth;
    GLint           _backingHeight;

    int             _frameCount;
    
    int64_t         _lastFrameTime;

    IJK_GLES2_Renderer *_renderer;
    int                 _rendererGravity;

    
    int             _tryLockErrorCount;
    BOOL            _didSetupGL;
    BOOL            _didStopGL;
    BOOL            _didLockedDueToMovedToWindow;
    BOOL            _shouldLockWhileBeingMovedToWindow;
    NSMutableArray *_registeredNotifications;

    IJKSDLGLViewApplicationState _applicationState;
}

@synthesize scaleFactor                = _scaleFactor;
@synthesize scalingMode                = _scalingMode;
// subtitle preference
@synthesize subtitlePreference = _subtitlePreference;
// rotate preference
@synthesize rotatePreference = _rotatePreference;
// color conversion perference
@synthesize colorPreference = _colorPreference;
// user defined display aspect ratio
@synthesize darPreference = _darPreference;
@synthesize preventDisplay;
@synthesize showHdrAnimation = _showHdrAnimation;

+ (Class) layerClass
{
	return [CAEAGLLayer class];
}

- (id) initWithFrame:(CGRect)frame
{
    self = [super initWithFrame:frame];
    if (self) {
        _tryLockErrorCount = 0;
        _shouldLockWhileBeingMovedToWindow = YES;
        self.glActiveLock = [[NSRecursiveLock alloc] init];
        _registeredNotifications = [[NSMutableArray alloc] init];
        
        _subtitlePreference = (IJKSDLSubtitlePreference){1.0, 0xFFFFFF, 0.1};
        _rotatePreference   = (IJKSDLRotatePreference){IJKSDLRotateNone, 0.0};
        _colorPreference    = (IJKSDLColorConversionPreference){1.0, 1.0, 1.0};
        _darPreference      = (IJKSDLDARPreference){0.0};
        _displayScreenScale = 1.0;
        _displayVideoScale  = 1.0;
        _rendererGravity    = IJK_GLES2_GRAVITY_RESIZE_ASPECT;
        
        [self registerApplicationObservers];
        
        _didSetupGL = NO;
        if ([self isApplicationActive] == YES)
            [self setupGLOnce];
    }

    return self;
}

- (void)willMoveToWindow:(UIWindow *)newWindow
{
    if (!_shouldLockWhileBeingMovedToWindow) {
        [super willMoveToWindow:newWindow];
        return;
    }
    if (newWindow && !_didLockedDueToMovedToWindow) {
        [self lockGLActive];
        _didLockedDueToMovedToWindow = YES;
    }
    [super willMoveToWindow:newWindow];
}

- (void)didMoveToWindow
{
    [super didMoveToWindow];
    if (self.window && _didLockedDueToMovedToWindow) {
        [self unlockGLActive];
        _didLockedDueToMovedToWindow = NO;
    }
}

- (BOOL)setupEAGLContext:(EAGLContext *)context
{
    glGenFramebuffers(1, &_framebuffer);
    glGenRenderbuffers(1, &_renderbuffer);
    glBindFramebuffer(GL_FRAMEBUFFER, _framebuffer);
    glBindRenderbuffer(GL_RENDERBUFFER, _renderbuffer);
    [_context renderbufferStorage:GL_RENDERBUFFER fromDrawable:(CAEAGLLayer*)self.layer];
    glGetRenderbufferParameteriv(GL_RENDERBUFFER, GL_RENDERBUFFER_WIDTH, &_backingWidth);
    glGetRenderbufferParameteriv(GL_RENDERBUFFER, GL_RENDERBUFFER_HEIGHT, &_backingHeight);
    glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_RENDERBUFFER, _renderbuffer);

    GLenum status = glCheckFramebufferStatus(GL_FRAMEBUFFER);
    if (status != GL_FRAMEBUFFER_COMPLETE) {
        NSLog(@"failed to make complete framebuffer object %x\n", status);
        return NO;
    }

    GLenum glError = glGetError();
    if (GL_NO_ERROR != glError) {
        NSLog(@"failed to setup GL %x\n", glError);
        return NO;
    }

    return YES;
}

- (CAEAGLLayer *)eaglLayer
{
    return (CAEAGLLayer*) self.layer;
}

- (BOOL)setupGL
{
    if (_didSetupGL)
        return YES;

    CAEAGLLayer *eaglLayer = (CAEAGLLayer*) self.layer;
    eaglLayer.opaque = YES;
    eaglLayer.drawableProperties = [NSDictionary dictionaryWithObjectsAndKeys:
                                    [NSNumber numberWithBool:NO], kEAGLDrawablePropertyRetainedBacking,
                                    kEAGLColorFormatRGBA8, kEAGLDrawablePropertyColorFormat,
                                    nil];

    _scaleFactor = [[UIScreen mainScreen] scale];
    if (_scaleFactor < 0.1f)
        _scaleFactor = 1.0f;

    [eaglLayer setContentsScale:_scaleFactor];

    _context = [[EAGLContext alloc] initWithAPI:kEAGLRenderingAPIOpenGLES2];
    if (_context == nil) {
        NSLog(@"failed to setup EAGLContext\n");
        return NO;
    }

    EAGLContext *prevContext = [EAGLContext currentContext];
    [EAGLContext setCurrentContext:_context];
    _didSetupGL = NO;
    if ([self setupEAGLContext:_context]) {
        NSLog(@"OK setup GL\n");
        _didSetupGL = YES;
    }

    [EAGLContext setCurrentContext:prevContext];
    return _didSetupGL;
}

- (BOOL)setupGLOnce
{
    if (_didSetupGL)
        return YES;

    if (![self tryLockGLActive])
        return NO;

    BOOL didSetupGL = [self setupGL];
    [self unlockGLActive];
    return didSetupGL;
}

- (void)setShowHdrAnimation:(BOOL)showHdrAnimation
{
    if (_showHdrAnimation != showHdrAnimation) {
        _showHdrAnimation = showHdrAnimation;
        self.hdrAnimationFrameCount = 0;
    }
}

- (void)videoZRotateDegrees:(NSInteger)degrees
{
    self.videoDegrees = degrees;
}

- (void)videoNaturalSizeChanged:(CGSize)size
{
    self.videoNaturalSize = size;
    CGRect viewBounds = [self bounds];
    if (!CGSizeEqualToSize(CGSizeZero, self.videoNaturalSize)) {
        self.displayVideoScale = FFMIN(1.0 * viewBounds.size.width / self.videoNaturalSize.width, 1.0 * viewBounds.size.height / self.videoNaturalSize.height);
    }
}

- (BOOL)isApplicationActive
{
    switch (_applicationState) {
        case IJKSDLGLViewApplicationForegroundState:
            return YES;
        case IJKSDLGLViewApplicationBackgroundState:
            return NO;
        default: {
            UIApplicationState appState = [UIApplication sharedApplication].applicationState;
            switch (appState) {
                case UIApplicationStateActive:
                    return YES;
                case UIApplicationStateInactive:
                case UIApplicationStateBackground:
                default:
                    return NO;
            }
        }
    }
}

- (void)dealloc
{
    [self lockGLActive];

    _didStopGL = YES;

    EAGLContext *prevContext = [EAGLContext currentContext];
    [EAGLContext setCurrentContext:_context];
    
    IJK_GLES2_Renderer_reset(_renderer);
    IJK_GLES2_Renderer_freeP(&_renderer);

    if (_framebuffer) {
        glDeleteFramebuffers(1, &_framebuffer);
        _framebuffer = 0;
    }

    if (_renderbuffer) {
        glDeleteRenderbuffers(1, &_renderbuffer);
        _renderbuffer = 0;
    }
    
    glFinish();

    [EAGLContext setCurrentContext:prevContext];

    _context = nil;

    [self unregisterApplicationObservers];

    [self unlockGLActive];
}

- (void)setScaleFactor:(CGFloat)scaleFactor
{
    _scaleFactor = scaleFactor;
    [self resetViewPort];
}

- (void)layoutSubviews
{
    [super layoutSubviews];
    if (self.window.screen != nil) {
        _scaleFactor = self.window.screen.scale;
    }
    [self resetViewPort];
}

- (void)resetViewPort
{
    CGSize viewSize = [self bounds].size;
    //TODO:need check airplay
    CGSize viewSizePixels = CGSizeMake(viewSize.width * _scaleFactor, viewSize.height * _scaleFactor);
    
    if (self.backingWidth != viewSizePixels.width || self.backingHeight != viewSizePixels.height) {
        self.backingWidth  = viewSizePixels.width;
        self.backingHeight = viewSizePixels.height;
        
        CGSize screenSize = [[UIScreen mainScreen]bounds].size;;
        self.displayScreenScale = FFMIN(1.0 * viewSize.width / screenSize.width,1.0 * viewSize.height / screenSize.height);
        if (!CGSizeEqualToSize(CGSizeZero, self.videoNaturalSize)) {
            self.displayVideoScale = FFMIN(1.0 * viewSize.width / self.videoNaturalSize.width,1.0 * viewSize.height / self.videoNaturalSize.height);
        }
        
        if (IJK_GLES2_Renderer_isValid(_renderer)) {
            IJK_GLES2_Renderer_setGravity(_renderer, _rendererGravity, self.backingWidth, self.backingHeight);
        }
    }
    
    self.renderBufferInvalidated = YES;
}

- (BOOL)setupRendererIfNeed:(IJKOverlayAttach *)attach
{
    if (attach == nil)
        return _renderer != nil;
    
    Uint32 cv_format = CVPixelBufferGetPixelFormatType(attach.videoPicture);
    
    if (!IJK_GLES2_Renderer_isValid(_renderer) ||
        !IJK_GLES2_Renderer_isFormat(_renderer, cv_format)) {

        IJK_GLES2_Renderer_reset(_renderer);
        IJK_GLES2_Renderer_freeP(&_renderer);
        
        _renderer = IJK_GLES2_Renderer_createApple(attach.videoPicture, 0);
        if (!IJK_GLES2_Renderer_isValid(_renderer))
            return NO;

        if (!IJK_GLES2_Renderer_use(_renderer))
            return NO;

        IJK_GLES2_Renderer_setGravity(_renderer, _rendererGravity, self.backingWidth, self.backingHeight);
        
        IJK_GLES2_Renderer_updateRotate(_renderer, _rotatePreference.type, _rotatePreference.degrees);
        
        IJK_GLES2_Renderer_updateAutoZRotate(_renderer, attach.autoZRotate);
        
        IJK_GLES2_Renderer_updateSubtitleBottomMargin(_renderer, _subtitlePreference.bottomMargin);
        
        IJK_GLES2_Renderer_updateColorConversion(_renderer, _colorPreference.brightness, _colorPreference.saturation,_colorPreference.contrast);
        
        IJK_GLES2_Renderer_updateUserDefinedDAR(_renderer, _darPreference.ratio);
    }

    return YES;
}

- (void)doUploadSubtitle:(IJKOverlayAttach *)attach
{
    _IJKSDLSubTexture * subTexture = attach.subTexture;
    if (subTexture) {
        float ratio = 1.0;
        if (attach.sub.pixels) {
            ratio = self.subtitlePreference.ratio * self.displayVideoScale * 1.5;
        } else {
            //for text subtitle scale display_scale.
            ratio *= self.displayScreenScale;
        }
        
        IJK_GLES2_Renderer_beginDrawSubtitle(_renderer);
        IJK_GLES2_Renderer_updateSubtitleVertex(_renderer, ratio * subTexture.w, ratio * subTexture.h);
        if (IJK_GLES2_Renderer_uploadSubtitleTexture(_renderer, subTexture.texture, subTexture.w, subTexture.h)) {
            IJK_GLES2_Renderer_drawArrays();
        } else {
            ALOGE("[GL] GLES2 Render Subtitle failed\n");
        }
        IJK_GLES2_Renderer_endDrawSubtitle(_renderer);
    }
}

- (void)doUploadVideoPicture:(IJKOverlayAttach *)attach
{
    if (attach.videoPicture) {
        if (IJK_GLES2_Renderer_updateVertex2(_renderer, attach.h, attach.w, attach.pixelW, attach.sarNum, attach.sarDen)) {
            float hdrPer = 1.0;
            if (self.showHdrAnimation) {
                if (self.hdrAnimationFrameCount == 0) {
                    [[NSNotificationCenter defaultCenter] postNotificationName:IJKMoviePlayerHDRAnimationStateChanged object:self userInfo:@{@"state":@(1)}];
                } else if (self.hdrAnimationFrameCount == kHDRAnimationMaxCount) {
                    [[NSNotificationCenter defaultCenter] postNotificationName:IJKMoviePlayerHDRAnimationStateChanged object:self userInfo:@{@"state":@(2)}];
                }
                
                if (self.hdrAnimationFrameCount <= kHDRAnimationMaxCount) {
                    self.hdrAnimationFrameCount++;
                    hdrPer = 1.0 * self.hdrAnimationFrameCount / kHDRAnimationMaxCount;
                }
            }
            IJK_GLES2_Renderer_updateHdrAnimationProgress(_renderer, hdrPer);
            if (IJK_GLES2_Renderer_uploadTexture(_renderer, (void *)attach.videoPicture)) {
                IJK_GLES2_Renderer_drawArrays();
            } else {
                ALOGE("[GL] Renderer_updateVertex failed\n");
            }
        } else {
            ALOGE("[GL] Renderer_updateVertex failed\n");
        }
    }
}

- (void)doRefreshCurrentAttach:(IJKOverlayAttach *)currentAttach
{
    if (!currentAttach) {
        return;
    }
    
    //update subtitle if need
    if (self.subtitlePreferenceChanged) {
        if (currentAttach.sub.text) {
            CVPixelBufferRef subPicture = [self _generateSubtitlePixel:currentAttach.sub.text];
            currentAttach.subTexture = [_IJKSDLSubTexture generate:subPicture];
        }
        self.subtitlePreferenceChanged = NO;
    }
    
    [self doDisplayVideoPicAndSubtitle:currentAttach];
}

- (void)setNeedsRefreshCurrentPic
{
    [self doRefreshCurrentAttach:self.currentAttach];
}

- (CVPixelBufferRef)_generateSubtitlePixel:(NSString *)subtitle
{
    if (subtitle.length == 0) {
        return NULL;
    }
    
    IJKSDLSubtitlePreference sp = self.subtitlePreference;
        
    float ratio = sp.ratio;
    int32_t bgrValue = sp.color;
    //iPhone上以800为标准，定义出字幕字体默认大小为60pt
    float scale = 1.0;
    CGSize screenSize = [[UIScreen mainScreen]bounds].size;
    
    NSInteger degrees = self.videoDegrees;
    if (degrees / 90 % 2 == 1) {
        scale = screenSize.height / 800.0;
    } else {
        scale = screenSize.width / 800.0;
    }
    //字幕默认配置
    NSMutableDictionary * attributes = [[NSMutableDictionary alloc] init];
    
    UIFont *subtitleFont = [UIFont systemFontOfSize:ratio * scale * 60];
    [attributes setObject:subtitleFont forKey:NSFontAttributeName];
    
    UIColor *subtitleColor = [UIColor colorWithRed:((float)(bgrValue & 0xFF)) / 255.0 green:((float)((bgrValue & 0xFF00) >> 8)) / 255.0 blue:(float)(((bgrValue & 0xFF0000) >> 16)) / 255.0 alpha:1.0];
    
    [attributes setObject:subtitleColor forKey:NSForegroundColorAttributeName];
    
    IJKSDLTextureString *textureString = [[IJKSDLTextureString alloc] initWithString:subtitle withAttributes:attributes];
    
    return [textureString createPixelBuffer];
}

- (CVPixelBufferRef)_generateSubtitlePixelFromPicture:(IJKSDLSubtitle*)pict
{
    CVPixelBufferRef pixelBuffer = NULL;
    NSDictionary *options = @{
        (__bridge NSString*)kCVPixelBufferOpenGLCompatibilityKey : @YES,
        (__bridge NSString*)kCVPixelBufferIOSurfacePropertiesKey : [NSDictionary dictionary]
    };
    
    CVReturn ret = CVPixelBufferCreate(kCFAllocatorDefault, pict.w, pict.h, kCVPixelFormatType_32BGRA, (__bridge CFDictionaryRef)options, &pixelBuffer);
    
    NSParameterAssert(ret == kCVReturnSuccess && pixelBuffer != NULL);
    
    CVPixelBufferLockBaseAddress(pixelBuffer, 0);
    
    uint8_t *baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer);
    int linesize = (int)CVPixelBufferGetBytesPerRow(pixelBuffer);

    uint8_t *dst_data[4] = {baseAddress,NULL,NULL,NULL};
    int dst_linesizes[4] = {linesize,0,0,0};

    const uint8_t *src_data[4] = {pict.pixels,NULL,NULL,NULL};
    const int src_linesizes[4] = {pict.w * 4,0,0,0};

    av_image_copy(dst_data, dst_linesizes, src_data, src_linesizes, AV_PIX_FMT_BGRA, pict.w, pict.h);
    
    CVPixelBufferUnlockBaseAddress(pixelBuffer, 0);
            
    if (kCVReturnSuccess == ret) {
        return pixelBuffer;
    } else {
        return NULL;
    }
}

- (BOOL)doDisplayVideoPicAndSubtitle:(IJKOverlayAttach *)attach
{
    if (!attach) {
        return NO;
    }
    
    if (_didSetupGL == NO)
        return NO;

    if ([self isApplicationActive] == NO)
        return NO;

    if (![self tryLockGLActive]) {
        if (0 == (_tryLockErrorCount % 100)) {
            NSLog(@"IJKSDLGLView:display: unable to tryLock GL active: %d\n", _tryLockErrorCount);
        }
        _tryLockErrorCount++;
        return NO;
    }

    BOOL ok = YES;
    _tryLockErrorCount = 0;
    if (_context && !_didStopGL) {
        EAGLContext *prevContext = [EAGLContext currentContext];
        [EAGLContext setCurrentContext:_context];
        {
            [[self eaglLayer] setContentsScale:_scaleFactor];
            if ([self setupRendererIfNeed:attach] && IJK_GLES2_Renderer_isValid(_renderer)) {
                glBindRenderbuffer(GL_RENDERBUFFER, _renderbuffer);
                glViewport(0, 0, self.backingWidth, self.backingHeight);
                glClear(GL_COLOR_BUFFER_BIT);
                glPixelStorei(GL_UNPACK_ALIGNMENT, 1);
                
                if (self.isRenderBufferInvalidated) {
                    self.renderBufferInvalidated = NO;
                    [_context renderbufferStorage:GL_RENDERBUFFER fromDrawable:(CAEAGLLayer*)self.layer];
                }
                
                //for video
                [self doUploadVideoPicture:attach];
                //for subtitle
                [self doUploadSubtitle:attach];
            } else {
                ALOGW("IJKSDLGLView: not ready.\n");
                ok = NO;
            }
            
            [_context presentRenderbuffer:GL_RENDERBUFFER];
        }
        [EAGLContext setCurrentContext:prevContext];
    }

    [self unlockGLActive];
    return ok;
}

- (void)generateSubTexture:(IJKOverlayAttach *)attach
{
    IJKSDLSubtitle *sub = attach.sub;
    CVPixelBufferRef subRef = NULL;
    if (sub.text.length > 0) {
        subRef = [self _generateSubtitlePixel:sub.text];
    } else if (sub.pixels != NULL) {
        subRef = [self _generateSubtitlePixelFromPicture:sub];
    }
    if (subRef) {
        [self tryLockGLActive];
        EAGLContext *prevContext = [EAGLContext currentContext];
        [EAGLContext setCurrentContext:_context];
        attach.subTexture = [_IJKSDLSubTexture generate:subRef];
        [self unlockGLActive];
        [EAGLContext setCurrentContext:prevContext];
        CVPixelBufferRelease(subRef);
    }
}

- (BOOL)displayAttach:(IJKOverlayAttach *)attach
{
    if (!attach) {
        ALOGW("IJKSDLGLView: overlay is nil\n");
        return NO;
    }
    
    //generate current subtitle.
    [self generateSubTexture:attach];
    
    if (self.subtitlePreferenceChanged) {
        self.subtitlePreferenceChanged = NO;
    }
    //hold the attach as current.
    self.currentAttach = attach;
    
    if (self.preventDisplay) {
        return YES;
    }
    
    return [self doDisplayVideoPicAndSubtitle:self.currentAttach];
}

#pragma mark AppDelegate

- (void) lockGLActive
{
    [self.glActiveLock lock];
}

- (void) unlockGLActive
{
    [self.glActiveLock unlock];
}

- (BOOL) tryLockGLActive
{
    if (![self.glActiveLock tryLock])
        return NO;

    /*-
    if ([UIApplication sharedApplication].applicationState != UIApplicationStateActive &&
        [UIApplication sharedApplication].applicationState != UIApplicationStateInactive) {
        [self.appLock unlock];
        return NO;
    }
     */

    if (self.glActivePaused) {
        [self.glActiveLock unlock];
        return NO;
    }
    
    return YES;
}

- (void)toggleGLPaused:(BOOL)paused
{
    [self lockGLActive];
    if (!self.glActivePaused && paused) {
        if (_context != nil) {
            EAGLContext *prevContext = [EAGLContext currentContext];
            [EAGLContext setCurrentContext:_context];
            glFinish();
            [EAGLContext setCurrentContext:prevContext];
        }
    }
    self.glActivePaused = paused;
    [self unlockGLActive];
}

- (void)registerApplicationObservers
{

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(applicationWillEnterForeground)
                                                 name:UIApplicationWillEnterForegroundNotification
                                               object:nil];
    [_registeredNotifications addObject:UIApplicationWillEnterForegroundNotification];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(applicationDidBecomeActive)
                                                 name:UIApplicationDidBecomeActiveNotification
                                               object:nil];
    [_registeredNotifications addObject:UIApplicationDidBecomeActiveNotification];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(applicationWillResignActive)
                                                 name:UIApplicationWillResignActiveNotification
                                               object:nil];
    [_registeredNotifications addObject:UIApplicationWillResignActiveNotification];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(applicationDidEnterBackground)
                                                 name:UIApplicationDidEnterBackgroundNotification
                                               object:nil];
    [_registeredNotifications addObject:UIApplicationDidEnterBackgroundNotification];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(applicationWillTerminate)
                                                 name:UIApplicationWillTerminateNotification
                                               object:nil];
    [_registeredNotifications addObject:UIApplicationWillTerminateNotification];
}

- (void)unregisterApplicationObservers
{
    for (NSString *name in _registeredNotifications) {
        [[NSNotificationCenter defaultCenter] removeObserver:self
                                                        name:name
                                                      object:nil];
    }
}

- (void)applicationWillEnterForeground
{
    NSLog(@"IJKSDLGLView:applicationWillEnterForeground: %d", (int)[UIApplication sharedApplication].applicationState);
    [self setupGLOnce];
    _applicationState = IJKSDLGLViewApplicationForegroundState;
    [self toggleGLPaused:NO];
}

- (void)applicationDidBecomeActive
{
    NSLog(@"IJKSDLGLView:applicationDidBecomeActive: %d", (int)[UIApplication sharedApplication].applicationState);
    [self setupGLOnce];
    [self toggleGLPaused:NO];
}

- (void)applicationWillResignActive
{
    NSLog(@"IJKSDLGLView:applicationWillResignActive: %d", (int)[UIApplication sharedApplication].applicationState);
    [self toggleGLPaused:YES];
    glFinish();
}

- (void)applicationDidEnterBackground
{
    NSLog(@"IJKSDLGLView:applicationDidEnterBackground: %d", (int)[UIApplication sharedApplication].applicationState);
    _applicationState = IJKSDLGLViewApplicationBackgroundState;
    [self toggleGLPaused:YES];
    glFinish();
}

- (void)applicationWillTerminate
{
    NSLog(@"IJKSDLGLView:applicationWillTerminate: %d", (int)[UIApplication sharedApplication].applicationState);
    [self toggleGLPaused:YES];
}

#pragma mark snapshot

- (UIImage*)snapshot
{
    [self lockGLActive];

    UIImage *image = [self snapshotInternal];

    [self unlockGLActive];

    return image;
}

- (UIImage*)snapshotInternal
{
    if (isIOS7OrLater()) {
        return [self snapshotInternalOnIOS7AndLater];
    } else {
        return [self snapshotInternalOnIOS6AndBefore];
    }
}

- (UIImage*)snapshotInternalOnIOS7AndLater
{
    if (CGSizeEqualToSize(self.bounds.size, CGSizeZero)) {
        return nil;
    }
    UIGraphicsBeginImageContextWithOptions(self.bounds.size, NO, 0.0);
    // Render our snapshot into the image context
    [self drawViewHierarchyInRect:self.bounds afterScreenUpdates:NO];

    // Grab the image from the context
    UIImage *complexViewImage = UIGraphicsGetImageFromCurrentImageContext();
    // Finish using the context
    UIGraphicsEndImageContext();

    return complexViewImage;
}

- (UIImage*)snapshotInternalOnIOS6AndBefore
{
    EAGLContext *prevContext = [EAGLContext currentContext];
    [EAGLContext setCurrentContext:_context];

    GLint backingWidth, backingHeight;

    // Bind the color renderbuffer used to render the OpenGL ES view
    // If your application only creates a single color renderbuffer which is already bound at this point,
    // this call is redundant, but it is needed if you're dealing with multiple renderbuffers.
    // Note, replace "viewRenderbuffer" with the actual name of the renderbuffer object defined in your class.
    glBindRenderbuffer(GL_RENDERBUFFER, _renderbuffer);

    // Get the size of the backing CAEAGLLayer
    glGetRenderbufferParameteriv(GL_RENDERBUFFER, GL_RENDERBUFFER_WIDTH, &backingWidth);
    glGetRenderbufferParameteriv(GL_RENDERBUFFER, GL_RENDERBUFFER_HEIGHT, &backingHeight);

    NSInteger x = 0, y = 0, width = backingWidth, height = backingHeight;
    NSInteger dataLength = width * height * 4;
    GLubyte *data = (GLubyte*)malloc(dataLength * sizeof(GLubyte));

    // Read pixel data from the framebuffer
    glPixelStorei(GL_PACK_ALIGNMENT, 4);
    glReadPixels((int)x, (int)y, (int)width, (int)height, GL_RGBA, GL_UNSIGNED_BYTE, data);

    // Create a CGImage with the pixel data
    // If your OpenGL ES content is opaque, use kCGImageAlphaNoneSkipLast to ignore the alpha channel
    // otherwise, use kCGImageAlphaPremultipliedLast
    CGDataProviderRef ref = CGDataProviderCreateWithData(NULL, data, dataLength, NULL);
    CGColorSpaceRef colorspace = CGColorSpaceCreateDeviceRGB();
    CGImageRef iref = CGImageCreate(width, height, 8, 32, width * 4, colorspace, kCGBitmapByteOrder32Big | kCGImageAlphaPremultipliedLast,
                                    ref, NULL, true, kCGRenderingIntentDefault);

    [EAGLContext setCurrentContext:prevContext];

    // OpenGL ES measures data in PIXELS
    // Create a graphics context with the target size measured in POINTS
    UIGraphicsBeginImageContext(CGSizeMake(width, height));

    CGContextRef cgcontext = UIGraphicsGetCurrentContext();
    // UIKit coordinate system is upside down to GL/Quartz coordinate system
    // Flip the CGImage by rendering it to the flipped bitmap context
    // The size of the destination area is measured in POINTS
    CGContextSetBlendMode(cgcontext, kCGBlendModeCopy);
    CGContextDrawImage(cgcontext, CGRectMake(0.0, 0.0, width, height), iref);

    // Retrieve the UIImage from the current context
    UIImage *image = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();

    // Clean up
    free(data);
    CFRelease(ref);
    CFRelease(colorspace);
    CGImageRelease(iref);

    return image;
}

#pragma mark - override setter methods

- (void)setScalingMode:(IJKMPMovieScalingMode)scalingMode
{
    switch (scalingMode) {
        case IJKMPMovieScalingModeFill:
            _rendererGravity = IJK_GLES2_GRAVITY_RESIZE;
            break;
        case IJKMPMovieScalingModeAspectFit:
            _rendererGravity = IJK_GLES2_GRAVITY_RESIZE_ASPECT;
            break;
        case IJKMPMovieScalingModeAspectFill:
            _rendererGravity = IJK_GLES2_GRAVITY_RESIZE_ASPECT_FILL;
            break;
    }
    _scalingMode = scalingMode;
    if (IJK_GLES2_Renderer_isValid(_renderer)) {
        IJK_GLES2_Renderer_setGravity(_renderer, _rendererGravity, self.backingWidth, self.backingHeight);
    }
}

- (void)setRotatePreference:(IJKSDLRotatePreference)rotatePreference
{
    if (_rotatePreference.type != rotatePreference.type || _rotatePreference.degrees != rotatePreference.degrees) {
        _rotatePreference = rotatePreference;
        if (IJK_GLES2_Renderer_isValid(_renderer)) {
            IJK_GLES2_Renderer_updateRotate(_renderer, _rotatePreference.type, _rotatePreference.degrees);
        }
    }
}

- (void)setColorPreference:(IJKSDLColorConversionPreference)colorPreference
{
    if (_colorPreference.brightness != colorPreference.brightness || _colorPreference.saturation != colorPreference.saturation || _colorPreference.contrast != colorPreference.contrast) {
        _colorPreference = colorPreference;
        if (IJK_GLES2_Renderer_isValid(_renderer)) {
            IJK_GLES2_Renderer_updateColorConversion(_renderer, _colorPreference.brightness, _colorPreference.saturation,_colorPreference.contrast);
        }
    }
}

- (void)setDarPreference:(IJKSDLDARPreference)darPreference
{
    if (_darPreference.ratio != darPreference.ratio) {
        _darPreference = darPreference;
        if (IJK_GLES2_Renderer_isValid(_renderer)) {
            IJK_GLES2_Renderer_updateUserDefinedDAR(_renderer, _darPreference.ratio);
        }
    }
}

- (void)setSubtitlePreference:(IJKSDLSubtitlePreference)subtitlePreference
{
    if (_subtitlePreference.bottomMargin != subtitlePreference.bottomMargin) {
        _subtitlePreference = subtitlePreference;
        if (IJK_GLES2_Renderer_isValid(_renderer)) {
            IJK_GLES2_Renderer_updateSubtitleBottomMargin(_renderer, _subtitlePreference.bottomMargin);
        }
    }
    
    if (_subtitlePreference.ratio != subtitlePreference.ratio || _subtitlePreference.color != subtitlePreference.color) {
        _subtitlePreference = subtitlePreference;
        self.subtitlePreferenceChanged = YES;
    }
}

- (NSString *)name
{
    return @"OpenGL-ES";
}

@end
