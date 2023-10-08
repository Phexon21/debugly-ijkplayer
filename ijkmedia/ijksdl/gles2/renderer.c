/*
 * Copyright (c) 2016 Bilibili
 * copyright (c) 2016 Zhang Rui <bbcallen@gmail.com>
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

#include "internal.h"
#ifdef __APPLE__
#include <TargetConditionals.h>
#include <CoreVideo/CoreVideo.h>
#include "../apple/ijk_vout_common.h"
#if TARGET_OS_OSX
#include <OpenGL/gl3.h>
#else
#import <OpenGLES/ES3/gl.h>
#endif
#endif
#include "math_util.h"

static void IJK_GLES2_printProgramInfo(GLuint program)
{
    if (!program)
        return;

    GLint info_len = 0;
    glGetProgramiv(program, GL_INFO_LOG_LENGTH, &info_len);
    if (!info_len) {
        ALOGE("[GLES2][Program] empty info\n");
        return;
    }

    char    buf_stack[32];
    char   *buf_heap = NULL;
    char   *buf      = buf_stack;
    GLsizei buf_len  = sizeof(buf_stack) - 1;
    if (info_len > sizeof(buf_stack)) {
        buf_heap = (char*) malloc(info_len + 1);
        if (buf_heap) {
            buf     = buf_heap;
            buf_len = info_len;
        }
    }

    glGetProgramInfoLog(program, buf_len, NULL, buf);
    ALOGE("[GLES2][Program] error %s\n", buf);

    if (buf_heap)
        free(buf_heap);
}

void IJK_GLES2_Renderer_reset(IJK_GLES2_Renderer *renderer)
{
    if (!renderer)
        return;

    if (renderer->vertex_shader)
        glDeleteShader(renderer->vertex_shader);
    if (renderer->fragment_shader)
        glDeleteShader(renderer->fragment_shader);
    if (renderer->program)
        glDeleteProgram(renderer->program);

    renderer->vertex_shader   = 0;
    renderer->fragment_shader = 0;
    renderer->program         = 0;

    for (int i = 0; i < IJK_GLES2_MAX_PLANE; ++i) {
        if (renderer->plane_textures[i]) {
            glDeleteTextures(1, &renderer->plane_textures[i]);
            renderer->plane_textures[i] = 0;
        }
    }
    
    glDeleteBuffers(1, &renderer->vbo);
    glDeleteVertexArrays(1, &renderer->vao);
}

void IJK_GLES2_Renderer_free(IJK_GLES2_Renderer *renderer)
{
    if (!renderer)
        return;

    if (renderer->func_destroy)
        renderer->func_destroy(renderer);

#if 0
    if (renderer->vertex_shader)    ALOGW("[GLES2] renderer: vertex_shader not deleted.\n");
    if (renderer->fragment_shader)  ALOGW("[GLES2] renderer: fragment_shader not deleted.\n");
    if (renderer->program)          ALOGW("[GLES2] renderer: program not deleted.\n");

    for (int i = 0; i < IJK_GLES2_MAX_PLANE; ++i) {
        if (renderer->plane_textures[i])
            ALOGW("[GLES2] renderer: plane texture[%d] not deleted.\n", i);
    }
#endif

    free(renderer);
}

void IJK_GLES2_Renderer_freeP(IJK_GLES2_Renderer **renderer)
{
    if (!renderer || !*renderer)
        return;

    IJK_GLES2_Renderer_free(*renderer);
    *renderer = NULL;
}

IJK_GLES2_Renderer *IJK_GLES2_Renderer_create_base(const char *fragment_shader_source,int openglVer)
{
    assert(fragment_shader_source);
    
    IJK_GLES2_Renderer *renderer = NULL;
    GLuint vertex_shader = 0;
    GLuint fragment_shader = 0;
    GLuint program = 0;
    
    char vsh_buffer[1024] = { '\0' };
    IJK_GLES2_getVertexShader_default(vsh_buffer,openglVer);
    
    ALOGD("vertex shader source:\n%s\n",vsh_buffer);
    ALOGD("fragment shader source:\n%s\n",fragment_shader_source);
    
    vertex_shader = IJK_GLES2_loadShader(GL_VERTEX_SHADER, vsh_buffer);
    if (!vertex_shader)
        goto fail;
    
    fragment_shader = IJK_GLES2_loadShader(GL_FRAGMENT_SHADER, fragment_shader_source);
    if (!fragment_shader)
        goto fail;

    program = glCreateProgram(); IJK_GLES2_checkError("glCreateProgram");
    if (!program)
        goto fail;

    glAttachShader(program, vertex_shader);     IJK_GLES2_checkError("glAttachShader(vertex)");
    glAttachShader(program, fragment_shader);   IJK_GLES2_checkError("glAttachShader(fragment)");
    glLinkProgram(program);                     IJK_GLES2_checkError("glLinkProgram");
    GLint link_status = GL_FALSE;
    glGetProgramiv(program, GL_LINK_STATUS, &link_status);
    if (!link_status)
        goto fail;

    renderer = (IJK_GLES2_Renderer *)calloc(1, sizeof(IJK_GLES2_Renderer));
    if (!renderer)
        goto fail;
    
    renderer->vertex_shader = vertex_shader;
    renderer->fragment_shader = fragment_shader;
    renderer->program = program;
    
    renderer->av4_position = glGetAttribLocation(renderer->program, "av4_Position");                IJK_GLES2_checkError_TRACE("glGetAttribLocation(av4_Position)");
    renderer->av2_texcoord = glGetAttribLocation(renderer->program, "av2_Texcoord");                IJK_GLES2_checkError_TRACE("glGetAttribLocation(av2_Texcoord)");
    renderer->um4_mvp      = glGetUniformLocation(renderer->program, "um4_ModelViewProjection");    IJK_GLES2_checkError_TRACE("glGetUniformLocation(um4_ModelViewProjection)");
    renderer->um3_color_conversion = -1;
    renderer->um3_rgb_adjustment = -1;
    
    return renderer;

fail:

    if (renderer && renderer->program)
        IJK_GLES2_printProgramInfo(renderer->program);

    IJK_GLES2_Renderer_free(renderer);
    
    if (vertex_shader)
        glDeleteShader(vertex_shader);
    if (fragment_shader)
        glDeleteShader(fragment_shader);
    if (program)
        glDeleteProgram(program);
    
    return NULL;
}

#ifdef __APPLE__
IJK_GLES2_Renderer *IJK_GLES2_Renderer_createApple(CVPixelBufferRef videoPicture,int openglVer)
{
    static int flag = 0;
    if (!flag) {
        IJK_GLES2_printString("Version", GL_VERSION);
        IJK_GLES2_printString("Vendor", GL_VENDOR);
        IJK_GLES2_printString("Renderer", GL_RENDERER);
        //    GLint m_nMaxTextureSize;
        //    glGetIntegerv(GL_MAX_TEXTURE_SIZE, &m_nMaxTextureSize);
        //    IJK_GLES2_printString("Extensions", GL_EXTENSIONS);
        //    IJK_GLES2_checkError("Extensions");
        flag = 1;
    }
    
    if (openglVer == 0) {
        const char *version_string = (const char *) glGetString(GL_VERSION);
        int major = 0, minor = 0;
#if TARGET_OS_OSX
        if (sscanf(version_string, "%d.%d", &major, &minor) == 2) {
            openglVer = major * 100 + minor * 10;
        } else {
            //use legacy opengl?
            openglVer = 120;
        }
#else
        if (sscanf(version_string, "OpenGL ES %d.%d", &major, &minor) == 2) {
            if (major == 2) {
                openglVer = 100;
            } else if (major == 3) {
                openglVer = 300;
            }
        } else {
            //use legacy opengl?
            openglVer = 100;
        }
#endif
    }
    //软硬解渲染统一
    IJK_GLES2_Renderer *renderer = ijk_create_common_gl_Renderer(videoPicture, openglVer);

    if (renderer) {
        glGenVertexArrays(1, &renderer->vao);
        // 创建顶点缓存对象
        glGenBuffers(1, &renderer->vbo);
        
        glBindVertexArray(renderer->vao);
        // 绑定顶点缓存对象到当前的顶点位置,之后对GL_ARRAY_BUFFER的操作即是对_VBO的操作
        // 同时也指定了_VBO的对象类型是一个顶点数据对象
        glBindBuffer(GL_ARRAY_BUFFER, renderer->vbo);
    }
    return renderer;
}

#else

IJK_GLES2_Renderer *IJK_GLES2_Renderer_create(SDL_VoutOverlay *overlay,int openglVer)
{
    IJK_GLES2_printString("Version", GL_VERSION);
    IJK_GLES2_printString("Vendor", GL_VENDOR);
    IJK_GLES2_printString("Renderer", GL_RENDERER);
//    GLint m_nMaxTextureSize;
//    glGetIntegerv(GL_MAX_TEXTURE_SIZE, &m_nMaxTextureSize);
//    IJK_GLES2_printString("Extensions", GL_EXTENSIONS);
//    IJK_GLES2_checkError("Extensions");
    if (openglVer == 0) {
        const char *version_string = (const char *) glGetString(GL_VERSION);
        int major = 0, minor = 0;
        if (sscanf(version_string, "OpenGL ES %d.%d", &major, &minor) == 2) {
            if (major == 2) {
                openglVer = 100;
            } else if (major == 3) {
                openglVer = 300;
            }
        } else {
            //use legacy opengl?
            openglVer = 100;
        }
    }
    
    IJK_GLES2_Renderer *renderer = NULL;
    
    switch (overlay->format) {
        case SDL_FCC_RV16:      renderer = IJK_GLES2_Renderer_create_rgb565(); break;
        case SDL_FCC_RV24:      renderer = IJK_GLES2_Renderer_create_rgb888(); break;
        case SDL_FCC_RV32:      renderer = IJK_GLES2_Renderer_create_rgbx8888(); break;
        case SDL_FCC_YV12:      renderer = IJK_GLES2_Renderer_create_yuv420p(); break;
        case SDL_FCC_I420:      renderer = IJK_GLES2_Renderer_create_yuv420p(); break;
        case SDL_FCC_J420:      renderer = IJK_GLES2_Renderer_create_yuv420p(); break;
        default:
            ALOGE("[GLES2] unknown format %4s(%d)\n", (char *)&overlay->format, overlay->format);
            return NULL;
    }

    if (renderer) {
        renderer->format = overlay->format;
        
        glGenVertexArrays(1, &renderer->vao);
        // 创建顶点缓存对象
        glGenBuffers(1, &renderer->vbo);
        
        glBindVertexArray(renderer->vao);
        // 绑定顶点缓存对象到当前的顶点位置,之后对GL_ARRAY_BUFFER的操作即是对_VBO的操作
        // 同时也指定了_VBO的对象类型是一个顶点数据对象
        glBindBuffer(GL_ARRAY_BUFFER, renderer->vbo);
    }
    return renderer;
}
#endif

GLboolean IJK_GLES2_Renderer_isValid(IJK_GLES2_Renderer *renderer)
{
    return renderer && renderer->program ? GL_TRUE : GL_FALSE;
}

GLboolean IJK_GLES2_Renderer_isFormat(IJK_GLES2_Renderer *renderer, int format)
{
    if (!IJK_GLES2_Renderer_isValid(renderer))
        return GL_FALSE;

    return renderer->format == format ? GL_TRUE : GL_FALSE;
}

static void IJK_GLES2_Renderer_Vertices_reset(IJK_GLES2_Renderer *renderer)
{
/*
 OpenGL 世界坐标系：
 取值范围：[-1.0,1.0]
       Y^
        |
        |
 -------o-------> X
        |
        |
*/
    //默认占满整个世界
    
    //左下
    renderer->vertices[0] = -1.0f;
    renderer->vertices[1] = -1.0f;
    //右下
    renderer->vertices[2] =  1.0f;
    renderer->vertices[3] = -1.0f;
    //左上
    renderer->vertices[4] = -1.0f;
    renderer->vertices[5] =  1.0f;
    //右上
    renderer->vertices[6] =  1.0f;
    renderer->vertices[7] =  1.0f;
}

