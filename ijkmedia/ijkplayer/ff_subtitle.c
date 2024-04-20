//
//  ff_subtitle.c
//  IJKMediaPlayerKit
//
//  Created by Reach Matt on 2022/5/23.
//

#include "ff_subtitle.h"
#include "ff_frame_queue.h"
#include "ff_packet_list.h"
#include "ff_subtitle_ex.h"
#include "ff_sub_component.h"
#include "ff_ffplay_debug.h"
#include "ijksdl_gpu.h"
#include "ijksdl/ijksdl_gpu.h"
#include "ff_subtitle_def_internal.h"

typedef struct FFSubtitle {
    PacketQueue packetq;
    FrameQueue frameq;
    float delay;
    float current_pts;
    int maxInternalStream;
    FFSubComponent* inSub;
    IJKEXSubtitle* exSub;
    int streamStartTime;//ic start_time (s)
    int video_w, video_h;
    IJKSDLSubtitlePreference sp;
    SDL_TextureOverlay *assTexture;
    SDL_FBOOverlay *fbo;
    SDL_TextureOverlay *preTexture;
}FFSubtitle;

//---------------------------Public Common Functions--------------------------------------------------//

int ff_sub_init(FFSubtitle **subp)
{
    if (!subp) {
        return -1;
    }
    FFSubtitle *sub = av_mallocz(sizeof(FFSubtitle));
    
    if (!sub) {
        return -2;
    }
    
    if (packet_queue_init(&sub->packetq) < 0) {
        av_free(sub);
        return -3;
    }
    
    if (frame_queue_init(&sub->frameq, &sub->packetq, SUBPICTURE_QUEUE_SIZE, 0) < 0) {
        packet_queue_destroy(&sub->packetq);
        av_free(sub);
        return -4;
    }
    sub->delay = 0.0f;
    sub->current_pts = 0.0f;
    sub->maxInternalStream = -1;
    
    *subp = sub;
    return 0;
}

void ff_sub_abort(FFSubtitle *sub)
{
    if (!sub) {
        return;
    }
    packet_queue_abort(&sub->packetq);
}

int ff_sub_destroy(FFSubtitle **subp)
{
    if (!subp) {
        return -1;
    }
    FFSubtitle *sub = *subp;
    
    if (!sub) {
        return -2;
    }
    if (sub->inSub) {
        subComponent_close(&sub->inSub);
    } else if (exSub_get_opened_stream_idx(sub->exSub) != -1) {
        exSub_subtitle_destroy(&sub->exSub);
    }
    packet_queue_destroy(&sub->packetq);
    frame_queue_destory(&sub->frameq);
    SDL_TextureOverlay_Release(&sub->assTexture);
    SDL_TextureOverlay_Release(&sub->preTexture);
    SDL_FBOOverlayFreeP(&sub->fbo);
    sub->delay = 0.0f;
    sub->current_pts = 0.0f;
    sub->maxInternalStream = -1;
    
    av_freep(subp);
    return 0;
}

int ff_sub_close_current(FFSubtitle *sub)
{
    if (!sub) {
        return -1;
    }
    if (sub->inSub) {
        return subComponent_close(&sub->inSub);
    } else if (exSub_get_opened_stream_idx(sub->exSub) != -1) {
        return exSub_close_current(sub->exSub);
    }
    return -1;
}

int ff_sub_drop_old_frames(FFSubtitle *sub)
{
    int count = 0;
    int serial = sub->packetq.serial;
    while (frame_queue_nb_remaining(&sub->frameq) > 0) {
        Frame *sp = frame_queue_peek(&sub->frameq);
        if (sp->serial != serial) {
            frame_queue_next(&sub->frameq);
            count++;
            continue;
        } else {
            break;
        }
    }
    return count;
}

