//
//  ff_ass_steam_renderer.c
//  IJKMediaPlayerKit
//
//  Created by Reach Matt on 2024/3/5.
//

#include "ff_ass_steam_renderer.h"
#include "libavcodec/avcodec.h"
#include "libavformat/avformat.h"
#include "libavutil/avstring.h"
#include "libavutil/imgutils.h"
#include "libavutil/opt.h"
#include "libavutil/parseutils.h"
#include "ff_subtitle_def.h"
#include "ijksdl/ijksdl_gpu.h"
#include "ff_subtitle_def_internal.h"

typedef struct FF_ASS_Context {
    const AVClass *priv_class;
    ASS_Library  *library;
    ASS_Renderer *renderer;
    ASS_Track    *track;
    
    char *fontsdir;
    char *charenc;
    char *force_style;
    int original_w, original_h;
    int shaping;
    int bottom_margin;
    int force_changed;
} FF_ASS_Context;

#define OFFSET(x) offsetof(FF_ASS_Context, x)
#define FLAGS AV_OPT_FLAG_VIDEO_PARAM
    
const AVOption ff_ass_options[] = {
    {"fontsdir",       "set the directory containing the fonts to read",           OFFSET(fontsdir),   AV_OPT_TYPE_STRING,     {.str = NULL},  0, 0, FLAGS },
    {"charenc",      "set input character encoding", OFFSET(charenc),      AV_OPT_TYPE_STRING, {.str = NULL}, 0, 0, FLAGS},
    {"force_style",  "force subtitle style",         OFFSET(force_style),  AV_OPT_TYPE_STRING, {.str = NULL}, 0, 0, FLAGS},
    {NULL},
};

/* libass supports a log level ranging from 0 to 7 */
static const int ass_libavfilter_log_level_map[] = {
    [0] = AV_LOG_FATAL,     /* MSGL_FATAL */
    [1] = AV_LOG_ERROR,     /* MSGL_ERR */
    [2] = AV_LOG_WARNING,   /* MSGL_WARN */
    [3] = AV_LOG_WARNING,   /* <undefined> */
    [4] = AV_LOG_INFO,      /* MSGL_INFO */
    [5] = AV_LOG_INFO,      /* <undefined> */
    [6] = AV_LOG_VERBOSE,   /* MSGL_V */
    [7] = AV_LOG_DEBUG,     /* MSGL_DBG2 */
};

static void ass_log(int ass_level, const char *fmt, va_list args, void *ctx)
{
    const int ass_level_clip = av_clip(ass_level, 0,
        FF_ARRAY_ELEMS(ass_libavfilter_log_level_map) - 1);
    int level = ass_libavfilter_log_level_map[ass_level_clip];
    //level = AV_LOG_ERROR;
    const char *prefix = "[ass] ";
    char *tmp = av_asprintf("%s%s", prefix, fmt);
    av_vlog(ctx, level, tmp, args);
}

/* Init libass */

static int init_libass(FF_ASS_Renderer *s)
{
    FF_ASS_Context *ass = s->priv_data;
    if (!ass) {
        return -1;
    }
    
    ass->library = ass_library_init();
    if (!ass->library) {
        av_log(ass, AV_LOG_ERROR, "Could not initialize libass.\n");
        return AVERROR(EINVAL);
    }
    
    ass_set_message_cb(ass->library, ass_log, ass);
    ass_set_fonts_dir(ass->library, ass->fontsdir);
    ass_set_extract_fonts(ass->library, 1);
    ass->renderer = ass_renderer_init(ass->library);
    
    if (!ass->renderer) {
        av_log(ass, AV_LOG_ERROR, "Could not initialize libass renderer.\n");
        return AVERROR(EINVAL);
    }

    ass->track = ass_new_track(ass->library);
    if (!ass->track) {
        av_log(s, AV_LOG_ERROR, "Could not create a libass track\n");
        return AVERROR(EINVAL);
    }
    
    ass->track->track_type = TRACK_TYPE_ASS;
    return 0;
}