// 视频带有旋转 90 度倍数时需要将显示宽高交换后计算
int IJK_GLES2_Renderer_NeedSwapForZAutoRotate(IJK_GLES2_Renderer *renderer)
{
    if (!renderer) {
        return 0;
    }
    return abs(renderer->auto_z_rotate_degrees) / 90 % 2 == 1 ? 1 : 0;
}

int IJK_GLES2_Renderer_isZRotate90oddMultiple(IJK_GLES2_Renderer *renderer)
{
    int total = 0;
    if (renderer->rotate_type == 3) {
        total += renderer->rotate_degrees;
    }
    
    total += renderer->auto_z_rotate_degrees;
    return abs(total) / 90 % 2 == 1 ? 1 : 0;
}

static void IJK_GLES2_Renderer_Vertices_apply(IJK_GLES2_Renderer *renderer)
{
    switch (renderer->gravity) {
        case IJK_GLES2_GRAVITY_RESIZE_ASPECT:
            break;
        case IJK_GLES2_GRAVITY_RESIZE_ASPECT_FILL:
            break;
        case IJK_GLES2_GRAVITY_RESIZE:
            IJK_GLES2_Renderer_Vertices_reset(renderer);
            return;
        default:
            ALOGE("[GLES2] unknown gravity %d\n", renderer->gravity);
            IJK_GLES2_Renderer_Vertices_reset(renderer);
            return;
    }

    float frame_width  = (float)renderer->frame_width;
    float frame_height = (float)renderer->frame_height;

    float layer_width  = (float)renderer->layer_width;
    float layer_height = (float)renderer->layer_height;
    
    if (layer_width <= 0 ||
        layer_height<= 0 ||
        frame_width <= 0 ||
        frame_height<= 0)
    {
        ALOGE("[GLES2] invalid width/height for gravity aspect\n");
        IJK_GLES2_Renderer_Vertices_reset(renderer);
        return;
    }
    
    //keep video AVRational
    if (renderer->frame_sar_num > 0 && renderer->frame_sar_den > 0) {
        frame_width = frame_width * renderer->frame_sar_num / renderer->frame_sar_den;
    }

    //when video's z rotate degrees is 90 odd multiple need swap w and h
    if (IJK_GLES2_Renderer_isZRotate90oddMultiple(renderer)) {
        float tmp = layer_width;
        layer_width = layer_height;
        layer_height = tmp;
    }
    
    //handle use define w-h ratio
    float dar_ratio = renderer->user_dar_ratio;
    if (renderer->user_dar_ratio > 0) {
        
        //when video's z rotate degrees is 90 odd multiple need swap user's ratio
        if (IJK_GLES2_Renderer_isZRotate90oddMultiple(renderer)) {
            dar_ratio = 1.0 / renderer->user_dar_ratio;
        }
        
        if (frame_width / frame_height > dar_ratio) {
            frame_height = frame_width * 1.0 / dar_ratio;
        } else {
            frame_width = frame_height * dar_ratio;
        }
    }
    
    const float ratioW  = layer_width  / frame_width;
    const float ratioH  = layer_height / frame_height;
    float ratio         = 1.0f;
    
    switch (renderer->gravity) {
        case IJK_GLES2_GRAVITY_RESIZE_ASPECT_FILL:  ratio = FFMAX(ratioW, ratioH); break;
        case IJK_GLES2_GRAVITY_RESIZE_ASPECT:       ratio = FFMIN(ratioW, ratioH); break;
    }
    
    float nW = (frame_width  * ratio / layer_width);
    float nH = (frame_height * ratio / layer_height);
    
    //左下
    renderer->vertices[0] = - nW;
    renderer->vertices[1] = - nH;
    //右下
    renderer->vertices[2] =   nW;
    renderer->vertices[3] = - nH;
    //左上
    renderer->vertices[4] = - nW;
    renderer->vertices[5] =   nH;
    //右上
    renderer->vertices[6] =   nW;
    renderer->vertices[7] =   nH;
}

