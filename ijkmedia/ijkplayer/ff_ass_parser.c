//
//  ff_ass_parser.c
//  IJKMediaPlayerKit
//
//  Created by Reach Matt on 2022/5/17.
//

#include "ff_ass_parser.h"
#include <libavutil/mem.h>

static const char * remove_ass_line_header(const char *ass)
{
/*
 ffmpeg4 ass解析规则:
 "Dialogue: 0,0:00:00.00,0:00:00.00,Default,,0,0,0,,这里是自由城\\N{\\fn微软雅黑\\fs52.5\\b0\\bord0}{\\i1}This is Free City.{\\i}{\\fad(150,150)}在不断衍生的黑暗之中  相互交换了\r\n{\\i1}";
 "Dialogue: 0,0:00:00.00,0:00:00.00,Default,,0,0,0,,{\an3\fnDFKai-SB\c&HFEFDFD&\3c&H070101&\pos(260,422)}{\fad(300,150)}字幕来源 X2&CASO";
 
 ffmpeg5 ass解析规则变了：16,0,DNOP-CHS,NTP,0000,0000,0000,,{\\fad(150,150)}在不断衍生的黑暗之中  相互交换了
 
 */
    const char *tok = ass;
#define CHECK_TOK(sepretor) \
do {               \
    char *pos = strchr(tok, sepretor); \
    if (pos) {tok = pos + 1;} \
} while(0) \
    
    CHECK_TOK(':'); // skip event
    CHECK_TOK(','); // skip layer
    CHECK_TOK(','); // skip start_time
    CHECK_TOK(','); // skip end_time
    CHECK_TOK(','); // skip style
    CHECK_TOK(','); // skip name
    CHECK_TOK(','); // skip margin_l
    CHECK_TOK(','); // skip margin_r
    CHECK_TOK(','); // skip margin_v
//    CHECK_TOK(','); // skip effect
#undef CHECK_TOK
    return tok;
}

static void replace_N_to_n(char *buffer)
{
    int len = (int)strlen(buffer);
    if (len > 0) {
        do {
            char *found = strstr(buffer, "\\N");
            if (found) {
                *(found) = '\n';
                memmove(found + 1, found + 2, strlen(found + 2));
                *(buffer+len - 1) = '\0';
            } else {
                break;
            }
        } while(1);
    }
}

static void remove_last_rn(char *buffer)
{
    int len = (int)strlen(buffer);
    if (len > 0) {
        char *found = strstr(buffer, "\r\n");
        if (found) {
            if (found + 2 == buffer + len) {
                *(found) = '\0';
            }
        }
    }
}

static void remove_last_n(char *buffer)
{
    int len = (int)strlen(buffer);
    if (len > 0) {
        char *found = strstr(buffer, "\n");
        if (found) {
            if (found + 1 == buffer + len) {
                *(found) = '\0';
            }
        }
    }
}

static char * remove_ass_line_effect(const char *ass)
{
    while (ass && strlen(ass) > 2) {
        //移除 { 开头并且 } 结尾的特效内容
        if (ass[0] == '{') {
            char* end = strchr(ass, '}');
            if (end) {
                ass = end + 1;
            } else {
                break;
            }
        } else {
            break;
        }
    }
    
    char *buffer = av_malloc(strlen(ass) + 1);
    bzero(buffer, strlen(ass) + 1);
    memcpy(buffer, ass, strlen(ass));
    
    while (1) {
        char *left  = strstr(buffer, "{");
        char *right = strstr(buffer, "}");
        if (left && right > left) {
            if (right - buffer == strlen(buffer)) {
                bzero(left, right - left);
            } else {
                int count = (int)strlen(buffer) - (int)(right - buffer);
                memmove(left, right + 1, count);
                bzero(left + count + 1, 1);
            }
        } else {
            break;
        }
    }
    return buffer;
}

//need free!
FFSubtitleBuffer * parse_ass_subtitle(const char *ass)
{
    const char *text = remove_ass_line_header(ass);
    if (text && strlen(text) > 0) {
        char *buffer = remove_ass_line_effect(text);
        replace_N_to_n(buffer);
        remove_last_rn(buffer);
        remove_last_n(buffer);
        FFSubtitleBuffer *sb = ff_gen_subtitle_text(buffer);
        av_free(buffer);
        return sb;
    }
    return NULL;
}