static void set_video_size(FF_ASS_Renderer *s, int w, int h)
{
    FF_ASS_Context *ass = s->priv_data;
    if (!ass) {
        return;
    }
    
    ass->original_w = w;
    ass->original_h = h;
    
    ass_set_frame_size(ass->renderer, w, h);
    ass_set_storage_size(ass->renderer, w, h);
    ass_set_font_scale(ass->renderer, 1.0);
    ass_set_cache_limits(ass->renderer, 3, 0);
    ass_set_line_spacing( ass->renderer, 0.0);
//    ass_set_pixel_aspect(ass->renderer, (double)w / h /
//                         ((double)ass->original_w / ass->original_h));
//    if (ass->shaping != -1)
//        ass_set_shaper(ass->renderer, ass->shaping);
    
    ass_set_shaper(ass->renderer, ASS_SHAPING_COMPLEX);
}

static void draw_ass_bgra(unsigned char *src, int src_w, int src_h,
                          int src_stride, unsigned char *dst, size_t dst_stride,
                          uint32_t color)
{
    const unsigned int sr = (color >> 24) & 0xff;
    const unsigned int sg = (color >> 16) & 0xff;
    const unsigned int sb = (color >>  8) & 0xff;
    const unsigned int _sa = 0xff - (color & 0xff);

    #define COLOR_BLEND(_sa,_sc,_dc) ((_sc * _sa + _dc * (65025 - _sa)) >> 16 & 0xFF)
    
    for (int y = 0; y < src_h; y++) {
        uint32_t *dstrow = (uint32_t *) dst;
        for (int x = 0; x < src_w; x++) {
            const uint32_t sa = _sa * src[x];
            
            uint32_t dstpix = dstrow[x];
            uint32_t dstb =  dstpix        & 0xFF;
            uint32_t dstg = (dstpix >>  8) & 0xFF;
            uint32_t dstr = (dstpix >> 16) & 0xFF;
            uint32_t dsta = (dstpix >> 24) & 0xFF;
            
            dstr = COLOR_BLEND(sa, sr, dstr);
            dstg = COLOR_BLEND(sa, sg, dstg);
            dstb = COLOR_BLEND(sa, sb, dstb);
            dsta = COLOR_BLEND(sa, 255, dsta);
            
            dstrow[x] = dstb | (dstg << 8) | (dstr << 16) | (dsta << 24);
        }
        dst += dst_stride;
        src += src_stride;
    }
    #undef COLOR_BLEND
}

static void draw_single_inset(FFSubtitleBuffer * frame, ASS_Image *img, int layer, int insetx, int insety, int bottom_margin)
{
    if (img->w == 0 || img->h == 0)
        return;
    unsigned char *dst = frame->data;
    int y = img->dst_y - insety - bottom_margin;
    if (y < 0) {
        y = 0;
    }
    dst += y * frame->rect.stride + (img->dst_x - insetx) * 4;
    draw_ass_bgra(img->bitmap, img->w, img->h, img->stride, dst, frame->rect.stride, img->color);
}

static int upload_buffer(FF_ASS_Renderer *s, double time_ms, FFSubtitleBuffer **buffer)
{
    FF_ASS_Context *ass = s->priv_data;
    if (!ass || !buffer) {
        return -1;
    }
    
    int changed;
    ASS_Image *imgs = ass_render_frame(ass->renderer, ass->track, time_ms, &changed);

    if (changed == 0 && !ass->force_changed) {
        return 0;
    }
    ass->force_changed = 0;
    
    if (imgs) {
        int bm = ass->bottom_margin;
        int water_mark = ass->original_h * SUBTITLE_MOVE_WATERMARK;
        ASS_Image *img = imgs;
        SDL_Rectangle dirtyRect = {0};
        while (img) {
            int y = img->dst_y;
            if (y > water_mark) {
                y -= bm;
                if (y < 0) {
                    y = 0;
                }
            }
            SDL_Rectangle t = {img->dst_x, y, img->w, img->h};
            dirtyRect = SDL_union_rectangle(dirtyRect, t);
            img = img->next;
        }
        
        FFSubtitleBuffer* frame = ff_subtitle_buffer_alloc_rgba32(dirtyRect);
        dirtyRect.stride = frame->rect.stride;
        
        int cnt = 0;
        while (imgs) {
            ++cnt;
            int offset = 0;
            if (imgs->dst_y > water_mark) {
                offset = bm;
            }
            draw_single_inset(frame, imgs, cnt, dirtyRect.x, dirtyRect.y, offset);
            imgs = imgs->next;
        }
        *buffer = frame;
        return 1;
    } else {
        av_log(NULL, AV_LOG_ERROR, "ass_render_frame NULL at time ms:%f\n", time_ms);
        return -2;
    }
}