GLboolean IJK_GLES2_Renderer_setGravity(IJK_GLES2_Renderer *renderer, int gravity, GLsizei layer_width, GLsizei layer_height)
{
    if (renderer->gravity != gravity && gravity >= IJK_GLES2_GRAVITY_MIN && gravity <= IJK_GLES2_GRAVITY_MAX)
        renderer->vertices_changed = 1;
    else if (renderer->layer_width != layer_width)
        renderer->vertices_changed = 1;
    else if (renderer->layer_height != layer_height)
        renderer->vertices_changed = 1;
    else
        return GL_TRUE;

    renderer->gravity      = gravity;
    renderer->layer_width  = layer_width;
    renderer->layer_height = layer_height;
    return GL_TRUE;
}

void IJK_GLES2_Renderer_updateRotate(IJK_GLES2_Renderer *renderer,int type,int degrees)
{
    int flag = 0;
    if (renderer->rotate_type != type) {
        renderer->rotate_type = type;
        flag = 1;
    }
    
    if (renderer->rotate_degrees != degrees) {
        renderer->rotate_degrees = degrees;
        flag = 1;
    }
    //need update mvp
    if (flag) {
        renderer->vertices_changed = 1;
        renderer->mvp_changed = 1;
    }
}

void IJK_GLES2_Renderer_updateSubtitleBottomMargin(IJK_GLES2_Renderer *renderer,float value)
{
    renderer->subtitle_bottom_margin = value;
}