static int ff_sub_upload_buffer(FFSubtitle *sub, float pts, FFSubtitleBufferPacket *packet)
{
    if (!sub || !packet) {
        return -1;
    }
    
    sub->current_pts = pts;
    pts += (sub ? sub->delay : 0.0);
    
    if (sub->inSub) {
        if (subComponent_get_stream(sub->inSub) != -1) {
            return subComponent_upload_buffer(sub->inSub, pts, packet);
        }
    }
    
    if (sub->exSub) {
        if (exSub_get_opened_stream_idx(sub->exSub) != -1) {
            pts -= sub->streamStartTime;
            return exSub_upload_buffer(sub->exSub, pts, packet);
        }
    }
    
    return -3;
}

static SDL_TextureOverlay * subtitle_ass_upload_texture(SDL_TextureOverlay *texture, FFSubtitleBufferPacket *packet)
{
    for (int i = 0; i < packet->len; i++) {
        FFSubtitleBuffer *buffer = packet->e[i];
        texture->clearDirtyRect(texture);
        texture->dirtyRect = buffer->rect;
        texture->replaceRegion(texture, buffer->rect, buffer->data);
    }
    return SDL_TextureOverlay_Retain(texture);
}

static SDL_TextureOverlay * subtitle_upload_fbo(SDL_GPU *gpu, SDL_FBOOverlay *fbo, FFSubtitleBufferPacket *packet)
{
    fbo->beginDraw(gpu, fbo, 0);
    fbo->clear(fbo);
    int water_mark = fbo->h * SUBTITLE_MOVE_WATERMARK;
    int bottom_offset = packet->bottom_margin;
    for (int i = 0; i < packet->len; i++) {
        FFSubtitleBuffer *sub = packet->e[i];
        SDL_TextureOverlay *texture = gpu->createTexture(gpu, sub->rect.w, sub->rect.h, SDL_TEXTURE_FMT_BRGA);
        int offset = sub->rect.y > water_mark ? bottom_offset : 0;
        SDL_Rectangle rect = sub->rect;
        rect.y -= offset;
        if (rect.y < 0) {
            rect.y = 0;
        }
        texture->replaceRegion(texture, rect, sub->data);
        texture->scale = packet->scale;
        fbo->drawTexture(gpu, fbo, texture);
        SDL_TextureOverlay_Release(&texture);
    }
    fbo->endDraw(gpu, fbo);
    return fbo->getTexture(fbo);
}

//if *texture is not NULL, it was retained
static int ff_sub_upload_texture(FFSubtitle *sub, float pts, SDL_GPU *gpu, SDL_TextureOverlay **texture)
{
    if (!sub || !texture) {
        return -1;
    }
    
    FFSubtitleBufferPacket packet = {0};
    int r = ff_sub_upload_buffer(sub, pts, &packet);
    if (r <= 0) {
        *texture = NULL;
        return r;
    }
    
    if (packet.isAss) {
        if (sub->assTexture && (sub->assTexture->w != packet.width || sub->assTexture->h != packet.height)) {
            SDL_TextureOverlay_Release(&sub->assTexture);
        }
        if (!sub->assTexture) {
            sub->assTexture = gpu->createTexture(gpu, packet.width, packet.height, SDL_TEXTURE_FMT_BRGA);
        }
        if (!sub->assTexture) {
            r = -1;
            goto end;
        }
        
        *texture = subtitle_ass_upload_texture(sub->assTexture, &packet);
        goto end;
    } else {
        if (sub->fbo && (sub->fbo->w != packet.width || sub->fbo->h != packet.height)) {
            SDL_FBOOverlayFreeP(&sub->fbo);
        }
        if (!sub->fbo) {
            sub->fbo = gpu->createFBO(gpu, packet.width, packet.height);
        }
        if (!sub->fbo) {
            r = -1;
            goto end;
        }
        
        *texture = subtitle_upload_fbo(gpu, sub->fbo, &packet);
    }
end:
    FreeSubtitleBufferArray(&packet);
    return r;
}

void ff_sub_get_texture(FFSubtitle *sub, float pts, SDL_GPU *gpu, SDL_TextureOverlay **texture)
{
    if (!texture) {
        return;
    }
    
    {
        SDL_TextureOverlay *sub_overlay = NULL;
        int r = ff_sub_upload_texture(sub, pts, gpu, &sub_overlay);
        if (r > 0) {
            //replace
            SDL_TextureOverlay_Release(&sub->preTexture);
            sub->preTexture = sub_overlay;
        } else if (r < 0) {
            //clean
            SDL_TextureOverlay_Release(&sub->preTexture);
        } else {
            //keep current
        }
    }
    
    *texture = SDL_TextureOverlay_Retain(sub->preTexture);
}


