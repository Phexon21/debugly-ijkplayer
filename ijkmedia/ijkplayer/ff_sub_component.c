//
//  ff_sub_component.c
//  IJKMediaPlayerKit
//
//  Created by Reach Matt on 2022/5/24.
//

#include "ff_sub_component.h"
#include "ff_frame_queue.h"
#include "ff_packet_list.h"
#include "ff_ass_renderer.h"
#include "ijksdl/ijksdl_gpu.h"
#include "ff_subtitle_def_internal.h"

#define SUB_MAX_KEEP_DU 3.0
#define ASS_USE_PRE_RENDER 1
#define CACHE_ASS_IMG_COUNT 6
#define A_ASS_IMG_DURATION 0.05

typedef struct FFSubComponent{
    int st_idx;
    PacketQueue* packetq;
    Decoder decoder;
    FrameQueue* frameq;
    subComponent_retry_callback retry_callback;
    void *retry_opaque;
    FF_ASS_Renderer *assRenderer;
    int bitmapRenderer;
    int video_width, video_height;
    int sub_width, sub_height;
    FFSubtitleBufferPacket sub_buffer_array;
    IJKSDLSubtitlePreference sp;
    int sp_changed;
    float current_pts;
    float pkt_pts;
    float pre_load_pts;
    float startTime;
}FFSubComponent;

static void apply_preference(FFSubComponent *com)
{
    if (com->assRenderer) {
        int b = com->sp.bottomMargin * com->sub_height;
        com->assRenderer->iformat->update_bottom_margin(com->assRenderer, b);
        com->assRenderer->iformat->set_font_scale(com->assRenderer, com->sp.scale);
        com->sp_changed = 0;
    }
}

#if ASS_USE_PRE_RENDER
static int pre_render_ass_frame(FFSubComponent *com, int serial)
{
    if (com->bitmapRenderer) {
        return -1;
    }
    
    if (com->pre_load_pts < 0) {
        if (com->current_pts >= 0) {
            com->pre_load_pts = com->current_pts;
        }
    }
    
    if (com->sp_changed) {
        while (frame_queue_nb_remaining(com->frameq) > 0) {
            Frame *af = frame_queue_peek_readable(com->frameq);
            if (af) {
                frame_queue_next(com->frameq);
            } else {
                break;
            }
        }
        if (com->current_pts >= 0) {
            //let the pts can display right now.
            com->pre_load_pts = com->current_pts - A_ASS_IMG_DURATION;
        }
        apply_preference(com);
    }
    
    if (com->pre_load_pts < 0) {
        return -1;
    }
    
    if (frame_queue_nb_remaining(com->frameq) >= CACHE_ASS_IMG_COUNT) {
        return -1;
    }
    
    //pre load need limit range
    if (com->pre_load_pts - com->current_pts > (SUB_MAX_KEEP_DU * CACHE_ASS_IMG_COUNT) || com->pre_load_pts > com->pkt_pts) {
        return -1;
    }
    FFSubtitleBuffer *pre_buffer = NULL;
    FF_ASS_Renderer *assRenderer = ff_ass_render_retain(com->assRenderer);
    int result = 0;
    while (com->packetq->abort_request == 0) {
        FFSubtitleBuffer *buffer = NULL;
        float delta = com->current_pts - com->pre_load_pts;
        if (delta > A_ASS_IMG_DURATION) {
            //subtitle is slower than video, so need fast forward
            com->pre_load_pts = com->current_pts + 0.2;
            Frame *sp = frame_queue_peek_offset(com->frameq, 0);
            double pts = sp ? sp->pts : -1;
            av_log(NULL, AV_LOG_WARNING, "subtitle is slower than video:%fs,cache:%d,%f",delta,frame_queue_nb_remaining(com->frameq),pts);
        }
        double pts = com->pre_load_pts;
        int r = ff_ass_upload_buffer(com->assRenderer, pts, &buffer, 0);
        if (r == 0) {
            //no change, reuse pre frame
            if (!pre_buffer) {
                Frame *lastFrame = frame_queue_peek_pre_writable(com->frameq);
                if (lastFrame) {
                    pre_buffer = ff_subtitle_buffer_retain(lastFrame->sub_list[0]);
                }
                if (!pre_buffer) {
                    ff_ass_upload_buffer(com->assRenderer, pts, &pre_buffer, 1);
                    if (pre_buffer) {
                        av_log(NULL, AV_LOG_DEBUG, "pre frame is nil, uploaded from ass render.\n");
                    }
                }
            }
            buffer = ff_subtitle_buffer_retain(pre_buffer);
        } else if (r > 0) {
            // buffer is new.
            if (pre_buffer) {
                ff_subtitle_buffer_release(&pre_buffer);
            }
            pre_buffer = ff_subtitle_buffer_retain(buffer);
        } else {
            //clean
            com->pre_load_pts += A_ASS_IMG_DURATION;
            result = -1;
            break;
        }
        if (!buffer) {
            com->pre_load_pts += A_ASS_IMG_DURATION;
            result = -1;
            break;
        }
        
        Frame *sp = frame_queue_peek_writable_noblock(com->frameq);
        if (!sp) {
            ff_subtitle_buffer_release(&buffer);
            result = -2;
            break;
        }
        com->pre_load_pts += A_ASS_IMG_DURATION;
        sp->pts = pts;
        sp->duration = A_ASS_IMG_DURATION;
        sp->serial = serial;
        sp->width  = com->sub_width;
        sp->height = com->sub_height;
        sp->shown = 0;
        sp->sub_list[0] = buffer;
        
        int size = frame_queue_push(com->frameq);
        
        if (size > CACHE_ASS_IMG_COUNT) {
            break;
        } else {
            continue;
        }
    }
    ff_subtitle_buffer_release(&pre_buffer);
    ff_ass_render_release(&assRenderer);
    return result;
}
#endif