void IJK_GLES2_Renderer_updateAutoZRotate(IJK_GLES2_Renderer *renderer,int degrees)
{
    if (renderer->auto_z_rotate_degrees != degrees) {
        renderer->auto_z_rotate_degrees = degrees;
        renderer->mvp_changed = 1;
    }
}

void IJK_GLES2_Renderer_updateUserDefinedDAR(IJK_GLES2_Renderer *renderer,float ratio)
{
    if (renderer->user_dar_ratio != ratio) {
        renderer->user_dar_ratio = ratio;
        renderer->vertices_changed = 1;
    }
}

static void IJK_GLES2_Renderer_TexCoords_cropRight(IJK_GLES2_Renderer *renderer, GLfloat cropRight)
{
    if (cropRight != 0) {
        ALOGE("IJK_GLES2_Renderer_TexCoords_cropRight:%g\n",cropRight);
    }
/*
 OpenGL 纹理坐标系：
 取值范围：[0.0,1.0]
   Y ^
     |
     |
     o-------> X
*/
    //默认将纹理贴满画布
    //左上
    renderer->texcoords[0] = 0.0f;
    renderer->texcoords[1] = 1.0f;
    //右上
    renderer->texcoords[2] = 1.0f - cropRight;
    renderer->texcoords[3] = 1.0f;
    //左下(圆点)
    renderer->texcoords[4] = 0.0f;
    renderer->texcoords[5] = 0.0f;
    //右下
    renderer->texcoords[6] = 1.0f - cropRight;
    renderer->texcoords[7] = 0.0f;
}

