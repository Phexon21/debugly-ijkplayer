/*
 * ijksdl_vout_ios_gles2.c
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

#import "ijksdl_vout_ios_gles2.h"

#include <assert.h>
#include "ijksdl/ijksdl_vout.h"
#include "ijksdl/ijksdl_vout_internal.h"
#include "ijksdl_vout_overlay_ffmpeg.h"
#include "ijksdl_vout_overlay_ffmpeg_hw.h"
#include "ijkplayer/ff_subtitle_def.h"

#if TARGET_OS_IOS
#include "../ios/IJKSDLGLView.h"
#else
#include "../mac/IJKSDLGLView.h"
#endif
#import "IJKSDLTextureString.h"
#import <MetalKit/MetalKit.h>

#if TARGET_OS_OSX
@interface _IJKSDLSubTexture : NSObject<IJKSDLSubtitleTextureProtocol>

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

- (instancetype)initWith:(uint32_t)texture w:(int)w h:(int)h
{
    self = [super init];
    if (self) {
        self.w = w;
        self.h = h;
        self.texture = texture;
    }
    return self;
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
        glBindTexture(GL_TEXTURE_RECTANGLE, _texture);
        
        int texutres[3] = {_texture,0,0};
        ijk_upload_texture_with_cvpixelbuffer(pixelBuff, texutres);
// glTexImage2D 不能处理字节对齐问题！会造成字幕倾斜显示，实际上有多余的padding填充，读取有误产生错行导致的
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
        glBindTexture(GL_TEXTURE_RECTANGLE, 0);
    }
    return self;
}

+ (instancetype)generate:(CVPixelBufferRef)pixel
{
    return [[self alloc] initWithCVPixelBuffer:pixel];
}

@end

#else
#warning TODO iOS
#endif

#if TARGET_OS_OSX
CGSize screenSize(void)
{
    static CGSize _screenSize;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        for (NSScreen *sc in [NSScreen screens]) {
            if (sc.frame.size.width > _screenSize.width && sc.frame.size.height > _screenSize.height) {
                _screenSize = sc.frame.size;
            }
        }
    });
    return _screenSize;
}

static id uploadBGRATexture(CVPixelBufferRef pixelBuff, NSOpenGLContext *openGLContext)
{
    CGLLockContext([openGLContext CGLContextObj]);
    [openGLContext makeCurrentContext];
    
    id subTexture = [_IJKSDLSubTexture generate:pixelBuff];
    CGLUnlockContext([openGLContext CGLContextObj]);
    return subTexture;
}
#else
#warning TODO iOS
#endif

static CVPixelBufferRef _generateFromPixels(FFSubtitleBuffer *buffer)
{
    if (NULL == buffer || !buffer->isImg || buffer->rect.w < 1 || buffer->rect.h < 1) {
        return NULL;
    }
    
    CVPixelBufferRef pixelBuffer = NULL;
    NSDictionary *options = @{
        (__bridge NSString*)kCVPixelBufferOpenGLCompatibilityKey : @YES,
        (__bridge NSString*)kCVPixelBufferIOSurfacePropertiesKey : [NSDictionary dictionary]
    };
    
    CVReturn ret = CVPixelBufferCreate(kCFAllocatorDefault, buffer->rect.w, buffer->rect.h, kCVPixelFormatType_32BGRA, (__bridge CFDictionaryRef)options, &pixelBuffer);
    
    if (ret != kCVReturnSuccess || pixelBuffer == NULL) {
        return NULL;
    }
    
    CVPixelBufferLockBaseAddress(pixelBuffer, 0);
    
    uint8_t *baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer);
    int linesize = (int)CVPixelBufferGetBytesPerRow(pixelBuffer);

    uint8_t *dst_data[4] = {baseAddress,NULL,NULL,NULL};
    int dst_linesizes[4] = {linesize,0,0,0};

    const uint8_t *src_data[4] = {buffer->data,NULL,NULL,NULL};
    const int src_linesizes[4] = {buffer->rect.w * 4,0,0,0};

    av_image_copy(dst_data, dst_linesizes, src_data, src_linesizes, AV_PIX_FMT_BGRA, buffer->rect.w, buffer->rect.h);
    
    CVPixelBufferUnlockBaseAddress(pixelBuffer, 0);
    
    if (kCVReturnSuccess == ret) {
        return pixelBuffer;
    } else {
        return NULL;
    }
}

static CVPixelBufferRef _generateFormText(FFSubtitleBuffer *buffer, int rotate, IJKSDLSubtitlePreference *sp, CGSize maxSize)
{
    if (NULL == buffer || buffer->isImg || strlen((const char *)buffer->data) == 0 || sp == NULL) {
        return NULL;
    }

    NSString *text = [[NSString alloc] initWithUTF8String:(const char *)buffer];
    if (!text) {
        return NULL;
    }
    
    //以1920为标准，对字体缩放
    float scale = 1.0;
    if (rotate / 90 % 2 == 1) {
        scale = screenSize().height / 1920.0;
    } else {
        scale = screenSize().width / 1920.0;
    }
    
    //字幕默认配置
    NSMutableDictionary * attributes = [[NSMutableDictionary alloc] init];

    UIFont *subtitleFont = nil;
    if (strlen(sp->name)) {
        subtitleFont = [UIFont fontWithName:[[NSString alloc] initWithUTF8String:sp->name] size:scale * sp->size];
    }
    
    if (!subtitleFont) {
        subtitleFont = [UIFont systemFontOfSize:scale * sp->size];
    }
    [attributes setObject:subtitleFont forKey:NSFontAttributeName];
    [attributes setObject:int2color(sp->color) forKey:NSForegroundColorAttributeName];
    
    IJKSDLTextureString *textureString = [[IJKSDLTextureString alloc] initWithString:text withAttributes:attributes withStrokeColor:int2color(sp->strokeColor) withStrokeSize:sp->strokeSize];
    
    textureString.maxSize = maxSize;
    return [textureString createPixelBuffer];
}

static CVPixelBufferRef generatePixelBuffer(FFSubtitleBuffer *buffer, int rotate, IJKSDLSubtitlePreference *sp, CGSize maxSize)
{
    if (!buffer) {
        return NULL;
    }
    
    CVPixelBufferRef subRef = NULL;
    if (buffer->isImg) {
        subRef = _generateFromPixels(buffer);
    } else {
        subRef = _generateFormText(buffer, rotate, sp, maxSize);
    }
    return subRef;
}

static id<MTLTexture> uploadBGRAMetalTexture(CVPixelBufferRef pixelBuff, id<MTLDevice>device)
{
    if (!pixelBuff) {
        return nil;
    }
    
    OSType type = CVPixelBufferGetPixelFormatType(pixelBuff);
    if (type != kCVPixelFormatType_32BGRA) {
        return nil;
    }
    
    CVPixelBufferLockBaseAddress(pixelBuff, kCVPixelBufferLock_ReadOnly);
    void *src = CVPixelBufferGetBaseAddress(pixelBuff);
    
    MTLTextureDescriptor *textureDescriptor = [[MTLTextureDescriptor alloc] init];

    // Indicate that each pixel has a blue, green, red, and alpha channel, where each channel is
    // an 8-bit unsigned normalized value (i.e. 0 maps to 0.0 and 255 maps to 1.0)
    textureDescriptor.pixelFormat = MTLPixelFormatBGRA8Unorm;
    // Set the pixel dimensions of the texture
    
    textureDescriptor.width  = CVPixelBufferGetWidth(pixelBuff);
    textureDescriptor.height = CVPixelBufferGetHeight(pixelBuff);
    
    // Create the texture from the device by using the descriptor
    id<MTLTexture> subTexture = [device newTextureWithDescriptor:textureDescriptor];
    
    MTLRegion region = {
        { 0, 0, 0 },                   // MTLOrigin
        {CVPixelBufferGetWidth(pixelBuff), CVPixelBufferGetHeight(pixelBuff), 1} // MTLSize
    };
    
    NSUInteger bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuff);
    
    [subTexture replaceRegion:region
                  mipmapLevel:0
                    withBytes:src
                  bytesPerRow:bytesPerRow];
    
    CVPixelBufferUnlockBaseAddress(pixelBuff, kCVPixelBufferLock_ReadOnly);
    
    return subTexture;
}

@implementation IJKOverlayAttach

- (void)dealloc
{
    if (self.videoPicture) {
        CVPixelBufferRelease(self.videoPicture);
        self.videoPicture = NULL;
    }
    self.subTexture = nil;
    if (self.sub) {
        ff_subtitle_buffer_release(&self->_sub);
    }
}

- (BOOL)generateSubTexture:(IJKSDLSubtitlePreference *)sp maxSize:(CGSize) maxSize context:(id)context
{
    if (self.overlay) {
        self.subTexture = (__bridge _IJKSDLSubTexture *)self.overlay->getTexture(self.overlay->opaque);
        return YES;
    }
    
    if (!self.sub) {
        return NO;
    }
    
    CVPixelBufferRef subRef = generatePixelBuffer(self.sub, self.autoZRotate, sp, maxSize);
    if (subRef) {
        if ([context isKindOfClass:[NSOpenGLContext class]]) {
            self.subTexture = uploadBGRATexture(subRef, context);
        } else {
            self.subTexture = uploadBGRAMetalTexture(subRef, context);
        }
        CVPixelBufferRelease(subRef);
    }
    return self.subTexture != nil;
}

@end

struct SDL_Vout_Opaque {
    void *cvPixelBufferPool;
    int cv_format;
    __strong UIView<IJKVideoRenderingProtocol> *gl_view;
    FFSubtitleBuffer *sub;
    SDL_TextureOverlay *overlay;
};

static SDL_VoutOverlay *vout_create_overlay_l(int width, int height, int src_format, SDL_Vout *vout)
{
    switch (src_format) {
        case AV_PIX_FMT_VIDEOTOOLBOX:
            return SDL_VoutFFmpeg_HW_CreateOverlay(width, height, vout);
        default:
            return SDL_VoutFFmpeg_CreateOverlay(width, height, src_format, vout);
    }
}

static SDL_VoutOverlay *vout_create_overlay(int width, int height, int src_format, SDL_Vout *vout)
{
    SDL_LockMutex(vout->mutex);
    SDL_VoutOverlay *overlay = vout_create_overlay_l(width, height, src_format, vout);
    SDL_UnlockMutex(vout->mutex);
    return overlay;
}

static void vout_free_l(SDL_Vout *vout)
{
    if (!vout)
        return;
    
    SDL_Vout_Opaque *opaque = vout->opaque;
    if (opaque) {
        opaque->gl_view = nil;
        if (opaque->sub) {
            ff_subtitle_buffer_release(&opaque->sub);
        }
        if (opaque->cvPixelBufferPool) {
            CVPixelBufferPoolRelease(opaque->cvPixelBufferPool);
            opaque->cvPixelBufferPool = NULL;
        }
        if (opaque->overlay) {
            SDL_TextureOverlayFreeP(&opaque->overlay);
        }
    }

    SDL_Vout_FreeInternal(vout);
}

static CVPixelBufferRef SDL_Overlay_getCVPixelBufferRef(SDL_VoutOverlay *overlay)
{
    switch (overlay->format) {
        case SDL_FCC__VTB:
            return SDL_VoutFFmpeg_HW_GetCVPixelBufferRef(overlay);
        case SDL_FCC__FFVTB:
            return SDL_VoutFFmpeg_GetCVPixelBufferRef(overlay);
        default:
            return NULL;
    }
}

static int vout_display_overlay_l(SDL_Vout *vout, SDL_VoutOverlay *overlay)
{
    SDL_Vout_Opaque *opaque = vout->opaque;
    UIView<IJKVideoRenderingProtocol>* gl_view = opaque->gl_view;

    if (!gl_view) {
        ALOGE("vout_display_overlay_l: NULL gl_view\n");
        return -1;
    }

    if (!overlay) {
        ALOGE("vout_display_overlay_l: NULL overlay\n");
        return -2;
    }

    if (overlay->w <= 0 || overlay->h <= 0) {
        ALOGE("vout_display_overlay_l: invalid overlay dimensions(%d, %d)\n", overlay->w, overlay->h);
        return -3;
    }

    if (SDL_FCC__VTB != overlay->format && SDL_FCC__FFVTB != overlay->format) {
        ALOGE("vout_display_overlay_l: invalid format:%d\n",overlay->format);
        return -4;
    }
    
    CVPixelBufferRef videoPic = SDL_Overlay_getCVPixelBufferRef(overlay);
    if (videoPic) {
        IJKOverlayAttach *attach = [[IJKOverlayAttach alloc] init];
        attach.w = overlay->w;
        attach.h = overlay->h;
      
        attach.pixelW = (int)CVPixelBufferGetWidth(videoPic);
        attach.pixelH = (int)CVPixelBufferGetHeight(videoPic);
        
        attach.pitches = overlay->pitches;
        attach.sarNum = overlay->sar_num;
        attach.sarDen = overlay->sar_den;
        attach.autoZRotate = overlay->auto_z_rotate_degrees;
        //attach.bufferW = overlay->pitches[0];
        attach.videoPicture = CVPixelBufferRetain(videoPic);
        attach.sub = ff_subtitle_buffer_retain(opaque->sub);
        attach.overlay = opaque->overlay;
        return [gl_view displayAttach:attach];
    } else {
        ALOGE("vout_display_overlay_l: no video picture.\n");
        return -5;
    }
}

static int vout_display_overlay(SDL_Vout *vout, SDL_VoutOverlay *overlay)
{
    @autoreleasepool {
        SDL_LockMutex(vout->mutex);
        int retval = vout_display_overlay_l(vout, overlay);
        SDL_UnlockMutex(vout->mutex);
        return retval;
    }
}

static void vout_update_subtitle(SDL_Vout *vout, void *sb, void *overlay)
{
    SDL_Vout_Opaque *opaque = vout->opaque;
    if (!opaque) {
        return;
    }
    
    opaque->overlay = overlay;
    if (opaque->sub) {
        ff_subtitle_buffer_release(&opaque->sub);
    }
    opaque->sub = ff_subtitle_buffer_retain(sb);
}

SDL_Vout *SDL_VoutIos_CreateForGLES2(void)
{
    SDL_Vout *vout = SDL_Vout_CreateInternal(sizeof(SDL_Vout_Opaque));
    if (!vout)
        return NULL;

    SDL_Vout_Opaque *opaque = vout->opaque;
    opaque->cv_format = -1;
    vout->create_overlay = vout_create_overlay;
    vout->free_l = vout_free_l;
    vout->display_overlay = vout_display_overlay;
    vout->update_subtitle = vout_update_subtitle;
    return vout;
}

static void SDL_VoutIos_SetGLView_l(SDL_Vout *vout, UIView<IJKVideoRenderingProtocol>* view)
{
    SDL_Vout_Opaque *opaque = vout->opaque;
    if (opaque->gl_view != view) {
        opaque->gl_view = view;
    }
}

void SDL_VoutIos_SetGLView(SDL_Vout *vout, UIView<IJKVideoRenderingProtocol>* view)
{
    SDL_LockMutex(vout->mutex);
    SDL_VoutIos_SetGLView_l(vout, view);
    SDL_UnlockMutex(vout->mutex);
}

typedef struct SDL_GPU_Opaque {
    id<MTLDevice>device;
    NSOpenGLContext *glContext;
} SDL_GPU_Opaque;

typedef struct SDL_TextureOverlay_Opaque {
    id<MTLTexture>texture_metal;
    _IJKSDLSubTexture* texture_gl;
    NSOpenGLContext *glContext;
} SDL_TextureOverlay_Opaque;

static void* getTexture(SDL_TextureOverlay_Opaque *opaque)
{
    if (opaque) {
        if (opaque->texture_gl) {
            return (__bridge void *)opaque->texture_gl;
        } else if (opaque->texture_metal) {
            return (__bridge void *)opaque->texture_metal;
        }
    }
    return NULL;
}

static void replaceMetalRegion(SDL_TextureOverlay_Opaque *opaque, SDL_Rectangle rect, void *pixels)
{
    if (opaque && opaque->texture_metal) {
        
        if (rect.x + rect.w > opaque->texture_metal.width) {
            rect.x = 0;
            rect.w = (int)opaque->texture_metal.width;
        }
        
        if (rect.y + rect.h > opaque->texture_metal.height) {
            rect.y = 0;
            rect.h = (int)opaque->texture_metal.height;
        }
        
        int bpr = rect.w * 4;
        MTLRegion region = {
            {rect.x, rect.y, 0}, // MTLOrigin
            {rect.w, rect.h, 1} // MTLSize
        };
        
        [opaque->texture_metal replaceRegion:region
                                 mipmapLevel:0
                                   withBytes:pixels
                                 bytesPerRow:bpr];
    }
}

static void clearMetalRegion(SDL_TextureOverlay *overlay)
{
    if (!overlay) {
        return;
    }
    SDL_TextureOverlay_Opaque *opaque = overlay->opaque;
    if (isZeroRectangle(overlay->dirtyRect)) {
        return;
    }
    void *pixels = av_mallocz(overlay->dirtyRect.w * overlay->dirtyRect.h * 4);
    replaceMetalRegion(opaque, overlay->dirtyRect, pixels);
    av_free(pixels);
}

static SDL_TextureOverlay *createMetalTexture(id<MTLDevice>device, int w, int h)
{
    SDL_TextureOverlay *overlay = (SDL_TextureOverlay*) calloc(1, sizeof(SDL_TextureOverlay));
    if (!overlay)
        return NULL;
    
    SDL_TextureOverlay_Opaque *opaque = (SDL_TextureOverlay_Opaque*) calloc(1, sizeof(SDL_TextureOverlay_Opaque));
    if (!opaque) {
        free(overlay);
        return NULL;
    }
    
    MTLTextureDescriptor *textureDescriptor = [[MTLTextureDescriptor alloc] init];

    // Indicate that each pixel has a blue, green, red, and alpha channel, where each channel is
    // an 8-bit unsigned normalized value (i.e. 0 maps to 0.0 and 255 maps to 1.0)
    textureDescriptor.pixelFormat = MTLPixelFormatBGRA8Unorm;
    // Set the pixel dimensions of the texture
    
    textureDescriptor.width  = w;
    textureDescriptor.height = h;
    
    // Create the texture from the device by using the descriptor
    id<MTLTexture> subTexture = [device newTextureWithDescriptor:textureDescriptor];
    
    opaque->texture_metal = subTexture;
    overlay->opaque = opaque;
    overlay->w = w;
    overlay->h = h;
    overlay->replaceRegion = replaceMetalRegion;
    overlay->getTexture = getTexture;
    overlay->clearDirtyRect = clearMetalRegion;
    return overlay;
}

static void replaceOpenGlRegion(SDL_TextureOverlay_Opaque *opaque, SDL_Rectangle r, void *pixels)
{
    if (opaque && opaque->texture_gl) {
        _IJKSDLSubTexture *t = opaque->texture_gl;
        CGLLockContext([opaque->glContext CGLContextObj]);
        [opaque->glContext makeCurrentContext];
        glBindTexture(GL_TEXTURE_RECTANGLE, t.texture);
        IJK_GLES2_checkError("bind texture subtitle");
        
        if (r.x + r.w > t.w) {
            r.x = 0;
            r.w = t.w;
        }
        
        if (r.y + r.h > t.h) {
            r.y = 0;
            r.h = t.h;
        }
        
        glTexSubImage2D(GL_TEXTURE_RECTANGLE, 0, r.x, r.y, (GLsizei)r.w, (GLsizei)r.h, GL_RGBA, GL_UNSIGNED_BYTE, (const GLvoid *)pixels);
        IJK_GLES2_checkError("replaceOpenGlRegion");
        glBindTexture(GL_TEXTURE_RECTANGLE, 0);
        CGLUnlockContext([opaque->glContext CGLContextObj]);
    }
}

static void clearOpenGLRegion(SDL_TextureOverlay *overlay)
{
    if (!overlay) {
        return;
    }
    SDL_TextureOverlay_Opaque *opaque = overlay->opaque;
    if (opaque && opaque->texture_gl) {
        if (isZeroRectangle(overlay->dirtyRect)) {
            return;
        }
        int h = overlay->dirtyRect.h;
        int bpr = overlay->dirtyRect.w * 4;
        void *pixels = av_mallocz(h * bpr);
        //memset(pixels, 100, h*bpr);
        replaceOpenGlRegion(opaque, overlay->dirtyRect, pixels);
        av_free(pixels);
    }
}

static SDL_TextureOverlay *createOpenGLTexture(NSOpenGLContext *context, int w, int h)
{
    SDL_TextureOverlay *overlay = (SDL_TextureOverlay*) calloc(1, sizeof(SDL_TextureOverlay));
    if (!overlay)
        return NULL;
    
    SDL_TextureOverlay_Opaque *opaque = (SDL_TextureOverlay_Opaque*) calloc(1, sizeof(SDL_TextureOverlay_Opaque));
    if (!opaque) {
        free(overlay);
        return NULL;
    }

    CGLLockContext([context CGLContextObj]);
    [context makeCurrentContext];
    uint32_t texture;
    // Create a texture object that you apply to the model.
    glGenTextures(1, &texture);
    glBindTexture(GL_TEXTURE_RECTANGLE, texture);
    glTexImage2D(GL_TEXTURE_RECTANGLE, 0, GL_RGBA, w, h, 0, GL_BGRA, GL_UNSIGNED_BYTE, NULL);
    
    glTexParameteri(GL_TEXTURE_RECTANGLE, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_RECTANGLE, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_RECTANGLE, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_RECTANGLE, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
   
    glBindTexture(GL_TEXTURE_RECTANGLE, 0);
    CGLUnlockContext([context CGLContextObj]);
    opaque->glContext = context;
    opaque->texture_gl = [[_IJKSDLSubTexture alloc] initWith:texture w:w h:h];;
    overlay->opaque = opaque;
    overlay->w = w;
    overlay->h = h;
    overlay->replaceRegion = replaceOpenGlRegion;
    overlay->getTexture = getTexture;
    overlay->clearDirtyRect = clearOpenGLRegion;
    return overlay;
}

void SDL_TextureOverlayFreeP(SDL_TextureOverlay **poverlay)
{
    if (poverlay) {
        (*poverlay)->opaque->texture_gl = NULL;
        (*poverlay)->opaque->glContext = NULL;
        (*poverlay)->opaque->texture_metal = NULL;
        free((*poverlay)->opaque);
        free(*poverlay);
        *poverlay = NULL;
    }
}

static SDL_TextureOverlay *createTexture(SDL_GPU_Opaque *opaque, int w, int h)
{
    if (opaque->device) {
        return createMetalTexture(opaque->device, w, h);
    } else {
        return createOpenGLTexture(opaque->glContext, w, h);
    }
}

SDL_GPU *SDL_CreateGPU_WithContext(id context)
{
    SDL_GPU *gl = (SDL_GPU*) calloc(1, sizeof(SDL_GPU));
    if (!gl)
        return NULL;
    int opaque_size = sizeof(SDL_GPU_Opaque);
    gl->opaque = calloc(1, opaque_size);
    if (!gl->opaque) {
        free(gl);
        return NULL;
    }
    bzero((void *)gl->opaque, opaque_size);
    SDL_GPU_Opaque *opaque = gl->opaque;
    if ([context isKindOfClass:[NSOpenGLContext class]]) {
        opaque->glContext = context;
    } else {
        opaque->device = context;
    }
    gl->createTexture = createTexture;
    return gl;
}

void SDL_GPUFreeP(SDL_GPU **pgpu)
{
    if (pgpu) {
        (*pgpu)->opaque->glContext = NULL;
        (*pgpu)->opaque->device = NULL;
        free((*pgpu)->opaque);
        free(*pgpu);
        *pgpu = NULL;
    }
}

