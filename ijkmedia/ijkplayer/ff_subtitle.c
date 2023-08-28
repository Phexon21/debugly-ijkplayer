//
//  ff_subtitle.c
//  IJKMediaPlayerKit
//
//  Created by Reach Matt on 2022/5/23.
//

#include "ff_subtitle.h"
#include "ff_frame_queue.h"
#include "ff_packet_list.h"
#include "ff_ass_parser.h"
#include "ff_subtitle_ex.h"
#include "ff_sub_component.h"
#include "ff_ffplay_debug.h"

typedef struct FFSubtitle {
    PacketQueue packetq;
    FrameQueue frameq;
    float delay;
    float current_pts;
    int maxInternalStream;
    FFSubComponent* inSub;
    IJKEXSubtitle* exSub;
    int streamStartTime;//ic start_time (s)
}FFSubtitle;

//---------------------------Private Functions--------------------------------------------------//

static double get_frame_real_begin_pts(FFSubtitle *sub, Frame *sp)
{
    return sp->pts + (float)sp->sub.start_display_time / 1000.0;
}

static double get_frame_begin_pts(FFSubtitle *sub, Frame *sp)
{
    return sp->pts + (float)sp->sub.start_display_time / 1000.0 + (sub ? sub->delay : 0.0);
}

static double get_frame_end_pts(FFSubtitle *sub, Frame *sp)
{
    if (sp->sub.end_display_time != 4294967295) {
        return sp->pts + (float)sp->sub.end_display_time / 1000.0 + (sub ? sub->delay : 0.0);
    } else {
        return sp->pts + 5 + (sub ? sub->delay : 0.0);
    }
}

static int stream_has_enough_packets(PacketQueue *queue, int min_frames)
{
    return queue->abort_request || queue->nb_packets > min_frames;
}

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
    
    sub->delay = 0.0f;
    sub->current_pts = 0.0f;
    sub->maxInternalStream = -1;
    
    av_freep(subp);
    return 0;
}

int ff_sub_close_current(FFSubtitle *sub)
{
    if (sub->inSub) {
        return subComponent_close(&sub->inSub);
    } else if (exSub_get_opened_stream_idx(sub->exSub) != -1) {
        return exSub_close_current(sub->exSub);
    }
    return -1;
}

static void ff_sub_clean_frame_queue(FFSubtitle *sub)
{
    if (!sub) {
        return;
    }
    FrameQueue *subpq = &sub->frameq;
    while (frame_queue_nb_remaining(subpq) > 0) {
        frame_queue_next(subpq);
    }
}