static void IJK_GLES2_Renderer_TexCoords_reset(IJK_GLES2_Renderer *renderer)
{
    IJK_GLES2_Renderer_TexCoords_cropRight(renderer, 0.0f);
}

static void IJK_GLES2_Renderer_Upload_Vbo_Data(IJK_GLES2_Renderer *renderer)
{
    GLfloat quadData [] = {
        renderer->vertices[0],renderer->vertices[1],
        renderer->vertices[2],renderer->vertices[3],
        renderer->vertices[4],renderer->vertices[5],
        renderer->vertices[6],renderer->vertices[7],
        //Texture Postition
        renderer->texcoords[0],renderer->texcoords[1],
        renderer->texcoords[2],renderer->texcoords[3],
        renderer->texcoords[4],renderer->texcoords[5],
        renderer->texcoords[6],renderer->texcoords[7],
    };
    
    // 绑定顶点缓存对象到当前的顶点位置,之后对GL_ARRAY_BUFFER的操作即是对_VBO的操作
    glBindBuffer(GL_ARRAY_BUFFER, renderer->vbo);
    // 将CPU数据发送到GPU,数据类型GL_ARRAY_BUFFER
    // GL_STATIC_DRAW 表示数据不会被修改,将其放置在GPU显存的更合适的位置,增加其读取速度
    glBufferData(GL_ARRAY_BUFFER, sizeof(quadData), quadData, GL_DYNAMIC_DRAW);
    
    // 指定顶点着色器位置为0的参数的数据读取方式与数据类型
    // 第一个参数: 参数位置
    // 第二个参数: 一次读取数据
    // 第三个参数: 数据类型
    // 第四个参数: 是否归一化数据
    // 第五个参数: 间隔多少个数据读取下一次数据
    // 第六个参数: 指定读取第一个数据在顶点数据中的偏移量
    glVertexAttribPointer(renderer->av4_position, 2, GL_FLOAT, GL_FALSE, 0, (void*)0);
    IJK_GLES2_checkError_TRACE("glVertexAttribPointer(av4_position)");
    //
    glEnableVertexAttribArray(renderer->av4_position);
    // texture coord attribute
    glVertexAttribPointer(renderer->av2_texcoord, 2, GL_FLOAT, GL_FALSE, 0, (void*)(8 * sizeof(float)));
    IJK_GLES2_checkError_TRACE("glVertexAttribPointer(av2_texcoord)");
    glEnableVertexAttribArray(renderer->av2_texcoord);
}