static int decode_a_frame(FFSubComponent *com, Decoder *d, AVSubtitle *pkt)
{
    int ret = AVERROR(EAGAIN);

    for (;com->packetq->abort_request == 0;) {
        
        if (d->packet_pending) {
            d->packet_pending = 0;
        } else {
            int old_serial = d->pkt_serial;
            int get_pkt = packet_queue_get(d->queue, d->pkt, 0, &d->pkt_serial);
            //av_log(NULL, AV_LOG_ERROR, "sub packet_queue_get:%d\n",get_pkt);
            if (get_pkt < 0)
                return -1;
            if (get_pkt == 0) {
                int r = 1;
#if ASS_USE_PRE_RENDER
                r = pre_render_ass_frame(com, old_serial);
#endif
                if (r) {
                    av_usleep(1000 * 10);
                }
                continue;
            }
            
            if (d->pkt->stream_index != com->st_idx) {
                av_packet_unref(d->pkt);
                continue;
            }
            if (old_serial != d->pkt_serial) {
                avcodec_flush_buffers(d->avctx);
                d->finished = 0;
                d->next_pts = d->start_pts;
                d->next_pts_tb = d->start_pts_tb;
                ff_ass_flush_events(com->assRenderer);
                while (frame_queue_nb_remaining(com->frameq) > 0) {
                    Frame *af = frame_queue_peek_readable(com->frameq);
                    if (af && af->serial != d->pkt_serial) {
                        frame_queue_next(com->frameq);
                    } else {
                        break;
                    }
                }
                com->pre_load_pts = -1;
                com->current_pts = -1;
                com->pkt_pts = -1;
                av_log(NULL, AV_LOG_INFO, "sub flush serial:%d\n",d->pkt_serial);
            }
        }
        if (d->queue->serial != d->pkt_serial)
        {
            av_packet_unref(d->pkt);
            continue;
        }

        int got_frame = 0;
        
        //av_log(NULL, AV_LOG_ERROR, "sub stream decoder pkt serial:%d,pts:%lld\n",d->pkt_serial,pkt->pts/1000);
        ret = avcodec_decode_subtitle2(d->avctx, pkt, &got_frame, d->pkt);
        if (ret >= 0) {
            if (got_frame && !d->pkt->data) {
                d->packet_pending = 1;
            }
            ret = got_frame ? 0 : (d->pkt->data ? AVERROR(EAGAIN) : AVERROR_EOF);
        }
        av_packet_unref(d->pkt);
        //Invalid UTF-8 in decoded subtitles text; maybe missing -sub_charenc option
        if (ret == AVERROR_INVALIDDATA) {
            return -1000;
        } else if (ret == -92) {
            //iconv convert failed
            return -1000;
        }
        if (ret >= 0)
            return 1;
    }
    return -2;
}

