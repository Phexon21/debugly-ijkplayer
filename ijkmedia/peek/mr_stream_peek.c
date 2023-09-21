//
//  mr_stream_peek.c
//  MRISR
//
//  Created by Reach Matt on 2023/9/7.
//

#include "mr_stream_peek.h"
#include "ff_frame_queue.h"
#include "ff_packet_list.h"
#include "ff_sub_component.h"
#include "ff_ffplay_def.h"
#include "ff_ffplay_debug.h"
#include <libavformat/avformat.h>
#include <libswresample/swresample.h>

#define MRSampleFormat AV_SAMPLE_FMT_S16P
#define MRSampleRate   16000
#define MRNBChannels   1

typedef struct MRStreamPeek {
    SDL_mutex* mutex;
    FFSubComponent* opaque;
    AVFormatContext* ic;
    int stream_idx;
    PacketQueue pktq;
    FrameQueue frameq;
    
    struct SwrContext *swr_ctx;
    struct AudioParams audio_src;
    
    int audio_buf_index;
    int audio_buf_size;
    uint8_t *audio_buf;
    uint8_t *audio_buf1;
    unsigned int audio_buf1_size;
    double audio_clock;
    int audio_clock_serial;
}MRStreamPeek;

int mr_stream_peek_create(MRStreamPeek **spp,int frameMaxCount)
{
    if (!spp) {
        return -1;
    }
    
    MRStreamPeek *sp = av_malloc(sizeof(MRStreamPeek));
    if (!sp) {
        return -2;
    }
    bzero(sp, sizeof(MRStreamPeek));
    
    sp->mutex = SDL_CreateMutex();
    if (NULL == sp->mutex) {
        av_free(sp);
       return -2;
    }
    
    if (packet_queue_init(&sp->pktq) < 0) {
        av_free(sp);
        return -3;
    }
    
    if (frame_queue_init(&sp->frameq, &sp->pktq, frameMaxCount, 0) < 0) {
        packet_queue_destroy(&sp->pktq);
        av_free(sp);
        return -4;
    }
    
    sp->stream_idx = -1;
    *spp = sp;
    return 0;
}

int mr_stream_peek_get_opened_stream_idx(MRStreamPeek *sp)
{
    if (sp && sp->opaque) {
        return sp->stream_idx;
    }
    return -1;
}

int mr_stream_peek_seek_to(MRStreamPeek *sp, float sec)
{
    if (!sp || !sp->opaque) {
        return -1;
    }
    return subComponent_seek_to(sp->opaque, sec);
}