static void IJK_GLES2_updateMVP_ifNeed(IJK_GLES2_Renderer *renderer)
{
    if (renderer->mvp_changed) {
        renderer->mvp_changed = 0;
        
        if (renderer->drawingSubtitle) {
            ijk_matrix proj_matrix = IJK_GLES2_defaultOrtho();
            glUniformMatrix4fv(renderer->um4_mvp, 1, GL_FALSE, (GLfloat*)(&proj_matrix.e));                    IJK_GLES2_checkError_TRACE("glUniformMatrix4fv(um4_mvp)");
        } else {
            ijk_float3_vector rotate_v3 = { 0.0 };
            //rotate x
            if (renderer->rotate_type == 1) {
                rotate_v3.x = 1.0;
            }
            //rotate y
            else if (renderer->rotate_type == 2) {
                rotate_v3.y = 1.0;
            }
            //rotate z
            else if (renderer->rotate_type == 3) {
                rotate_v3.z = 1.0;
            }
            
            ijk_matrix rotation_matrix;
            
            float radians = radians_from_degrees(renderer->rotate_degrees);
            ijk_matrix rotation_matrix_1 = ijk_make_rotate_matrix(radians, rotate_v3);
            
            if (renderer->auto_z_rotate_degrees != 0) {
                ijk_matrix rotation_matrix_0 = ijk_make_rotate_matrix_xyz(radians_from_degrees(renderer->auto_z_rotate_degrees), 0.0, 0.0, 1.0);
                ijk_matrix_multiply(&rotation_matrix_0,&rotation_matrix_1,&rotation_matrix);
            } else {
                rotation_matrix = rotation_matrix_1;
            }
            ijk_matrix r_matrix;
            ijk_matrix proj_matrix = IJK_GLES2_defaultOrtho();
            ijk_matrix_multiply(&proj_matrix,&rotation_matrix,&r_matrix);
            glUniformMatrix4fv(renderer->um4_mvp, 1, GL_FALSE, (GLfloat*)(&r_matrix.e)); IJK_GLES2_checkError_TRACE("glUniformMatrix4fv(um4_mvp)");
        }
    }
}

/*
 * Per-Renderer routine
 */
GLboolean IJK_GLES2_Renderer_use(IJK_GLES2_Renderer *renderer)
{
    if (!renderer)
        return GL_FALSE;

    assert(renderer->func_use);
    if (!renderer->func_use(renderer))
        return GL_FALSE;
    
    renderer->rgb_adjustment[0] = 1.0;
    renderer->rgb_adjustment[1] = 1.0;
    renderer->rgb_adjustment[2] = 1.0;
    renderer->mvp_changed = 1;
    renderer->rgb_adjust_changed = 1;
    
    IJK_GLES2_Renderer_TexCoords_reset(renderer);
    IJK_GLES2_Renderer_Vertices_reset(renderer);
    IJK_GLES2_Renderer_Upload_Vbo_Data(renderer);
    IJK_GLES2_updateMVP_ifNeed(renderer);
    return GL_TRUE;
}

void* IJK_GLES2_Renderer_getVideoImage(IJK_GLES2_Renderer *renderer, SDL_VoutOverlay *overlay)
{
    if (renderer->func_getVideoImage) {
        return renderer->func_getVideoImage(renderer,overlay);
    } else {
        return NULL;
    }
}

void IJK_GLES2_Renderer_updateColorConversion(IJK_GLES2_Renderer *renderer,float brightness,float satutaion,float contrast)
{
    int changed = 0;
    if (renderer->rgb_adjustment[0] != brightness) {
        changed = 1;
        renderer->rgb_adjustment[0] = brightness;
    }
    if (renderer->rgb_adjustment[1] != satutaion) {
        changed = 1;
        renderer->rgb_adjustment[1] = satutaion;
    }
    if (renderer->rgb_adjustment[2] != contrast) {
        changed = 1;
        renderer->rgb_adjustment[2] = contrast;
    }
    
    if (changed) {
        renderer->rgb_adjust_changed = 1;
    }
}

static void IJK_GLES2_updateRGB_adjust_ifNeed(IJK_GLES2_Renderer *renderer)
{
    if (renderer->rgb_adjust_changed && renderer->um3_rgb_adjustment >= 0) {
        glUniform3fv(renderer->um3_rgb_adjustment, 1, renderer->rgb_adjustment);
        IJK_GLES2_checkError_TRACE("glUniform3fv(um3_rgb_adjustment)");
        renderer->rgb_adjust_changed = 0;
    }
}

/*
 * update video vertex
 */