int ff_sub_frame_queue_size(FFSubtitle *sub)
{
    if (sub) {
        return sub->frameq.size;
    }
    return 0;
}

int ff_sub_has_enough_packets(FFSubtitle *sub, int min_frames)
{
    if (sub) {
        return sub->packetq.abort_request || sub->packetq.nb_packets > min_frames;
    }
    return 1;
}

int ff_sub_put_null_packet(FFSubtitle *sub, AVPacket *pkt, int st_idx)
{
    if (sub) {
        return packet_queue_put_nullpacket(&sub->packetq, pkt, st_idx);
    }
    return -1;
}

int ff_sub_put_packet(FFSubtitle *sub, AVPacket *pkt)
{
    if (sub) {
        //av_log(NULL, AV_LOG_INFO,"sub put pkt:%lld\n",pkt->pts/1000);
        return packet_queue_put(&sub->packetq, pkt);
    }
    return -1;
}

int ff_sub_get_opened_stream_idx(FFSubtitle *sub)
{
    int idx = -1;
    if (sub) {
        if (sub->inSub) {
            idx = subComponent_get_stream(sub->inSub);
        }
        if (idx == -1 && sub->exSub) {
            idx = exSub_get_opened_stream_idx(sub->exSub);
        }
    }
    return idx;
}

void ff_sub_seek_to(FFSubtitle *sub, float delay, float v_pts)
{
    if (exSub_get_opened_stream_idx(sub->exSub) != -1) {
        v_pts -= sub->streamStartTime;
    }
    
    float wantDisplay = v_pts - delay;
    exSub_seek_to(sub->exSub, wantDisplay);
}

int ff_sub_set_delay(FFSubtitle *sub, float delay, float v_pts)
{
    if (!sub) {
        return -1;
    }
    if (exSub_get_opened_stream_idx(sub->exSub) != -1) {
        v_pts -= sub->streamStartTime;
    }
    
    float wantDisplay = v_pts - delay;
    //subtile's frame queue greater than can display pts
    if (sub->current_pts > wantDisplay) {
        float diff = fabsf(delay - sub->delay);
        sub->delay = delay;
        //need seek to wantDisplay;
        if (sub->inSub) {
            //after seek maybe can display want sub,but can't seek every dealy change,so when diff greater than 2s do seek.
            if (diff > 2) {
                //return 1 means need seek.
                return 1;
            }
            return -2;
        } else if (exSub_get_opened_stream_idx(sub->exSub) != -1) {
            exSub_seek_to(sub->exSub, wantDisplay-2);
            return 0;
        } else {
            return -3;
        }
    } else {
        //when no need seek,just apply the diff to output frame's pts
        sub->delay = delay;
        return 0;
    }
}

float ff_sub_get_delay(FFSubtitle *sub)
{
    return sub ? sub->delay : 0.0;
}

int ff_sub_isInternal_stream(FFSubtitle *sub, int stream)
{
    if (!sub) {
        return 0;
    }
    return stream >= 0 && stream <= sub->maxInternalStream;
}

int ff_sub_isExternal_stream(FFSubtitle *sub, int stream)
{
    if (!sub) {
        return 0;
    }
    return exSub_contain_streamIdx(sub->exSub, stream);
}

int ff_sub_current_stream_type(FFSubtitle *sub, int *outIdx)
{
    int type = 0;
    int idx = -1;
    if (sub) {
        if (sub->inSub) {
            idx = subComponent_get_stream(sub->inSub);
            type = 1;
        }
        if (idx == -1 && sub->exSub) {
            idx = exSub_get_opened_stream_idx(sub->exSub);
            if (idx != -1) {
                type = 2;
            }
        }
    }
    
    if (outIdx) {
        *outIdx = idx;
    }
    return type;
}