static void convert_pal_bgra(uint32_t *colors, size_t count, bool gray)
{
    for (int n = 0; n < count; n++) {
        uint32_t c = colors[n];
        uint32_t b = c & 0xFF;
        uint32_t g = (c >> 8) & 0xFF;
        uint32_t r = (c >> 16) & 0xFF;
        uint32_t a = (c >> 24) & 0xFF;
        if (gray)
            r = g = b = (r + g + b) / 3;
        // from straight to pre-multiplied alpha
        b = b * a / 255;
        g = g * a / 255;
        r = r * a / 255;
        colors[n] = b | (g << 8) | (r << 16) | (a << 24);
    }
}

/// the graphic subtitles' bitmap with pixel format AV_PIX_FMT_PAL8,
/// https://ffmpeg.org/doxygen/trunk/pixfmt_8h.html#a9a8e335cf3be472042bc9f0cf80cd4c5
/// need to be converted to RGBA32 before use

static FFSubtitleBuffer* convert_pal8_to_bgra(const AVSubtitleRect* rect)
{
    uint32_t pal[256] = {0};
    memcpy(pal, rect->data[1], rect->nb_colors * 4);
    convert_pal_bgra(pal, rect->nb_colors, 0);
    
    SDL_Rectangle r = (SDL_Rectangle){rect->x, rect->y, rect->w, rect->h, rect->linesize[0]};
    FFSubtitleBuffer *frame = ff_subtitle_buffer_alloc_rgba32(r);
    if (!frame) {
        return NULL;
    }
    
    for (int y = 0; y < rect->h; y++) {
        uint8_t *in = rect->data[0] + y * rect->linesize[0];
        uint32_t *out = (uint32_t *)(frame->data + y * frame->rect.stride);
        for (int x = 0; x < rect->w; x++)
            *out++ = pal[*in++];
    }
    return frame;
}

static int create_ass_renderer_if_need(FFSubComponent *com)
{
    if (com->assRenderer) {
        return 0;
    }
    
    int ratio = 1;
#ifdef __APPLE__
    //文本字幕放大两倍，使得 retina 屏显示清楚
    ratio = 2;
    com->sub_width  = com->video_width  * ratio;
    com->sub_height = com->video_height * ratio;
#endif
    
    com->assRenderer = ff_ass_render_create_default(com->decoder.avctx->subtitle_header, com->decoder.avctx->subtitle_header_size, com->sub_width, com->sub_height, NULL);
    
    apply_preference(com);
    
    return NULL == com->assRenderer;
}

static int create_bitmap_renderer_if_need(FFSubComponent *com)
{
    if (com->bitmapRenderer) {
        return 0;
    }
    com->bitmapRenderer = 1;
    com->sub_width = com->decoder.avctx->width;
    com->sub_height = com->decoder.avctx->height;
    if (!com->sub_width || !com->sub_height) {
        com->sub_width = com->video_width;
        com->sub_height = com->video_height;
    }
    return 0;
}

