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

typedef struct FF_ASS_Context {
    const AVClass *priv_class;
    ASS_Library  *library;
    ASS_Renderer *renderer;
    ASS_Track    *track;
    
    char *fontsdir;
    char *charenc;
    char *force_style;
    int stream_index;
    int alpha;
    int original_w, original_h;
    int shaping;
} FF_ASS_Context;

#define OFFSET(x) offsetof(FF_ASS_Context, x)
#define FLAGS AV_OPT_FLAG_VIDEO_PARAM
    
const AVOption ff_ass_options[] = {
    {"fontsdir",       "set the directory containing the fonts to read",           OFFSET(fontsdir),   AV_OPT_TYPE_STRING,     {.str = NULL},  0, 0, FLAGS },
    {"alpha",          "enable processing of alpha channel",                       OFFSET(alpha),      AV_OPT_TYPE_BOOL,       {.i64 = 0   },         0,        1, FLAGS },
    {"charenc",      "set input character encoding", OFFSET(charenc),      AV_OPT_TYPE_STRING, {.str = NULL}, 0, 0, FLAGS},
    {"stream_index", "set stream index",             OFFSET(stream_index), AV_OPT_TYPE_INT,    { .i64 = -1 }, -1,       INT_MAX,  FLAGS},
    {"si",           "set stream index",             OFFSET(stream_index), AV_OPT_TYPE_INT,    { .i64 = -1 }, -1,       INT_MAX,  FLAGS},
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
    
    return 0;
}

static void set_video_size(FF_ASS_Renderer *s, int w, int h)
{
    FF_ASS_Context *ass = s->priv_data;
    if (!ass) {
        return;
    }
    //放大两倍，使得 retina 屏显示清楚
    w *= 2;
    h *= 2;

    ass->original_w = w;
    ass->original_h = h;
    
    ass_set_frame_size(ass->renderer, w, h);
    ass_set_storage_size(ass->renderer, w, h);
    ass_set_font_scale(ass->renderer, 1.0);
    ass_set_cache_limits(ass->renderer, 3, 0);
    
//    ass_set_pixel_aspect(ass->renderer, (double)w / h /
//                         ((double)ass->original_w / ass->original_h));
//    if (ass->shaping != -1)
//        ass_set_shaper(ass->renderer, ass->shaping);
    
    ass_set_shaper(ass->renderer, ASS_SHAPING_COMPLEX);
}

static void draw_ass_rgba(unsigned char *src, int src_w, int src_h,
                          int src_stride, unsigned char *dst, size_t dst_stride,
                          int dst_x, int dst_y, uint32_t color)
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
            uint32_t dstr =  dstpix        & 0xFF;
            uint32_t dstg = (dstpix >>  8) & 0xFF;
            uint32_t dstb = (dstpix >> 16) & 0xFF;
            uint32_t dsta = (dstpix >> 24) & 0xFF;
            
            dstr = COLOR_BLEND(sa, sr, dstr);
            dstg = COLOR_BLEND(sa, sg, dstg);
            dstb = COLOR_BLEND(sa, sb, dstb);
            dsta = COLOR_BLEND(sa, 255, dsta);
            
            dstrow[x] = dstr | (dstg << 8) | (dstb << 16) | (dsta << 24);
            
        }
        dst += dst_stride;
        src += src_stride;
    }
    #undef COLOR_BLEND
}

static void blend_single(FFSubtitleBuffer * frame, ASS_Image *img, int layer)
{
    if (img->w == 0 || img->h == 0)
        return;
    //printf("blend %d rect:{%d,%d}{%d,%d}\n", layer, img->dst_x, img->dst_y, img->w, img->h);
    unsigned char *dst = frame->buffer;
    dst += img->dst_y * frame->stride + img->dst_x * 4;
    draw_ass_rgba(img->bitmap, img->w, img->h, img->stride, dst, frame->stride, img->dst_x, img->dst_y, img->color);
}