//FILE *file_pcm_l = NULL;
static int audio_decode_frame(MRStreamPeek *sp)
{
    if (sp->pktq.abort_request)
        return -1;
    
    Frame *af;
    
    //skip old audio frames.
    do {
        af = frame_queue_peek_readable_noblock(&sp->frameq);
        if (af == NULL) {
            if (subComponent_eof_and_pkt_empty(sp->opaque)) {
                return -1;
            } else {
                av_usleep(10);
            }
        } else {
            if (af->serial != sp->pktq.serial) {
                frame_queue_next(&sp->frameq);
                continue;
            } else {
                break;
            }
        }
    } while (1);
    
    AVFrame *frame = af->frame;
    
    int data_size = av_samples_get_buffer_size(NULL,
                                               frame->ch_layout.nb_channels,
                                               frame->nb_samples,
                                               frame->format,
                                               1);
    
    static int flag = 1;
    
    if (flag) {
        av_log(NULL, AV_LOG_WARNING, "audio sample rate:%d\n",frame->sample_rate);
        av_log(NULL, AV_LOG_WARNING, "audio format:%s\n",av_get_sample_fmt_name(frame->format));
        flag = 0;
    }
    
    int need_convert =  frame->format != sp->audio_src.fmt ||
                        av_channel_layout_compare(&frame->ch_layout, &sp->audio_src.ch_layout) ||
                        frame->sample_rate != sp->audio_src.freq ||
                        !sp->swr_ctx;

    if (need_convert) {
        swr_free(&sp->swr_ctx);
        AVChannelLayout layout;
        av_channel_layout_default(&layout, MRNBChannels);
        swr_alloc_set_opts2(&sp->swr_ctx,
                            &layout, MRSampleFormat, MRSampleRate,
                            &frame->ch_layout, frame->format, frame->sample_rate,
                            0, NULL);
        if (!sp->swr_ctx) {
            av_log(NULL, AV_LOG_ERROR,
                   "swr_alloc_set_opts2 failed!\n");
            return -1;
        }
        
        if (swr_init(sp->swr_ctx) < 0) {
            av_log(NULL, AV_LOG_ERROR,
                   "Cannot create sample rate converter for conversion of %d Hz %s %d channels to %d Hz %s %d channels!\n",
                    frame->sample_rate, av_get_sample_fmt_name(frame->format), frame->ch_layout.nb_channels,
                   MRSampleRate, av_get_sample_fmt_name(MRSampleFormat), layout.nb_channels);
            swr_free(&sp->swr_ctx);
            return -1;
        }
        
        if (av_channel_layout_copy(&sp->audio_src.ch_layout, &frame->ch_layout) < 0)
            return -1;
        sp->audio_src.freq = frame->sample_rate;
        sp->audio_src.fmt = frame->format;
    }

    int resampled_data_size;
    if (sp->swr_ctx) {
        int out_count = (int)((int64_t)frame->nb_samples * MRSampleRate / frame->sample_rate + 256);
        int out_size = av_samples_get_buffer_size(NULL, MRNBChannels, out_count, MRSampleFormat, 0);
        int len2;
        if (out_size < 0) {
            av_log(NULL, AV_LOG_ERROR, "av_samples_get_buffer_size() failed\n");
            return -1;
        }
        av_fast_malloc(&sp->audio_buf1, &sp->audio_buf1_size, out_size);

        const uint8_t **in = (const uint8_t **)frame->extended_data;
        uint8_t **out = &sp->audio_buf1;
        
        if (!sp->audio_buf1)
            return AVERROR(ENOMEM);
        len2 = swr_convert(sp->swr_ctx, out, out_count, in, frame->nb_samples);
        if (len2 < 0) {
            av_log(NULL, AV_LOG_ERROR, "swr_convert() failed\n");
            return -1;
        }
        if (len2 == out_count) {
            av_log(NULL, AV_LOG_WARNING, "audio buffer is probably too small\n");
            if (swr_init(sp->swr_ctx) < 0)
                swr_free(&sp->swr_ctx);
        }
        sp->audio_buf = sp->audio_buf1;
        int bytes_per_sample = av_get_bytes_per_sample(MRSampleFormat);
        resampled_data_size = len2 * MRNBChannels * bytes_per_sample;
    } else {
        sp->audio_buf = frame->data[0];
        resampled_data_size = data_size;
    }

    /* update the audio clock with the pts */
    if (!isnan(af->pts))
        sp->audio_clock = af->pts;
    sp->audio_clock_serial = af->serial;

//    if (file_pcm_l == NULL) {
//        file_pcm_l = fopen("/Users/matt/Library/Containers/2E018519-4C6C-4E16-B3B1-9F3ED37E67E5/Data/tmp/3.pcm", "wb+");
//    }
//    fwrite(sp->audio_buf, resampled_data_size, 1, file_pcm_l);
    
    frame_queue_next(&sp->frameq);
    return resampled_data_size;
}

int mr_stream_peek_get_data(MRStreamPeek *sub, unsigned char *buffer, int len, double * pts_begin, double * pts_end)
{
    const int len_want = len;
    double begin = -1,end = -1;
    
    if (!sub) {
        return -1;
    }
    
    while (len > 0) {
        if (sub->audio_buf_index >= sub->audio_buf_size) {
            int audio_size = audio_decode_frame(sub);
            if (audio_size < 0) {
                /* if error, just output silence */
                sub->audio_buf = NULL;
                sub->audio_buf_size = 0;
                goto end;
            } else {
                sub->audio_buf_size = audio_size;
                if (begin < 0) {
                    begin = sub->audio_clock;
                }
            }
            sub->audio_buf_index = 0;
        }
        
        if (subComponent_get_pkt_serial(sub->opaque) != sub->pktq.serial) {
            sub->audio_buf_index = sub->audio_buf_size;
            break;
        }
        int rest_len = sub->audio_buf_size - sub->audio_buf_index;
        if (rest_len > len)
            rest_len = len;
        memcpy(buffer, (uint8_t *)sub->audio_buf + sub->audio_buf_index, rest_len);
        len -= rest_len;
        buffer += rest_len;
        sub->audio_buf_index += rest_len;
    }
end:
    
    if (begin >= 0) {
        int bytes_per_sec = av_samples_get_buffer_size(NULL, MRNBChannels, MRSampleRate, MRSampleFormat, 1);
        end = begin + (len_want - len) / bytes_per_sec;
    }
    
    if (pts_begin) {
        *pts_begin = begin;
    }
    
    if (pts_end) {
        *pts_end = end;
    }
    
    return len_want - len;
}