int ff_sub_fetch_frame(FFSubtitle *sub, float pts, char **text, AVSubtitleRect **bmp)
{
    if (!sub) {
        return -1;
    }
    
    if (ff_sub_get_opened_stream_idx(sub) < 0) {
        return -1;
    }
    
    int r = 1;
    if (exSub_get_opened_stream_idx(sub->exSub) != -1) {
        pts -= sub->streamStartTime;
    }
    int rem = 0;
    int dropped = 0;
    while ((rem = frame_queue_nb_remaining(&sub->frameq)) > 0) {
        if (rem > 1) {
            Frame *sp2 = frame_queue_peek_next(&sub->frameq);
            if (pts > get_frame_begin_pts(sub, sp2)) {
                dropped++;
                frame_queue_next(&sub->frameq);
                continue;
            }
        }
        Frame * sp = frame_queue_peek(&sub->frameq);
        sub->current_pts = get_frame_real_begin_pts(sub, sp);
        float begin = sub->current_pts + (sub ? sub->delay : 0.0);
        float end = get_frame_end_pts(sub, sp);
        
        if (pts > begin && pts < end) {
            if (!sp->uploaded) {
                if (sp->sub.num_rects > 0) {
                    if (sp->sub.rects[0]->text) {
                        *text = av_strdup(sp->sub.rects[0]->text);
                    } else if (sp->sub.rects[0]->ass) {
                        *text = parse_ass_subtitle(sp->sub.rects[0]->ass);
                    } else if (sp->sub.rects[0]->type == SUBTITLE_BITMAP
                               && sp->sub.rects[0]->data[0]
                               && sp->sub.rects[0]->linesize[0]) {
                        *bmp = sp->sub.rects[0];
                    } else {
                        assert(0);
                    }
                }
                r = 0;
                sp->uploaded = 1;
            }
            //av_log(NULL, AV_LOG_ERROR, "sub fetch frame :%0.2f,%0.2f,%0.2f;dropped:%d\n",pts,sub->current_pts,(sub ? sub->delay : 0.0),dropped);
        } else {
            //av_log(NULL, AV_LOG_ERROR, "sub fetch frame failed:%0.2f,%0.2f,%0.2f;dropped:%d\n",pts,sub->current_pts,(sub ? sub->delay : 0.0),dropped);
            if (sp->uploaded) {
                sp->uploaded = 0;
            }
            //clean current display sub
            r = -3;
        }
        break;
    }
    return r;
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
        return stream_has_enough_packets(&sub->packetq, min_frames);
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
    ff_sub_clean_frame_queue(sub);
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
                ff_sub_clean_frame_queue(sub);
                //return 1 means need seek.
                return 1;
            }
            return -2;
        } else if (exSub_get_opened_stream_idx(sub->exSub) != -1) {
            ff_sub_clean_frame_queue(sub);
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

void ff_sub_stream_ic_ready(FFSubtitle *sub,AVFormatContext* ic)
{
    sub->streamStartTime = (int)fftime_to_seconds(ic->start_time);
    sub->maxInternalStream = ic->nb_streams;
}

int ff_sub_open_component(FFSubtitle *sub, int stream_index, AVFormatContext* ic, AVCodecContext *avctx)
{
    if (sub->inSub || sub->exSub) {
        packet_queue_flush(&sub->packetq);
        ff_sub_clean_frame_queue(sub);
    }
    return subComponent_open(&sub->inSub, stream_index, ic, avctx, &sub->packetq, &sub->frameq);
}

int ff_inSub_packet_queue_flush(FFSubtitle *sub)
{
    if (sub) {
        if (sub->inSub) {
            packet_queue_flush(&sub->packetq);
        }
        return 0;
    }
    return -1;
}

//---------------------------Internal Subtitle Functions--------------------------------------------------//

//

//---------------------------External Subtitle Functions--------------------------------------------------//

int ff_exSub_addOnly_subtitle(FFSubtitle *sub, const char *file_name, IjkMediaMeta *meta)
{
    if (!sub->exSub) {
        if (exSub_create(&sub->exSub, &sub->frameq, &sub->packetq) != 0) {
            return -1;
        }
    }
    
    return exSub_addOnly_subtitle(sub->exSub, file_name, meta);
}

int ff_exSub_add_active_subtitle(FFSubtitle *sub, const char *file_name, IjkMediaMeta *meta)
{
    if (!sub->exSub) {
        if (exSub_create(&sub->exSub, &sub->frameq, &sub->packetq) != 0) {
            return -1;
        }
    }
    packet_queue_flush(&sub->packetq);
    ff_sub_clean_frame_queue(sub);
    return exSub_add_active_subtitle(sub->exSub, file_name, meta);
}

int ff_exSub_open_stream(FFSubtitle *sub, int stream)
{
    if (!sub->exSub) {
        return -1;
    }
    packet_queue_flush(&sub->packetq);
    ff_sub_clean_frame_queue(sub);
    
    return exSub_open_file_idx(sub->exSub, stream);
}

int ff_exSub_check_file_added(const char *file_name, FFSubtitle *sub)
{
    if (!sub || !sub->exSub) {
        return -1;
    }
    return exSub_check_file_added(file_name, sub->exSub);
}