static void peek_alpha(unsigned char *src, int src_w, int src_h, int src_stride)
{
    uint32_t *dstrow = (uint32_t *) src;
    printf("-------------alpha-------------\n");
    for (int y = 0; y < src_h; y++) {
        for (int x = 0; x < src_w/4; x++) {
            
            uint32_t dstpix = dstrow[x];
            uint32_t dsta = (dstpix >> 24) & 0xFF;
            
            if (dsta != 255 && dsta != 0) {
                printf("%d,",dsta);
            }
        }
        printf("\n");
        dstrow += src_stride/4;
    }
}

static void blend(FFSubtitleBuffer * frame, ASS_Image *img)
{
    int cnt = 0;
    while (img) {
        ++cnt;
        blend_single(frame, img, cnt);
        img = img->next;
    }
    //peek_alpha(frame->buffer, frame->width, frame->height, frame->stride);
}

static FFSubtitleBuffer* render_frame(FF_ASS_Renderer *s, double time_ms, int changed_only)
{
    FF_ASS_Context *ass = s->priv_data;
    if (!ass) {
        return NULL;
    }
    int changed;
    ASS_Image *imgs = ass_render_frame(ass->renderer, ass->track, time_ms, &changed);
    
    if (changed_only && changed == 0) {
        return NULL;
    }
    
    if (imgs) {
        FFSubtitleBuffer* buff = ff_gen_subtitle_image(ass->original_w, ass->original_h, 4);
        buff->usedAss = 1;
        blend(buff, imgs);
        return buff;
    } else {
        av_log(NULL, AV_LOG_ERROR, "ass_render_frame NULL at time ms:%f\n", time_ms);
        return NULL;
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

static int set_stream(FF_ASS_Renderer *s, AVStream *st, uint8_t *subtitle_header, int subtitle_header_size)
{
    FF_ASS_Context *ass = s->priv_data;
    if (!ass) {
        return AVERROR(EINVAL);
    }
    
    /* Load attached fonts */
    if (st->codecpar->codec_type == AVMEDIA_TYPE_ATTACHMENT &&
        attachment_is_font(st)) {
        const AVDictionaryEntry *tag = av_dict_get(st->metadata, "filename", NULL,
                          AV_DICT_MATCH_CASE);

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

    ass_set_fonts(ass->renderer, NULL, "sans-serif", ASS_FONTPROVIDER_AUTODETECT, NULL, 1);
    
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
    printf("ass_process_chunk:%s\n", ass_line);
    ass_process_chunk(ass->track, ass_line, (int)strlen(ass_line), start_time, duration);
}

static void update_margin(FF_ASS_Renderer *s, int t, int b, int l, int r)
{
    FF_ASS_Context *ass = s->priv_data;
    if (!ass || !ass->renderer) {
        return;
    }
    ass_set_margins(ass->renderer, t, b, l, r);
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
    .priv_class     = &subtitles_class,
    .priv_data_size = sizeof(FF_ASS_Context),
    .init           = init_libass,
    .set_stream     = set_stream,
    .set_video_size = set_video_size,
    .process_chunk  = process_chunk,
    .render_frame   = render_frame,
    .update_margin  = update_margin,
    .uninit         = uninit,
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
        ffAss_destroy(&r);
        return NULL;
    }
    return r;
}

FF_ASS_Renderer *ffAss_create_default(AVStream *st, uint8_t *subtitle_header, int subtitle_header_size, int video_w, int video_h, AVDictionary *opts)
{
    FF_ASS_Renderer_Format* format = &ff_ass_default_format;
    FF_ASS_Renderer* r = ffAss_create_with_format(format, opts);
    if (r) {
        r->iformat->set_stream(r, st, subtitle_header, subtitle_header_size);
        r->iformat->set_video_size(r, video_w, video_h);
    }
    return r;
}

void ffAss_destroy(FF_ASS_Renderer **sp)
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
