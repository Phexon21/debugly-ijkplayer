//
//  ijksdl_gpu_opengl_macos.m
//  IJKMediaPlayerKit
//
//  Created by Reach Matt on 2024/4/14.
//

#import "ijksdl_gpu_opengl_macos.h"
#import "IJKSDLOpenGLFBO.h"
#import "ijksdl_gles2.h"
#import "ijksdl_vout_ios_gles2.h"
#import "ijksdl_gpu.h"
#include <libavutil/mem.h>

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

@end

typedef struct SDL_GPU_Opaque_GL {
    NSOpenGLContext *glContext;
} SDL_GPU_Opaque_GL;

typedef struct SDL_TextureOverlay_Opaque_GL {
    _IJKSDLSubTexture* texture;
    NSOpenGLContext *glContext;
} SDL_TextureOverlay_Opaque_GL;

typedef struct SDL_FBOOverlay_Opaque_GL {
    NSOpenGLContext *glContext;
    SDL_TextureOverlay *toverlay;
    IJKSDLOpenGLFBO *fbo;
} SDL_FBOOverlay_Opaque_GL;

static void* getTexture(SDL_TextureOverlay *overlay);

#pragma mark - Texture OpenGL

static void replaceRegion(SDL_TextureOverlay *overlay, SDL_Rectangle rect, void *pixels)
{
    if (overlay && overlay->opaque) {
        SDL_TextureOverlay_Opaque_GL *op = overlay->opaque;
        _IJKSDLSubTexture *t = op->texture;
        CGLLockContext([op->glContext CGLContextObj]);
        [op->glContext makeCurrentContext];
        glBindTexture(GL_TEXTURE_RECTANGLE, t.texture);
        IJK_GLES2_checkError("bind texture subtitle");
        
        if (rect.x + rect.w > t.w) {
            rect.x = 0;
            rect.w = t.w;
        }
        
        if (rect.y + rect.h > t.h) {
            rect.y = 0;
            rect.h = t.h;
        }
        
        glTexSubImage2D(GL_TEXTURE_RECTANGLE, 0, rect.x, rect.y, (GLsizei)rect.w, (GLsizei)rect.h, GL_RGBA, GL_UNSIGNED_BYTE, (const GLvoid *)pixels);
        IJK_GLES2_checkError("replaceOpenGlRegion");
        glBindTexture(GL_TEXTURE_RECTANGLE, 0);
        CGLUnlockContext([op->glContext CGLContextObj]);
    }
}

static void clearOpenGLRegion(SDL_TextureOverlay *overlay)
{
    if (!overlay) {
        return;
    }
    
    if (isZeroRectangle(overlay->dirtyRect)) {
        return;
    }
    void *pixels = av_mallocz(overlay->dirtyRect.stride * overlay->dirtyRect.h);
    replaceRegion(overlay, overlay->dirtyRect, pixels);
    av_free(pixels);
}

static void dealloc_texture(SDL_TextureOverlay *overlay)
{
    if (overlay) {
        SDL_TextureOverlay_Opaque_GL *opaque = overlay->opaque;
        if (opaque) {
            opaque->glContext = nil;
            opaque->texture = nil;
            free(opaque);
        }
        overlay->opaque = NULL;
    }
}

static SDL_TextureOverlay * create_textureOverlay_with_glTexture(NSOpenGLContext *context, _IJKSDLSubTexture * subTexture)
{
    SDL_TextureOverlay *overlay = (SDL_TextureOverlay*) calloc(1, sizeof(SDL_TextureOverlay));
    if (!overlay)
        return NULL;
    
    SDL_TextureOverlay_Opaque_GL *opaque = (SDL_TextureOverlay_Opaque_GL*)calloc(1, sizeof(SDL_TextureOverlay_Opaque_GL));
    if (!opaque) {
        free(overlay);
        return NULL;
    }

    opaque->glContext = context;
    opaque->texture = subTexture;
    overlay->opaque = opaque;
    overlay->w = subTexture.w;
    overlay->h = subTexture.h;
    overlay->refCount = 1;
    
    overlay->replaceRegion = replaceRegion;
    overlay->getTexture = getTexture;
    overlay->clearDirtyRect = clearOpenGLRegion;
    overlay->dealloc = dealloc_texture;
    
    return overlay;
}

static SDL_TextureOverlay *createOpenGLTexture(NSOpenGLContext *context, int w, int h, SDL_TEXTURE_FMT fmt)
{
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
    
    return create_textureOverlay_with_glTexture(context, [[_IJKSDLSubTexture alloc] initWith:texture w:w h:h]);
}

static void* getTexture(SDL_TextureOverlay *overlay)
{
    if (overlay && overlay->opaque) {
        SDL_TextureOverlay_Opaque_GL *opaque = overlay->opaque;
        return (__bridge void *)opaque->texture;
    }
    return NULL;
}

static SDL_TextureOverlay *createTexture(SDL_GPU *gpu, int w, int h, SDL_TEXTURE_FMT fmt)
{
    if (!gpu && ! gpu->opaque) {
        return NULL;
    }
    
    SDL_GPU_Opaque_GL *gop = gpu->opaque;
    
    return createOpenGLTexture(gop->glContext, w, h, fmt);
}