static const char * const font_mimetypes[] = {
    "font/ttf",
    "font/otf",
    "font/sfnt",
    "font/woff",
    "font/woff2",
    "application/font-sfnt",
    "application/font-woff",
    "application/x-truetype-font",
    "application/vnd.ms-opentype",
    "application/x-font-ttf",
    NULL
};

static int attachment_is_font(AVStream * st)
{
    const AVDictionaryEntry *tag = av_dict_get(st->metadata, "mimetype", NULL, AV_DICT_MATCH_CASE);
    if (tag) {
        for (int n = 0; font_mimetypes[n]; n++) {
            if (av_strcasecmp(font_mimetypes[n], tag->value) == 0)
                return 1;
        }
    }
    return 0;
}

static void set_attach_font(FF_ASS_Renderer *s, AVStream *st)
{
    FF_ASS_Context *ass = s->priv_data;
    if (!ass) {
        return;
    }
    
    /* Load attached fonts */
    if (st->codecpar->codec_type == AVMEDIA_TYPE_ATTACHMENT &&
        attachment_is_font(st)) {
        const AVDictionaryEntry *tag = av_dict_get(st->metadata, "filename", NULL, AV_DICT_MATCH_CASE);
        if (tag) {
            av_log(s, AV_LOG_DEBUG, "Loading attached font: %s\n",
                   tag->value);
            ass_add_font(ass->library, tag->value,
                         (char *)st->codecpar->extradata,
                         st->codecpar->extradata_size);
        } else {
            av_log(s, AV_LOG_WARNING,
                   "Font attachment has no filename, ignored.\n");
        }
    }
}

static int set_subtitle_header(FF_ASS_Renderer *s, uint8_t *subtitle_header, int subtitle_header_size)
{
    FF_ASS_Context *ass = s->priv_data;
    if (!ass) {
        return AVERROR(EINVAL);
    }
    
    //"sans-serif"
    ass_set_fonts(ass->renderer, NULL, "Helvetica Neue", ASS_FONTPROVIDER_AUTODETECT, NULL, 1);
    /* Anything else than NONE will break smooth img updating.
          TODO: List and force ASS_HINTING_LIGHT for known problematic fonts */
    ass_set_hinting( ass->renderer, ASS_HINTING_NONE );
    
    int ret = 0;
    //ass->force_style = "MarginV=50";
    if (ass->force_style) {
        char **list = NULL;
        char *temp = NULL;
        char *ptr = av_strtok(ass->force_style, ",", &temp);
        int i = 0;
        while (ptr) {
            av_dynarray_add(&list, &i, ptr);
            if (!list) {
                ret = AVERROR(ENOMEM);
                goto end;
            }
            ptr = av_strtok(NULL, ",", &temp);
        }
        av_dynarray_add(&list, &i, NULL);
        if (!list) {
            ret = AVERROR(ENOMEM);
            goto end;
        }
        ass_set_style_overrides(ass->library, list);
        av_free(list);
    }
    /* Decode subtitles and push them into the renderer (libass) */
    if (subtitle_header && subtitle_header_size > 0)
        ass_process_codec_private(ass->track,
                                  (char *)subtitle_header,
                                  subtitle_header_size);
end:
    
    return ret;
}

static void process_chunk(FF_ASS_Renderer *s, char *ass_line, long long start_time, long long duration)
{
    FF_ASS_Context *ass = s->priv_data;
    if (!ass) {
        return;
    }
    ass_process_chunk(ass->track, ass_line, (int)strlen(ass_line), start_time, duration);
}

static void update_bottom_margin(FF_ASS_Renderer *s, int b)
{
    FF_ASS_Context *ass = s->priv_data;
    if (!ass || !ass->renderer) {
        return;
    }
    //设置后字体会被压缩变形
    //ass_set_margins(ass->renderer, 0, b, 0, 0);
    ass->bottom_margin = b;
    ass->force_changed = 1;
}

static void set_font_scale(FF_ASS_Renderer *s, double scale)
{
    FF_ASS_Context *ass = s->priv_data;
    if (!ass || !ass->renderer) {
        return;
    }
    ass_set_font_scale(ass->renderer, scale);
}