int mr_stream_peek_open_filepath(MRStreamPeek *sub, const char *file_name, int idx)
{
    if (!sub) {
        return -1;
    }

    if (!file_name || strlen(file_name) == 0) {
        return -2;
    }
        
    int ret = 0;
    AVFormatContext* ic = NULL;
    AVCodecContext* avctx = NULL;
    
    if (avformat_open_input(&ic, file_name, NULL, NULL) < 0) {
        ret = -1;
        goto fail;
    }
    
    if (avformat_find_stream_info(ic, NULL) < 0) {
        ret = -2;
        goto fail;
    }

    if (ic) {
        av_log(NULL, AV_LOG_DEBUG, "ex subtitle demuxer:%s\n",ic->iformat->name);
    }
    AVStream *stream = ic->streams[idx];
    stream->discard = AVDISCARD_DEFAULT;
    
    if (!stream) {
        ret = -3;
        av_log(NULL, AV_LOG_ERROR, "none subtitle stream in %s\n", file_name);
        goto fail;
    }
    
    const AVCodec* codec = avcodec_find_decoder(stream->codecpar->codec_id);
    if (!codec) {
        av_log(NULL, AV_LOG_WARNING, "could find codec:%s for %s\n",
                file_name, avcodec_get_name(stream->codecpar->codec_id));
        ret = -4;
        goto fail;
    }
    
    avctx = avcodec_alloc_context3(NULL);
    if (!avctx) {
        ret = -5;
        goto fail;
    }

    if (avcodec_parameters_to_context(avctx, stream->codecpar) < 0) {
        ret = -6;
        goto fail;
    }
    //so important,ohterwise, sub frame has not pts.
    avctx->pkt_timebase = stream->time_base;
    
    if (avcodec_open2(avctx, codec, NULL) < 0) {
        ret = -7;
        goto fail;
    }
    
    if (subComponent_open(&sub->opaque, idx, ic, avctx, &sub->pktq, &sub->frameq) != 0) {
        ret = -8;
        goto fail;
    }
    
    sub->ic = ic;
    sub->stream_idx = idx;
    return 0;
fail:
    if (ret < 0) {
        if (ic)
            avformat_close_input(&ic);
        if (avctx)
            avcodec_free_context(&avctx);
    }
    return ret;
}

int mr_stream_peek_close(MRStreamPeek *sub)
{
    if(!sub) {
        return -1;
    }
    
    FFSubComponent *opaque = sub->opaque;
    
    if(!opaque) {
        if (sub->ic)
            avformat_close_input(&sub->ic);
        return -2;
    }
    
    int r = subComponent_close(&opaque);
    SDL_LockMutex(sub->mutex);
    sub->opaque = NULL;
    if (sub->ic)
        avformat_close_input(&sub->ic);
    SDL_UnlockMutex(sub->mutex);
    return r;
}

void mr_stream_peek_destroy(MRStreamPeek **subp)
{
    if (!subp) {
        return;
    }
    
    MRStreamPeek *sub = *subp;
    if (!sub) {
        return;
    }
    
    mr_stream_peek_close(sub);
    
    SDL_DestroyMutex(sub->mutex);
    
    av_freep(subp);
}

int mr_stream_peek_get_buffer_size(int second)
{
    int bytes_per_sec = av_samples_get_buffer_size(NULL, MRNBChannels, MRSampleRate, MRSampleFormat, 1);
    return bytes_per_sec * second;
}