GLboolean IJK_GLES2_Renderer_updateVertex(IJK_GLES2_Renderer *renderer, SDL_VoutOverlay *overlay)
{
    if (!renderer)
        return GL_FALSE;

    GLsizei visible_width = renderer->frame_width;
    if (overlay) {
        GLsizei visible_height = overlay->h;
                visible_width  = overlay->w;
        if (renderer->frame_width   != visible_width    ||
            renderer->frame_height  != visible_height   ||
            renderer->frame_sar_num != overlay->sar_num ||
            renderer->frame_sar_den != overlay->sar_den) {

            renderer->frame_width   = visible_width;
            renderer->frame_height  = visible_height;
            renderer->frame_sar_num = overlay->sar_num;
            renderer->frame_sar_den = overlay->sar_den;

            renderer->vertices_changed = 1;
        }
        
        renderer->last_buffer_width = renderer->func_getBufferWidth(renderer, overlay);
    } else {
        // NULL overlay means force reload vertice
        renderer->vertices_changed = 1;
    }
    
    GLsizei buffer_width = renderer->last_buffer_width;
    if (!renderer->vertices_changed) {
        if (buffer_width > 0 &&
             buffer_width > visible_width &&
             buffer_width != renderer->buffer_width &&
             visible_width != renderer->visible_width) {
            renderer->vertices_changed = 1;
        }
    }
    
    if (renderer->vertices_changed) {
        renderer->vertices_changed = 0;

        IJK_GLES2_Renderer_Vertices_apply(renderer);

        renderer->buffer_width  = buffer_width;
        renderer->visible_width = visible_width;

        GLsizei padding_pixels     = buffer_width - visible_width;
        GLfloat padding_normalized = ((GLfloat)padding_pixels) / buffer_width;

        IJK_GLES2_Renderer_TexCoords_cropRight(renderer, padding_normalized);
        IJK_GLES2_Renderer_Upload_Vbo_Data(renderer);
    }
    
    IJK_GLES2_updateMVP_ifNeed(renderer);
    IJK_GLES2_updateRGB_adjust_ifNeed(renderer);
    glBindVertexArray(renderer->vao); IJK_GLES2_checkError_TRACE("glBindVertexArray");

    return GL_TRUE;
}

/*
 * update video vertex
 */
GLboolean IJK_GLES2_Renderer_updateVertex2(IJK_GLES2_Renderer *renderer,
                                         int overlay_h,
                                         int overlay_w,
                                         int buffer_w,
                                         int sar_num,
                                         int sar_den)
{
    if (!renderer)
        return GL_FALSE;

    GLsizei visible_width  = renderer->frame_width;
    GLsizei visible_height = overlay_h;
            visible_width  = overlay_w;
    if (renderer->frame_width   != visible_width    ||
        renderer->frame_height  != visible_height   ||
        renderer->frame_sar_num != sar_num ||
        renderer->frame_sar_den != sar_den) {

        renderer->frame_width   = visible_width;
        renderer->frame_height  = visible_height;
        renderer->frame_sar_num = sar_num;
        renderer->frame_sar_den = sar_den;

        renderer->vertices_changed = 1;
    }
    
    renderer->last_buffer_width = buffer_w;
    
    GLsizei buffer_width = renderer->last_buffer_width;
    if (!renderer->vertices_changed) {
        if (buffer_width > 0 &&
             buffer_width > visible_width &&
             buffer_width != renderer->buffer_width &&
             visible_width != renderer->visible_width) {
            renderer->vertices_changed = 1;
        }
    }
    
    if (renderer->vertices_changed) {
        renderer->vertices_changed = 0;

        IJK_GLES2_Renderer_Vertices_apply(renderer);

        renderer->buffer_width  = buffer_width;
        renderer->visible_width = visible_width;

        GLsizei padding_pixels     = buffer_width - visible_width;
        GLfloat padding_normalized = ((GLfloat)padding_pixels) / buffer_width;

        IJK_GLES2_Renderer_TexCoords_cropRight(renderer, padding_normalized);
        IJK_GLES2_Renderer_Upload_Vbo_Data(renderer);
    }
    
    IJK_GLES2_updateMVP_ifNeed(renderer);
    IJK_GLES2_updateRGB_adjust_ifNeed(renderer);
    glBindVertexArray(renderer->vao); IJK_GLES2_checkError_TRACE("glBindVertexArray");

    return GL_TRUE;
}

/*
 * reset vao
 */