static void uninit(FF_ASS_Renderer *s)
{
    FF_ASS_Context *ass = s->priv_data;
    if (!ass) {
        return;
    }
    if (ass->track)
        ass_free_track(ass->track);
    if (ass->renderer)
        ass_renderer_done(ass->renderer);
    if (ass->library)
        ass_library_done(ass->library);
}

static void *ass_context_child_next(void *obj, void *prev)
{
    return NULL;
}

static const AVClass subtitles_class = {
    .class_name = "ff_ass_subtitles",
    .item_name  = av_default_item_name,
    .option     = ff_ass_options,
    .version    = LIBAVUTIL_VERSION_INT,
    .child_next = ass_context_child_next,
};

FF_ASS_Renderer_Format ff_ass_default_format = {
    .priv_class         = &subtitles_class,
    .priv_data_size     = sizeof(FF_ASS_Context),
    .init               = init_libass,
    .set_subtitle_header= set_subtitle_header,
    .set_attach_font    = set_attach_font,
    .set_video_size     = set_video_size,
    .process_chunk      = process_chunk,
    .upload_buffer      = upload_buffer,
    .update_bottom_margin= update_bottom_margin,
    .set_font_scale     = set_font_scale,
    .uninit             = uninit,
};

static FF_ASS_Renderer *ffAss_create_with_format(FF_ASS_Renderer_Format* format, AVDictionary *opts)
{
    FF_ASS_Renderer *r = av_mallocz(sizeof(FF_ASS_Renderer));
    r->priv_data = av_mallocz(format->priv_data_size);
    if (!r->priv_data) {
        av_log(NULL, AV_LOG_ERROR, "ffAss_create:AVERROR(ENOMEM)");
        return NULL;
    }
    r->iformat = format;
    if (format->priv_class) {
        //非FF_ASS_Context的首地址，也就是第一个变量的地址赋值
        *(const AVClass**)r->priv_data = format->priv_class;
        av_opt_set_defaults(r->priv_data);
    }
    if (opts) {
        av_opt_set_dict(r->priv_data, &opts);
    }
    
    if (format->init(r)) {
        ff_ass_render_release(&r);
        return NULL;
    }
    r->refCount = 1;
    return r;
}

FF_ASS_Renderer *ff_ass_render_create_default(uint8_t *subtitle_header, int subtitle_header_size, int video_w, int video_h, AVDictionary *opts)
{
    FF_ASS_Renderer_Format* format = &ff_ass_default_format;
    FF_ASS_Renderer* r = ffAss_create_with_format(format, opts);
    if (r) {
        r->iformat->set_subtitle_header(r, subtitle_header, subtitle_header_size);
        r->iformat->set_video_size(r, video_w, video_h);
    }
    return r;
}

static void _destroy(FF_ASS_Renderer **sp)
{
    if (!sp) return;
    FF_ASS_Renderer *s = *sp;
    
    if (s->iformat->uninit) {
        s->iformat->uninit(s);
    }
    
    if (s->iformat->priv_data_size)
        av_opt_free(s->priv_data);
    av_freep(&s->priv_data);
    av_freep(sp);
}

FF_ASS_Renderer * ff_ass_render_retain(FF_ASS_Renderer *ar)
{
    if (ar) {
        __atomic_add_fetch(&ar->refCount, 1, __ATOMIC_RELEASE);
    }
    return ar;
}

void ff_ass_render_release(FF_ASS_Renderer **arp)
{
    if (arp) {
        FF_ASS_Renderer *sb = *arp;
        if (sb) {
            if (__atomic_add_fetch(&sb->refCount, -1, __ATOMIC_RELEASE) == 0) {
                _destroy(arp);
            }
        }
    }
}

int ff_ass_upload_buffer(FF_ASS_Renderer * assRenderer, float begin, FFSubtitleBuffer ** buffer)
{
    return assRenderer->iformat->upload_buffer(assRenderer, begin * 1000, buffer);
}

void ff_ass_process_chunk(FF_ASS_Renderer * assRenderer, const char *ass_line, float begin, float end)
{
    assRenderer->iformat->process_chunk(assRenderer, (char *)ass_line, begin, end);
}