static int subtitle_thread(void *arg)
{
    FFSubComponent *com = arg;
    int got_subtitle;
    
    for (;com->packetq->abort_request == 0;) {
        AVSubtitle sub;
        got_subtitle = decode_a_frame(com, &com->decoder, &sub);
        
        if (got_subtitle == -1000) {
            if (com->retry_callback) {
                com->retry_callback(com->retry_opaque);
                return -1;
            }
            break;
        }
        
        if (got_subtitle < 0)
            break;
        
        if (got_subtitle) {
            //av_log(NULL, AV_LOG_ERROR,"sub received frame:%f\n",pts);
            int serial = com->decoder.pkt_serial;
            if (com->packetq->serial == serial) {
                
                double pts = 0;
                if (sub.pts != AV_NOPTS_VALUE)
                    pts = sub.pts / (double)AV_TIME_BASE + com->startTime;
                
                int count = 0;
                FFSubtitleBuffer* buffers [SUB_REF_MAX_LEN] = { 0 };
                for (int i = 0; i < sub.num_rects; i++) {
                    AVSubtitleRect *rect = sub.rects[i];
                    //AV_CODEC_ID_HDMV_PGS_SUBTITLE
                    //AV_CODEC_ID_FIRST_SUBTITLE
                    if (rect->type == SUBTITLE_BITMAP) {
                        if (rect->w <= 0 || rect->h <= 0) {
                            continue;
                        }
                        if (!create_bitmap_renderer_if_need(com)) {
                            FFSubtitleBuffer* sb = convert_pal8_to_bgra(rect);
                            if (sb) {
                                buffers[count++] = sb;
                            } else {
                                break;
                            }
                        }
                    } else {
                        char *ass_line = rect->ass;
                        if (!ass_line)
                            continue;
                        if (!create_ass_renderer_if_need(com)) {
                            const float begin = pts + (float)sub.start_display_time / 1000.0;
                            float end = sub.end_display_time - sub.start_display_time;
                            ff_ass_process_chunk(com->assRenderer, ass_line, begin * 1000, end);
                            com->pkt_pts = begin;
                            count++;
                        }
                    }
                }
                
                if (count == 0) {
                    avsubtitle_free(&sub);
                    continue;
                }
                
                if (com->bitmapRenderer) {
                    Frame *sp = frame_queue_peek_writable(com->frameq);
                    if (com->packetq->abort_request || !sp) {
                        avsubtitle_free(&sub);
                        break;
                    }
                    sp->pts = pts + (float)sub.start_display_time / 1000.0;
                    if (sub.end_display_time > sub.start_display_time &&
                        sub.end_display_time != UINT32_MAX) {
                        sp->duration = (float)(sub.end_display_time - sub.start_display_time) / 1000.0;
                    } else {
                        sp->duration = -1;
                        Frame *pre = frame_queue_peek_pre_writable(com->frameq);
                        if (pre) {
                            pre->duration = sp->pts - pre->pts;
                        }
                    }
                    sp->serial = serial;
                    sp->width  = com->sub_width;
                    sp->height = com->sub_height;
                    sp->shown = 0;
                    
                    if (count > 0) {
                        memcpy(sp->sub_list, buffers, count * sizeof(buffers[0]));
                    } else {
                        bzero(sp->sub_list, sizeof(sp->sub_list));
                    }
                    frame_queue_push(com->frameq);
                }
            } else {
                //av_log(NULL, AV_LOG_DEBUG,"sub stream push old frame:%d\n",serial);
            }
            avsubtitle_free(&sub);
        }
    }
    
    ff_ass_render_release(&com->assRenderer);
    com->retry_callback = NULL;
    com->retry_opaque = NULL;
    com->st_idx = -1;
    
    return 0;
}