#pragma mark - FBO OpenGl

static SDL_FBOOverlay *createOpenGLFBO(NSOpenGLContext *glContext, int w, int h)
{
    SDL_FBOOverlay *overlay = (SDL_FBOOverlay*) calloc(1, sizeof(SDL_FBOOverlay));
    if (!overlay)
        return NULL;
    
    SDL_FBOOverlay_Opaque_GL *opaque = (SDL_FBOOverlay_Opaque_GL*) calloc(1, sizeof(SDL_FBOOverlay_Opaque_GL));
    if (!opaque) {
        free(overlay);
        return NULL;
    }
    
    CGSize size = CGSizeMake(w, h);
    if (opaque->fbo) {
        if (![opaque->fbo canReuse:size]) {
            opaque->fbo = nil;
        }
    }
    if (!opaque->fbo) {
        CGLLockContext([glContext CGLContextObj]);
        [glContext makeCurrentContext];
        opaque->fbo = [[IJKSDLOpenGLFBO alloc] initWithSize:size];
        CGLUnlockContext([glContext CGLContextObj]);
    }
    opaque->glContext = glContext;
    overlay->opaque = opaque;
    return overlay;
}

static void beginOpenGLDraw(SDL_GPU *gpu, SDL_FBOOverlay *overlay, int ass)
{
    if (!gpu || !gpu->opaque || !overlay || !overlay->opaque) {
        return;
    }
    
    SDL_FBOOverlay_Opaque_GL *fop = overlay->opaque;
    SDL_GPU_Opaque_GL *gop = gpu->opaque;
}

static void openglDraw(SDL_GPU *gpu, SDL_FBOOverlay *foverlay, SDL_TextureOverlay *toverlay)
{
    if (!gpu || !gpu->opaque || !foverlay || !foverlay->opaque || !toverlay) {
        return;
    }
}

static void endOpenGLDraw(SDL_GPU *gpu, SDL_FBOOverlay *overlay)
{
    if (!gpu || !gpu->opaque || !overlay || !overlay->opaque) {
        return;
    }
}

static void clear_fbo(SDL_FBOOverlay *overlay)
{
    
}

static void dealloc_fbo(SDL_FBOOverlay *overlay)
{
    if (!overlay || !overlay->opaque) {
        return;
    }
    
    SDL_FBOOverlay_Opaque_GL *fop = overlay->opaque;
    SDL_TextureOverlay_Release(&fop->toverlay);
    fop->fbo = nil;
    fop->glContext = nil;
    free(fop);
}

static SDL_TextureOverlay * getTexture_fbo(SDL_FBOOverlay *foverlay)
{
    if (!foverlay || !foverlay->opaque) {
        return NULL;
    }
    
    SDL_FBOOverlay_Opaque_GL *fop = foverlay->opaque;
    if (fop->toverlay) {
        return SDL_TextureOverlay_Retain(fop->toverlay);
    }
    
    uint32_t t = [fop->fbo texture];
    CGSize size = [fop->fbo size];
    _IJKSDLSubTexture *subTexture = [[_IJKSDLSubTexture alloc] initWith:t w:(int)size.width h:(int)size.height];
    return create_textureOverlay_with_glTexture(fop->glContext, subTexture);
}

static SDL_FBOOverlay *createFBO(SDL_GPU *gpu, int w, int h)
{
    if (!gpu || !gpu->opaque) {
        return NULL;
    }
    
    SDL_GPU_Opaque_GL *gop = gpu->opaque;
    SDL_FBOOverlay *overlay = createOpenGLFBO(gop->glContext, w, h);
    
    if (overlay) {
        overlay->w = w;
        overlay->h = h;
        overlay->beginDraw = beginOpenGLDraw;
        overlay->drawTexture = openglDraw;
        overlay->endDraw = endOpenGLDraw;
        overlay->clear = clear_fbo;
        overlay->getTexture = getTexture_fbo;
    }
    return overlay;
}

#pragma mark - GPU

static void dealloc_gpu(SDL_GPU *gpu)
{
    if (!gpu || !gpu->opaque) {
        return;
    }
    
    SDL_GPU_Opaque_GL *gop = gpu->opaque;
    gop->glContext = NULL;
    free(gop);
}

SDL_GPU *SDL_CreateGPU_WithGLContext(NSOpenGLContext * context)
{
    SDL_GPU *gl = (SDL_GPU*) calloc(1, sizeof(SDL_GPU));
    if (!gl)
        return NULL;
    
    SDL_GPU_Opaque_GL *opaque = av_mallocz(sizeof(SDL_GPU_Opaque_GL));
    if (!opaque) {
        free(gl);
        return NULL;
    }
    opaque->glContext = context;
    gl->opaque = opaque;
    gl->createTexture = createTexture;
    gl->createFBO = createFBO;
    gl->dealloc = dealloc_gpu;
    return gl;
}