GLboolean IJK_GLES2_Renderer_resetVao(IJK_GLES2_Renderer *renderer)
{
    if (!renderer)
        return GL_FALSE;
    renderer->vertices_changed = 1;
    IJK_GLES2_Renderer_Vertices_reset(renderer);
    IJK_GLES2_Renderer_TexCoords_reset(renderer);
    IJK_GLES2_Renderer_Upload_Vbo_Data(renderer);
    IJK_GLES2_updateMVP_ifNeed(renderer);
    IJK_GLES2_updateRGB_adjust_ifNeed(renderer);
    glBindVertexArray(renderer->vao); IJK_GLES2_checkError_TRACE("glBindVertexArray");
    return GL_TRUE;
}

/*
 * upload video texture
 */
GLboolean IJK_GLES2_Renderer_uploadTexture(IJK_GLES2_Renderer *renderer, void *picture)
{
    if (!renderer || !renderer->func_uploadTexture)
        return GL_FALSE;
    
    assert(!renderer->drawingSubtitle);
    
    if (!renderer->func_uploadTexture(renderer, picture))
        return GL_FALSE;
    
    return GL_TRUE;
}

void IJK_GLES2_Renderer_updateHdrAnimationProgress(IJK_GLES2_Renderer *renderer, float per)
{
    if (!renderer || !renderer->func_updateHDRAnimation)
        return;

    renderer->func_updateHDRAnimation(renderer, per);
}

void IJK_GLES2_Renderer_drawArrays(void)
{
    glDrawArrays(GL_TRIANGLE_STRIP, 0, 4); IJK_GLES2_checkError_TRACE("glDrawArrays");
}

void IJK_GLES2_Renderer_beginDrawSubtitle(IJK_GLES2_Renderer *renderer)
{
    if (!renderer->drawingSubtitle) {
        if (renderer->func_useSubtitle) {
            renderer->func_useSubtitle(renderer, GL_TRUE);
        }
        renderer->drawingSubtitle = 1;
        //need change mvp for draw subtitle.
        renderer->mvp_changed = 1;
    }
}

void IJK_GLES2_Renderer_endDrawSubtitle(IJK_GLES2_Renderer *renderer)
{
    if (renderer->drawingSubtitle) {
        if (renderer->func_useSubtitle) {
            renderer->func_useSubtitle(renderer, GL_FALSE);
        }
        renderer->drawingSubtitle = 0;
        //need change mvp for draw picture.
        renderer->mvp_changed = 1;
    }
}

/*
 * upload subtitle texture
 */
GLboolean IJK_GLES2_Renderer_uploadSubtitleTexture(IJK_GLES2_Renderer *renderer, int texture, int w, int h)
{
    if (!renderer || !renderer->func_uploadSubtitle)
        return GL_FALSE;
    
    assert(renderer->drawingSubtitle);
    
    if (!renderer->func_uploadSubtitle(renderer, texture, w, h))
        return GL_FALSE;
    
    return GL_TRUE;
}

/*
 * update subtitle vertex
 */
void IJK_GLES2_Renderer_updateSubtitleVertex(IJK_GLES2_Renderer *renderer, float width, float height)
{
    glEnable(GL_BLEND);
    glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);
    
    //字幕图片在纹理坐标系上的尺寸
    float ratioW = 1.0 * width / renderer->layer_width;
    float ratioH = 1.0 * height / renderer->layer_height;
    
    float leftX  = 0 - ratioW;
    float rightX = 0 + ratioW;
    //距离底部0.1，实际是 (0.1 * layer_height)px; [-1,1]
    float margin = (renderer->subtitle_bottom_margin - 1) * 2 + 1;
    margin = FFMAX(margin, -1.0);
    margin = FFMIN(margin, 1.0 - 2 * ratioH);
    float bottomY = margin;
    float topY = bottomY + 2 * ratioH;
    
    //左下
    renderer->vertices[0] = leftX;
    renderer->vertices[1] = bottomY;
    //右下
    renderer->vertices[2] = rightX;
    renderer->vertices[3] = bottomY;
    //左上
    renderer->vertices[4] = leftX;
    renderer->vertices[5] = topY;
    //右上
    renderer->vertices[6] = rightX;
    renderer->vertices[7] = topY;
    
    //标记下，渲染视频的时候能修正回来；
    renderer->vertices_changed = 1;
    IJK_GLES2_Renderer_TexCoords_reset(renderer);
    IJK_GLES2_Renderer_Upload_Vbo_Data(renderer);
    
    IJK_GLES2_updateMVP_ifNeed(renderer);
}