static int subComponent_packet_from_frame_queue(FFSubComponent *com, float pts, FFSubtitleBufferPacket *packet, int ignore_cache)
{
    if (!com || !packet) {
        return -1;
    }
    
    int serial = com->packetq->serial;
    
    if (serial == -1) {
        return -2;
    }
    
    int i = 0;
    
    while (packet->len < SUB_REF_MAX_LEN) {
        Frame *sp = frame_queue_peek_offset(com->frameq, i);
        if (!sp) {
            break;
        }
        
        //drop old serial subs
        if (sp->serial != serial) {
            av_log(NULL, AV_LOG_ERROR,"sub stream drop old serial frame:%d\n",sp->serial);
            frame_queue_next(com->frameq);
            continue;
        }
        
        if (sp->duration > 0) {
            if (pts > sp->pts + sp->duration) {
                frame_queue_next(com->frameq);
                continue;
            }
        } else {
            Frame *next = frame_queue_peek_offset(com->frameq, i + 1);
            if (next) {
                float du = next->pts - sp->pts;
                if (du <= 0) {
                    av_log(NULL, AV_LOG_ERROR,"sub stream drop overtime2 frame:%f\n",sp->pts);
                    frame_queue_next(com->frameq);
                    continue;
                } else if (du > 0) {
                    du = du < SUB_MAX_KEEP_DU ? du : SUB_MAX_KEEP_DU;
                    sp->duration = du;
                }
            } else {
                float delta = pts - sp->pts;
                if (delta > SUB_MAX_KEEP_DU) {
                    av_log(NULL, AV_LOG_ERROR,"sub stream drop overtime3 frame:%f\n",sp->pts);
                    frame_queue_next(com->frameq);
                    continue;
                }
            }
        }
        
        if (!sp->sub_list[0]) {
            i++;
            continue;
        }
        
        //已经开始
        if (pts > sp->pts) {
            for (int j = 0; j < sizeof(sp->sub_list)/sizeof(sp->sub_list[0]); j++) {
                FFSubtitleBuffer *sb = sp->sub_list[j];
                if (sb) {
                    packet->e[packet->len++] = ff_subtitle_buffer_retain(sb);
                } else {
                    break;
                }
            }
            i++;
            continue;
        } else {
            //还没已经开始
            i++;
            break;
        }
    }
    
    if (packet->len == 0) {
        //i > 0 means the frame queue is not empty
        return i > 0 ? -1 : -100;
    }
    
    if (ignore_cache || isFFSubtitleBufferArrayDiff(&com->sub_buffer_array, packet)) {
        ResetSubtitleBufferArray(&com->sub_buffer_array, packet);
        return 1;
    } else {
        FreeSubtitleBufferArray(packet);
        return 0;
    }
}

#if ! ASS_USE_PRE_RENDER
static int subComponent_packet_from_ass_render(FFSubComponent *com, float pts, FFSubtitleBufferPacket *packet)
{
    if (!com || !packet) {
        return -1;
    }
    
    FFSubtitleBuffer *sb = NULL;
    FF_ASS_Renderer *assRenderer = ff_ass_render_retain(com->assRenderer);
    int r = ff_ass_upload_buffer(com->assRenderer, pts, &sb, 0);
    ff_ass_render_release(&assRenderer);
    if (r > 0) {
        packet->e[packet->len++] = sb;
    }
    return r;
}
#endif

static int subComponent_packet_ass_from_frame_queue(FFSubComponent *com, float pts, FFSubtitleBufferPacket *packet)
{
    if (com->sp_changed) {
        return -100;
    }
    return subComponent_packet_from_frame_queue(com, pts, packet, 0);
}

static int subComponent_packet_for_ass(FFSubComponent *com, float pts, FFSubtitleBufferPacket *packet)
{
#if ASS_USE_PRE_RENDER
    return subComponent_packet_ass_from_frame_queue(com, pts, packet);
#else
    return subComponent_packet_from_ass_render(com, pts, packet);
#endif
}

int subComponent_upload_buffer(FFSubComponent *com, float pts, FFSubtitleBufferPacket *packet)
{
    if (!com || com->packetq->abort_request || !packet) {
        return -1;
    }
    
    com->current_pts = pts;
    
    if (com->assRenderer) {
        FFSubtitleBufferPacket myPacket = {0};
        myPacket.scale = 1.0;
        myPacket.width = com->sub_width;
        myPacket.height = com->sub_height;
        myPacket.isAss = 1;
        
        int r = subComponent_packet_for_ass(com, pts, &myPacket);
        if (r > 0) {
            *packet = myPacket;
        }
        return r;
    } else if (com->bitmapRenderer) {
        FFSubtitleBufferPacket myPacket = { 0 };
        myPacket.scale = com->sp.scale;
        myPacket.width = com->sub_width;
        myPacket.height = com->sub_height;
        myPacket.bottom_margin = com->sp.bottomMargin * com->sub_height;
        myPacket.isAss = 0;
        
        int r = subComponent_packet_from_frame_queue(com, pts, &myPacket, com->sp_changed);
        if (r > 0) {
            com->sp_changed = 0;
            *packet = myPacket;
        }
        return r;
    } else {
        return -2;
    }
}