void ff_sub_stream_ic_ready(FFSubtitle *sub, AVFormatContext* ic, int video_w, int video_h)
{
    if (!sub) {
        return;
    }
    sub->video_w = video_w;
    sub->video_h = video_h;
    sub->streamStartTime = (int)fftime_to_seconds(ic->start_time);
    sub->maxInternalStream = ic->nb_streams;
    exSub_reset_video_size(sub->exSub, video_w, video_h);
}

int ff_inSub_open_component(FFSubtitle *sub, int stream_index, AVStream* st, AVCodecContext *avctx)
{
    int r = subComponent_open(&sub->inSub, stream_index, NULL, avctx, &sub->packetq, &sub->frameq, NULL, NULL, sub->video_w, sub->video_h);
    if (!r) {
        subComponent_update_preference(sub->inSub, &sub->sp);
    }
    return r;
}

enum AVCodecID ff_sub_get_codec_id(FFSubtitle *sub)
{
    if (!sub) {
        return -1;
    }
    AVCodecContext *avctx = NULL;
    int idx = -1;
    if (sub->inSub) {
        idx = subComponent_get_stream(sub->inSub);
        if (idx != -1) {
            avctx = subComponent_get_avctx(sub->inSub);
        }
    }
    if (idx == -1 && sub->exSub) {
        idx = exSub_get_opened_stream_idx(sub->exSub);
        if (idx != -1) {
            avctx = exSub_get_avctx(sub->exSub);
        }
    }
    
    return avctx ? avctx->codec_id : AV_CODEC_ID_NONE;
}

int ff_sub_packet_queue_flush(FFSubtitle *sub)
{
    if (sub) {
        packet_queue_flush(&sub->packetq);
        return 0;
    }
    return -1;
}

int ff_update_sub_preference(FFSubtitle *sub, IJKSDLSubtitlePreference* sp)
{
    if (sub) {
        sub->sp = *sp;
        int hasStream = 0;
        int idx = -1;
        if (sub->inSub) {
            idx = subComponent_get_stream(sub->inSub);
            if (idx != -1) {
                subComponent_update_preference(sub->inSub, sp);
                hasStream = 1;
            }
        }
        if (idx == -1 && sub->exSub) {
            idx = exSub_get_opened_stream_idx(sub->exSub);
            if (idx != -1) {
                exSub_update_preference(sub->exSub, sp);
                hasStream = 1;
            }
        }
        return hasStream;
    }
    return 0;
}

//---------------------------Internal Subtitle Functions--------------------------------------------------//

//

//---------------------------External Subtitle Functions--------------------------------------------------//

int ff_exSub_addOnly_subtitle(FFSubtitle *sub, const char *file_name, IjkMediaMeta *meta)
{
    if (!sub->exSub) {
        //maybe video_w and vieo_h is zero now.
        if (exSub_create(&sub->exSub, &sub->frameq, &sub->packetq, sub->video_w, sub->video_h) != 0) {
            return -1;
        }
    }
    return exSub_addOnly_subtitle(sub->exSub, file_name, meta);
}

int ff_exSub_add_active_subtitle(FFSubtitle *sub, const char *file_name, IjkMediaMeta *meta)
{
    if (!sub->exSub) {
        //maybe video_w and vieo_h is zero now.
        if (exSub_create(&sub->exSub, &sub->frameq, &sub->packetq, sub->video_w, sub->video_h) != 0) {
            return -1;
        }
    }
    int err = exSub_add_active_subtitle(sub->exSub, file_name, meta);
    if (!err) {
        exSub_update_preference(sub->exSub, &sub->sp);
    }
    return err;
}

int ff_exSub_open_stream(FFSubtitle *sub, int stream)
{
    if (!sub->exSub) {
        return -1;
    }
    int err = exSub_open_file_idx(sub->exSub, stream, sub->video_w, sub->video_h);
    if (!err) {
        exSub_update_preference(sub->exSub, &sub->sp);
    }
    return err;
}

int ff_exSub_check_file_added(const char *file_name, FFSubtitle *sub)
{
    if (!sub || !sub->exSub) {
        return -1;
    }
    return exSub_check_file_added(file_name, sub->exSub);
}