int subComponent_open(FFSubComponent **cp, int stream_index, AVStream* stream, PacketQueue* packetq, FrameQueue* frameq, const char *enc, subComponent_retry_callback callback, void *opaque, int vw, int vh, float startTime)
{
    assert(frameq);
    assert(packetq);
    
    FFSubComponent *com = NULL;
    
    if (!cp) {
        return -2;
    }
    
    if (AVMEDIA_TYPE_SUBTITLE != stream->codecpar->codec_type) {
        return -3;
    }
    
    stream->discard = AVDISCARD_DEFAULT;
    AVCodecContext* avctx = avcodec_alloc_context3(NULL);
    if (!avctx) {
        return -4;
    }
    
    if (avcodec_parameters_to_context(avctx, stream->codecpar) < 0) {
        return -5;
    }
    
    //so important,ohterwise,sub frame has not pts.
    avctx->pkt_timebase = stream->time_base;
    if (enc) {
        avctx->sub_charenc = av_strdup(enc);
        avctx->sub_charenc_mode = FF_SUB_CHARENC_MODE_AUTOMATIC;
    }
    const AVCodec* codec = avcodec_find_decoder(stream->codecpar->codec_id);
    
    if (!codec) {
        av_log(NULL, AV_LOG_ERROR, "can't find [%s] subtitle decoder!", avcodec_get_name(stream->codecpar->codec_id));
        return -100;
    }
    
    if (avcodec_open2(avctx, codec, NULL) < 0) {
        av_log(NULL, AV_LOG_ERROR, "can't open [%s] subtitle decoder!", avcodec_get_name(stream->codecpar->codec_id));
        return -6;
    }
    
    com = av_mallocz(sizeof(FFSubComponent));
    if (!com) {
        avcodec_free_context(&avctx);
        return -7;
    }
    
    com->video_width = vw;
    com->video_height = vh;
    com->frameq = frameq;
    com->packetq = packetq;
    com->retry_callback = callback;
    com->retry_opaque = opaque;
    com->st_idx = stream_index;
    com->sp = ijk_subtitle_default_preference();
    com->current_pts = -1;
    com->pre_load_pts = -1;
    com->startTime = startTime;
    
    int ret = decoder_init(&com->decoder, avctx, com->packetq, NULL);
    
    if (ret < 0) {
        av_log(NULL, AV_LOG_ERROR, "subtitle decoder init failed:%d", ret);
        avcodec_free_context(&avctx);
        av_free(com);
        return -8;
    }
    
    ret = decoder_start(&com->decoder, subtitle_thread, com, "ff_subtitle_dec");
    if (ret < 0) {
        av_log(NULL, AV_LOG_ERROR, "subtitle decoder start failed:%d", ret);
        decoder_destroy(&com->decoder);
        av_free(com);
        return -9;
    }
    
    av_log(NULL, AV_LOG_INFO, "sub stream opened:%d use enc:%s,serial:%d,decoder:%s\n", stream_index, enc, packetq->serial, avcodec_get_name(stream->codecpar->codec_id));
    *cp = com;
    return 0;
}

int subComponent_close(FFSubComponent **cp)
{
    if (!cp) {
        return -1;
    }
    FFSubComponent *com = *cp;
    if (!com) {
        return -2;
    }
    
    if (com->st_idx == -1) {
        return -3;
    }
    decoder_abort(&com->decoder, com->frameq);
    decoder_destroy(&com->decoder);
    FreeSubtitleBufferArray(&com->sub_buffer_array);
    av_freep(cp);
    return 0;
}

int subComponent_get_stream(FFSubComponent *com)
{
    if (com) {
        return com->st_idx;
    }
    return -1;
}

AVCodecContext * subComponent_get_avctx(FFSubComponent *com)
{
    return com ? com->decoder.avctx : NULL;
}

void subComponent_update_preference(FFSubComponent *com, IJKSDLSubtitlePreference* sp)
{
    if (!com) {
        return;
    }
    
    if (!isIJKSDLSubtitlePreferenceEqual(&com->sp, sp)) {
        com->sp = *sp;
        com->sp_changed = 1;
    }
}
