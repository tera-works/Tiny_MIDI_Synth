// =============================================================
//  kitplayer — midikit で最適化した MIDI ファイルを midi_keyboard_kit_synth に流し続ける展示用プレーヤー
//
//  使い方（Mac）:
//    ビルド: clang -O2 -Wno-deprecated-declarations -o kitplayer kitplayer.c -framework CoreMIDI -framework CoreFoundation
//    実行:   ./kitplayer [フォルダ または .mid ...] [-port 名前] [-gap 秒] [-once] [-list]
//            フォルダを省くと、今いる場所の「最適化後」フォルダ（無ければ今いる場所）の .mid を全部
//    （kitplayer.command をダブルクリックすると、ビルドしてから再生する。再生中はスリープしない）
//  使い方（Windows）:
//    kitplayer.bat をダブルクリック（kitplayer.exe と同じフォルダの「最適化後」を再生。再生中はスリープしない）
//    ビルド: cl /O2 /MT /utf-8 kitplayer.c（Visual Studio の「x64 Native Tools コマンド プロンプト」で）
//
//  ・フォルダの .mid を名前順に、ずっと繰り返し再生する。フォルダに playlist.txt があればその順番
//    （1 行に 1 つのファイル名。# から後はコメント。サブフォルダは「アニメ/曲.mid」のように書く）
//  ・出力先は名前に「TinyKeyboard」を含む MIDI 出力（-port で変更。-list で一覧）。見つからなければ、
//    PC の中のソフト音源・仮想ポート以外の出力がちょうど 1 つならそれを使う（Windows では USB の製品名で見えることがある）
//  ・各曲の前に GM リセットを送る（曲の頭の音質モードの SysEx で高音質に戻る）。曲の途中の SysEx もそのまま送る
//  ・本体が抜けたら待ち、挿し直されたら自動でつなぎ直して、その曲を頭から再生する
//  ・再生した曲と時刻を、フォルダの「再生ログ.txt」に残す
//
//  キー操作: スペース = 一時停止 / 再開、n = 次の曲、b = 前の曲、r = 今の曲を頭から、q = 終了
//    一時停止すると鳴っている音を全部止める。再開するときは音色・CC・ベンド・音質モードを送り直してから続きを鳴らす
// =============================================================
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <stdarg.h>
#include <signal.h>
#include <time.h>

#ifdef _WIN32
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <mmsystem.h>
#include <shellapi.h>
#include <conio.h>
#pragma comment(lib, "winmm.lib")
#pragma comment(lib, "shell32.lib")
#else
#include <CoreMIDI/CoreMIDI.h>
#include <CoreFoundation/CoreFoundation.h>
#include <dirent.h>
#include <termios.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/stat.h>
#endif

#define DEFAULT_PORT "TinyKeyboard"
#define MAX_SONGS 512

// ---------------- 時間 ----------------
static double nowSec(void) {
#ifdef _WIN32
    static LARGE_INTEGER f; LARGE_INTEGER c;
    if (!f.QuadPart) QueryPerformanceFrequency(&f);
    QueryPerformanceCounter(&c); return (double)c.QuadPart / (double)f.QuadPart;
#else
    struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return t.tv_sec + t.tv_nsec * 1e-9;
#endif
}
static void sleepSec(double s) {
    if (s <= 0) return;
#ifdef _WIN32
    Sleep((DWORD)(s * 1000 + 0.5));
#else
    struct timespec t; t.tv_sec = (time_t)s; t.tv_nsec = (long)((s - (double)t.tv_sec) * 1e9); nanosleep(&t, NULL);
#endif
}

// ---------------- ファイル（Windows は UTF-8 の名前を UTF-16 に） ----------------
static FILE* openU8(const char* path, const char* mode) {
#ifdef _WIN32
    wchar_t wp[1024], wm[8];
    MultiByteToWideChar(CP_UTF8, 0, path, -1, wp, 1024); MultiByteToWideChar(CP_UTF8, 0, mode, -1, wm, 8);
    return _wfopen(wp, wm);
#else
    return fopen(path, mode);
#endif
}
static int isDirU8(const char* path) {
#ifdef _WIN32
    wchar_t wp[1024]; MultiByteToWideChar(CP_UTF8, 0, path, -1, wp, 1024);
    DWORD a = GetFileAttributesW(wp); return a != INVALID_FILE_ATTRIBUTES && (a & FILE_ATTRIBUTE_DIRECTORY);
#else
    struct stat st; return stat(path, &st) == 0 && S_ISDIR(st.st_mode);
#endif
}

// ---------------- 記録 ----------------
static FILE* gLog = NULL;
static void logf_(const char* fmt, ...) {
    if (!gLog) return;
    time_t t = time(NULL); struct tm* lt = localtime(&t); char ts[32];
    strftime(ts, sizeof ts, "%Y-%m-%d %H:%M:%S", lt);
    fprintf(gLog, "%s  ", ts);
    va_list a; va_start(a, fmt); vfprintf(gLog, fmt, a); va_end(a);
    fputc('\n', gLog); fflush(gLog);
}

// ---------------- MIDI 出力 ----------------
static char gPortName[256] = DEFAULT_PORT;   // 名前にこれを含む出力を使う
static int gPortGiven = 0;                    // -port で指定された
static char gOpened[256] = "";               // つないでいる出力の名前
static int gSendFail = 0;                     // 送れなかった（抜けた）
static int gDry = 0;                          // -dry: 送らない（動作確認用）
static long gSent = 0;                        // 送ったメッセージの数
static double gSpeed = 1.0;                   // -speed: 再生の速さ（動作確認用）
#ifdef _WIN32
static HMIDIOUT gOut = NULL;
static int midiCount(void) { return (int)midiOutGetNumDevs(); }
static void midiName(int i, char* buf, int n) {
    MIDIOUTCAPSW c; buf[0] = 0;
    if (midiOutGetDevCapsW((UINT)i, &c, sizeof c) == MMSYSERR_NOERROR) WideCharToMultiByte(CP_UTF8, 0, c.szPname, -1, buf, n, NULL, NULL);
}
static int midiOpenIndex(int i) { return midiOutOpen(&gOut, (UINT)i, 0, 0, CALLBACK_NULL) == MMSYSERR_NOERROR; }
static void midiClose(void) { if (gOut) { midiOutReset(gOut); midiOutClose(gOut); gOut = NULL; } }
static int midiSend(const uint8_t* d, int n) {
    ++gSent; if (gDry) return 1;
    if (!gOut) return 0;
    if (d[0] == 0xF0 || d[0] == 0xF7) {
        MIDIHDR h; memset(&h, 0, sizeof h); h.lpData = (LPSTR)d; h.dwBufferLength = (DWORD)n; h.dwBytesRecorded = (DWORD)n;
        if (midiOutPrepareHeader(gOut, &h, sizeof h) != MMSYSERR_NOERROR) return 0;
        MMRESULT r = midiOutLongMsg(gOut, &h, sizeof h);
        for (int w = 0; r == MMSYSERR_NOERROR && !(h.dwFlags & MHDR_DONE) && w < 1000; ++w) Sleep(1);   // 抜けたときに待ち続けない
        midiOutUnprepareHeader(gOut, &h, sizeof h);
        if (r != MMSYSERR_NOERROR) gSendFail = 1;
        return r == MMSYSERR_NOERROR;
    }
    DWORD m = d[0] | (n > 1 ? d[1] << 8 : 0) | (n > 2 ? d[2] << 16 : 0);
    if (midiOutShortMsg(gOut, m) != MMSYSERR_NOERROR) { gSendFail = 1; return 0; }
    return 1;
}
static void midiPump(void) {}
#else
static MIDIClientRef gClient = 0;
static MIDIPortRef gPort = 0;
static MIDIEndpointRef gDest = 0;
static void midiInit(void) {
    if (gClient) return;
    MIDIClientCreate(CFSTR("kitplayer"), NULL, NULL, &gClient);
    MIDIOutputPortCreate(gClient, CFSTR("out"), &gPort);
}
static int midiCount(void) { midiInit(); return (int)MIDIGetNumberOfDestinations(); }
static void midiName(int i, char* buf, int n) {
    buf[0] = 0; CFStringRef s = NULL;
    MIDIEndpointRef e = MIDIGetDestination((ItemCount)i);
    if (e && MIDIObjectGetStringProperty(e, kMIDIPropertyDisplayName, &s) == noErr && s) {
        CFStringGetCString(s, buf, n, kCFStringEncodingUTF8); CFRelease(s);
    }
}
static int midiOpenIndex(int i) { gDest = MIDIGetDestination((ItemCount)i); return gDest != 0; }
static void midiClose(void) { gDest = 0; }
static int midiSend(const uint8_t* d, int n) {
    ++gSent; if (gDry) return 1;
    if (!gDest) return 0;
    static union { MIDIPacketList pl; uint8_t b[70000]; } buf;   // MIDIPacketList（SysEx も 1 つのパケットで送る）。並びを合わせるため union
    MIDIPacketList* pl = &buf.pl;
    MIDIPacket* p = MIDIPacketListInit(pl);
    p = MIDIPacketListAdd(pl, sizeof buf, p, 0, (ByteCount)n, d);
    if (!p) return 0;
    if (MIDISend(gPort, gDest, pl) != noErr) { gSendFail = 1; return 0; }
    return 1;
}
static void midiPump(void) { CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0, true); }   // 抜き差しの知らせを受け取る
#endif
// PC の中のソフト音源・仮想ポート（本体ではない）
static int isSoftPort(const char* b) {
    static const char* soft[] = { "Microsoft GS Wavetable", "IAC", "Network", "loopMIDI", "Session", NULL };
    for (int k = 0; soft[k]; ++k) if (strstr(b, soft[k])) return 1;
    return 0;
}
// 名前に gPortName を含む出力の番号（無ければ -1）。名前で見つからず -port の指定もないときは、
// ソフト音源・仮想ポート以外の出力がちょうど 1 つならそれを本体とみなす（Windows では USB の製品名で見えることがある）
static int findPort(char* name, int n) {
    int c = midiCount(), other = -1, nOther = 0; char ob[256] = "";
    for (int i = 0; i < c; ++i) {
        char b[256]; midiName(i, b, sizeof b);
        if (strstr(b, gPortName)) { if (name) snprintf(name, n, "%s", b); return i; }
        if (!isSoftPort(b)) { other = i; ++nOther; snprintf(ob, sizeof ob, "%s", b); }
    }
    if (!gPortGiven && nOther == 1) { if (name) snprintf(name, n, "%s", ob); return other; }
    return -1;
}
static int connected(void) {
    if (gDry) return 1;
    if (gSendFail) return 0;
    midiPump();
    char b[256]; int i = findPort(b, sizeof b);
    if (i < 0) return 0;
#ifndef _WIN32
    if (gDest && gDest != MIDIGetDestination((ItemCount)i)) return 0;   // つなぎ直しが必要
#endif
    return gOpened[0] != 0;
}
static int connectPort(void) {
    if (gDry) { snprintf(gOpened, sizeof gOpened, "(送らない)"); return 1; }
    midiClose(); gOpened[0] = 0; gSendFail = 0;
    char b[256]; int i = findPort(b, sizeof b);
    if (i < 0 || !midiOpenIndex(i)) return 0;
    snprintf(gOpened, sizeof gOpened, "%s", b);
    return 1;
}
static void allNotesOff(void) {
    for (int ch = 0; ch < 16; ++ch) {
        uint8_t m[3] = { (uint8_t)(0xB0 | ch), 64, 0 };     // ペダルを離す
        midiSend(m, 3);
        m[1] = 123; midiSend(m, 3);                         // オールノートオフ
        m[1] = 120; midiSend(m, 3);                         // オールサウンドオフ
    }
}
static void gmReset(void) { static const uint8_t r[] = { 0xF0, 0x7E, 0x7F, 0x09, 0x01, 0xF7 }; midiSend(r, sizeof r); }

// ---------------- 標準 MIDI ファイル ----------------
typedef struct { double t; uint32_t off; uint16_t len; uint8_t trk; uint32_t ord; } Ev;   // 送るイベント（データは pool[off..]）
typedef struct { Ev* ev; int n; uint8_t* pool; size_t poolN; double dur; } Song;
static uint32_t rdVar(const uint8_t* b, size_t* i, size_t end) { uint32_t v = 0; while (*i < end) { uint8_t c = b[(*i)++]; v = (v << 7) | (c & 127); if (!(c & 128)) break; } return v; }
static int cmpEv(const void* a, const void* b) {
    const Ev* x = (const Ev*)a; const Ev* y = (const Ev*)b;
    if (x->t != y->t) return x->t < y->t ? -1 : 1;
    if (x->trk != y->trk) return x->trk < y->trk ? -1 : 1;
    return x->ord < y->ord ? -1 : (x->ord > y->ord);
}
typedef struct { uint32_t tick, us; } Tempo;
static int cmpTempo(const void* a, const void* b) { const Tempo* x = (const Tempo*)a; const Tempo* y = (const Tempo*)b; return x->tick < y->tick ? -1 : (x->tick > y->tick); }
static void freeSong(Song* s) { free(s->ev); free(s->pool); memset(s, 0, sizeof *s); }
static int loadSong(const char* path, Song* S, char* err, int errn) {
    memset(S, 0, sizeof *S);
    FILE* f = openU8(path, "rb"); if (!f) { snprintf(err, errn, "開けません"); return 0; }
    fseek(f, 0, SEEK_END); long sz = ftell(f); fseek(f, 0, SEEK_SET);
    uint8_t* b = (uint8_t*)malloc(sz > 0 ? (size_t)sz : 1); size_t got = fread(b, 1, (size_t)sz, f); fclose(f);
    if (got < 14 || memcmp(b, "MThd", 4)) { free(b); snprintf(err, errn, "MIDI ファイルではありません"); return 0; }
    uint32_t hl = (uint32_t)b[4] << 24 | b[5] << 16 | b[6] << 8 | b[7];
    int ntrk = b[10] << 8 | b[11], div = b[12] << 8 | b[13];
    if (div & 0x8000) { free(b); snprintf(err, errn, "SMPTE 形式には未対応"); return 0; }
    // 1 回目: イベントとテンポを数えて集める（時刻はまだ tick）
    size_t cap = 4096, n = 0, pcap = 65536, pn = 0; Ev* ev = (Ev*)malloc(cap * sizeof(Ev)); uint8_t* pool = (uint8_t*)malloc(pcap);
    uint32_t* tick = (uint32_t*)malloc(cap * sizeof(uint32_t));
    Tempo* tp = (Tempo*)malloc(sizeof(Tempo) * 1024); int tn = 0, tcap = 1024;
    size_t pos = 8 + hl; uint32_t lastTick = 0;
    for (int tr = 0; tr < ntrk && pos + 8 <= got; ++tr) {
        uint32_t len = (uint32_t)b[pos + 4] << 24 | b[pos + 5] << 16 | b[pos + 6] << 8 | b[pos + 7];
        if (memcmp(b + pos, "MTrk", 4)) { pos += 8 + len; --tr; continue; }
        size_t i = pos + 8, end = pos + 8 + len; if (end > got) end = got;
        uint32_t t = 0, ord = 0; uint8_t rs = 0;
        while (i < end) {
            t += rdVar(b, &i, end); if (i >= end) break;
            uint8_t c = b[i]; const uint8_t* d = NULL; uint32_t dl = 0; uint8_t head[3]; int sys = 0;
            if (c == 0xFF) {
                if (i + 1 >= end) break;
                uint8_t m = b[i + 1]; i += 2; uint32_t l = rdVar(b, &i, end);
                if (m == 0x51 && l == 3 && i + 3 <= end) {
                    if (tn == tcap) { tcap *= 2; tp = (Tempo*)realloc(tp, sizeof(Tempo) * tcap); }
                    tp[tn].tick = t; tp[tn].us = (uint32_t)b[i] << 16 | b[i + 1] << 8 | b[i + 2]; ++tn;
                }
                i += l; continue;
            } else if (c == 0xF0 || c == 0xF7) {
                ++i; uint32_t l = rdVar(b, &i, end); if (i + l > end) break;
                d = b + i; dl = l; sys = c; i += l;
            } else {
                if (c & 0x80) { rs = c; ++i; }
                if (!rs) break;
                int nd = ((rs & 0xF0) == 0xC0 || (rs & 0xF0) == 0xD0) ? 1 : 2;
                if (i + nd > end) break;
                head[0] = rs; head[1] = b[i]; head[2] = nd > 1 ? b[i + 1] : 0; i += nd;
                d = head; dl = (uint32_t)nd + 1;
            }
            if (n == cap) { cap *= 2; ev = (Ev*)realloc(ev, cap * sizeof(Ev)); tick = (uint32_t*)realloc(tick, cap * sizeof(uint32_t)); }
            size_t need = dl + 1; while (pn + need > pcap) { pcap *= 2; pool = (uint8_t*)realloc(pool, pcap); }
            ev[n].off = (uint32_t)pn; ev[n].trk = (uint8_t)tr; ev[n].ord = ord++;
            if (sys == 0xF0) { pool[pn++] = 0xF0; memcpy(pool + pn, d, dl); pn += dl; ev[n].len = (uint16_t)(dl + 1); }   // F0 + 中身（最後の F7 を含む）
            else { memcpy(pool + pn, d, dl); pn += dl; ev[n].len = (uint16_t)dl; }   // F7 は中身をそのまま / チャンネルメッセージ
            tick[n] = t; if (t > lastTick) lastTick = t; ++n;
        }
        pos += 8 + len;
    }
    free(b);
    // テンポ表で tick → 秒
    qsort(tp, tn, sizeof(Tempo), cmpTempo);
    for (size_t k = 0; k < n; ++k) {
        double s = 0; uint32_t lt = 0, us = 500000;
        for (int j = 0; j < tn && tp[j].tick <= tick[k]; ++j) { s += (double)(tp[j].tick - lt) * us / 1e6 / div; lt = tp[j].tick; us = tp[j].us; }
        ev[k].t = s + (double)(tick[k] - lt) * us / 1e6 / div;
    }
    free(tick); free(tp);
    qsort(ev, n, sizeof(Ev), cmpEv);
    S->ev = ev; S->n = (int)n; S->pool = pool; S->poolN = pn; S->dur = n ? ev[n - 1].t : 0;
    return 1;
}
// 一時停止のあと: 今の位置までの音色・CC・ベンド・プレッシャー・SysEx の最後の状態を送り直す（音は送らない）
static void chase(const Song* S, int upto) {
    static int last[16][2 + 128 + 2];                  // [0] 音色, [1] ベンド, [2..129] CC, [130] プレッシャー
    for (int c = 0; c < 16; ++c) for (int k = 0; k < 2 + 128 + 2; ++k) last[c][k] = -1;
    int* sysIdx = (int*)malloc(sizeof(int) * (upto + 1)); int ns = 0;
    for (int i = 0; i < upto; ++i) {
        const uint8_t* d = S->pool + S->ev[i].off; int ty = d[0] & 0xF0, ch = d[0] & 15;
        if (d[0] == 0xF0 || d[0] == 0xF7) sysIdx[ns++] = i;
        else if (ty == 0xC0) last[ch][0] = i;
        else if (ty == 0xE0) last[ch][1] = i;
        else if (ty == 0xB0 && d[1] < 120) last[ch][2 + d[1]] = i;
        else if (ty == 0xD0) last[ch][130] = i;
    }
    // 元の順番で送る（RPN の 101/100 → 6/38 の順などを保つ）
    int* order = (int*)malloc(sizeof(int) * (16 * 132 + ns + 1)); int no = 0;
    for (int k = 0; k < ns; ++k) order[no++] = sysIdx[k];
    for (int c = 0; c < 16; ++c) for (int k = 0; k < 132; ++k) if (last[c][k] >= 0) order[no++] = last[c][k];
    for (int a = 1; a < no; ++a) { int v = order[a], j = a - 1; while (j >= 0 && order[j] > v) { order[j + 1] = order[j]; --j; } order[j + 1] = v; }
    for (int k = 0; k < no; ++k) midiSend(S->pool + S->ev[order[k]].off, S->ev[order[k]].len);
    free(order); free(sysIdx);
}

// ---------------- キー入力 ----------------
// 動作確認用: -keys "秒:キー,秒:キー,..."（起動からの秒数に、そのキーを押したことにする。s = スペース）
static struct { double t; int k; } gScript[64]; static int gNScript = 0, gScriptPos = 0; static double gT0 = 0;
static int scriptKey(void) {
    if (gScriptPos < gNScript && nowSec() - gT0 >= gScript[gScriptPos].t) return gScript[gScriptPos++].k;
    return -1;
}
#ifdef _WIN32
static void keysInit(void) {}
static void keysDone(void) {}
static int keyGet(void) {
    int s = scriptKey(); if (s >= 0) return s;
    if (!_kbhit()) return -1; int c = _getch(); if (c == 0 || c == 0xE0) { c = _getch(); return c == 77 ? 'n' : (c == 75 ? 'b' : -1); } return c; }
#else
static struct termios gTerm; static int gTermSaved = 0;
static void keysInit(void) {
    if (!isatty(0) || tcgetattr(0, &gTerm) != 0) return;
    struct termios t = gTerm; t.c_lflag &= ~(ICANON | ECHO); t.c_cc[VMIN] = 0; t.c_cc[VTIME] = 0;
    tcsetattr(0, TCSANOW, &t); gTermSaved = 1;
}
static void keysDone(void) { if (gTermSaved) { tcsetattr(0, TCSANOW, &gTerm); gTermSaved = 0; } }
static int keyGet(void) {
    int sk = scriptKey(); if (sk >= 0) return sk;
    unsigned char c;
    if (read(0, &c, 1) != 1) return -1;
    if (c == 27) {                                          // 矢印キー（ESC [ C / ESC [ D）
        unsigned char s[2];
        if (read(0, s, 1) == 1 && s[0] == '[' && read(0, s + 1, 1) == 1) return s[1] == 'C' ? 'n' : (s[1] == 'D' ? 'b' : -1);
        return -1;
    }
    return c;
}
#endif

// ---------------- 曲の一覧 ----------------
static char* gSongs[MAX_SONGS]; static int gNSongs = 0;
static int cmpStr(const void* a, const void* b) { return strcmp(*(char* const*)a, *(char* const*)b); }
static void addSong(const char* p) { if (gNSongs < MAX_SONGS) { gSongs[gNSongs] = (char*)malloc(strlen(p) + 1); strcpy(gSongs[gNSongs++], p); } }
static int hasMidExt(const char* n) { size_t l = strlen(n); return l > 4 && (!strcmp(n + l - 4, ".mid") || !strcmp(n + l - 4, ".MID") || !strcmp(n + l - 4, ".Mid")); }
static void listDir(const char* dir, int recurse) {   // dir 以下の .mid（サブフォルダも）
#ifdef _WIN32
    wchar_t pat[1024]; char u[1024]; snprintf(u, sizeof u, "%s\\*", dir); MultiByteToWideChar(CP_UTF8, 0, u, -1, pat, 1024);
    WIN32_FIND_DATAW fd; HANDLE h = FindFirstFileW(pat, &fd); if (h == INVALID_HANDLE_VALUE) return;
    do {
        char nm[512]; WideCharToMultiByte(CP_UTF8, 0, fd.cFileName, -1, nm, sizeof nm, NULL, NULL);
        if (nm[0] == '.') continue;
        char full[1024]; snprintf(full, sizeof full, "%s\\%s", dir, nm);
        if (fd.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) { if (recurse) listDir(full, 1); }
        else if (hasMidExt(nm)) addSong(full);
    } while (FindNextFileW(h, &fd));
    FindClose(h);
#else
    DIR* d = opendir(dir); if (!d) return;
    struct dirent* e;
    while ((e = readdir(d))) {
        if (e->d_name[0] == '.') continue;
        char full[1024]; snprintf(full, sizeof full, "%s/%s", dir, e->d_name);
        if (isDirU8(full)) { if (recurse) listDir(full, 1); }
        else if (hasMidExt(e->d_name)) addSong(full);
    }
    closedir(d);
#endif
}
// playlist.txt があればその順番、無ければ名前順
static void loadFolder(const char* dir) {
    char pl[1024]; snprintf(pl, sizeof pl, "%s/playlist.txt", dir);
    FILE* f = openU8(pl, "rb");
    if (f) {
        char line[1024]; int first = 1;
        while (fgets(line, sizeof line, f)) {
            char* s = line;
            if (first && (unsigned char)s[0] == 0xEF && (unsigned char)s[1] == 0xBB && (unsigned char)s[2] == 0xBF) s += 3;   // UTF-8 の BOM
            first = 0;
            char* h = strchr(s, '#'); if (h) *h = 0;
            size_t l = strlen(s); while (l && (s[l - 1] == '\n' || s[l - 1] == '\r' || s[l - 1] == ' ' || s[l - 1] == '\t')) s[--l] = 0;
            while (*s == ' ' || *s == '\t') ++s;
            if (!*s) continue;
            char full[1024]; snprintf(full, sizeof full, "%s/%s", dir, s);
            FILE* t = openU8(full, "rb");
            if (t) { fclose(t); addSong(full); } else printf("  ※ playlist.txt の曲が見つかりません: %s\n", s);
        }
        fclose(f);
        printf("playlist.txt の順番で再生します\n");
        return;
    }
    int before = gNSongs; listDir(dir, 1);
    qsort(gSongs + before, gNSongs - before, sizeof(char*), cmpStr);
}
static const char* baseName(const char* p) { const char* s = strrchr(p, '/'); const char* w = strrchr(p, '\\'); if (w > s) s = w; return s ? s + 1 : p; }

// ---------------- 再生 ----------------
static volatile sig_atomic_t gQuit = 0;
static void onSignal(int s) { (void)s; gQuit = 1; }
enum { R_END, R_NEXT, R_PREV, R_RESTART, R_QUIT };
static double gGap = 2.0;

static void status(const char* name, int idx, double t, double dur, int paused) {
    printf("\r  [%d/%d] %s  %d:%02d / %d:%02d %s   ", idx + 1, gNSongs, name, (int)t / 60, (int)t % 60, (int)dur / 60, (int)dur % 60,
           paused ? "（一時停止中：スペースで再開）" : "                              ");
    fflush(stdout);
}
// 本体が抜けていたら挿し直されるまで待つ（q で終了）。つなぎ直したら 1 を返す
static int waitDevice(void) {
    if (connected()) return 0;
    printf("\n  本体（%s）が見つかりません。USB を挿してください…（q で終了）\n", gPortName);
    logf_("本体が見つからない / 抜けた");
    midiClose(); gOpened[0] = 0;
    for (;;) {
        if (gQuit) return 0;
        int k = keyGet(); if (k == 'q' || k == 'Q') { gQuit = 1; return 0; }
        midiPump();
        if (findPort(NULL, 0) >= 0) {
            sleepSec(2.0);                                  // 本体の起動を待つ
            if (connectPort()) { printf("  つなぎました: %s\n", gOpened); logf_("つなぎ直した: %s", gOpened); return 1; }
        }
        sleepSec(0.5);
    }
}
static int playSong(const Song* S, const char* name, int idx) {
    gmReset(); sleepSec(0.3);
    double start = nowSec(), pausedAt = 0, lastStatus = 0, lastCheck = nowSec();
    int i = 0, paused = 0;
    for (;;) {
        if (gQuit) { allNotesOff(); return R_QUIT; }
        int k = keyGet();
        if (k == ' ') {
            if (!paused) { paused = 1; pausedAt = nowSec(); allNotesOff(); logf_("一時停止: %s", name); }
            else { paused = 0; start += nowSec() - pausedAt; chase(S, i); logf_("再開: %s", name); }
            status(name, idx, ((paused ? pausedAt : nowSec()) - start) * gSpeed, S->dur, paused);
        }
        else if (k == 'n' || k == 'N') { allNotesOff(); return R_NEXT; }
        else if (k == 'b' || k == 'B') { allNotesOff(); return R_PREV; }
        else if (k == 'r' || k == 'R') { allNotesOff(); return R_RESTART; }
        else if (k == 'q' || k == 'Q') { allNotesOff(); return R_QUIT; }
        double now = nowSec();
        if (now - lastCheck > 1.0) {                        // 1 秒ごとに本体がつながっているか
            lastCheck = now;
            if (!connected()) { if (waitDevice()) return R_RESTART; if (gQuit) return R_QUIT; }
        }
        if (paused) { sleepSec(0.02); continue; }
        double t = (now - start) * gSpeed;
        while (i < S->n && S->ev[i].t <= t) { midiSend(S->pool + S->ev[i].off, S->ev[i].len); ++i; }
        if (now - lastStatus > 0.5) { status(name, idx, t, S->dur, 0); lastStatus = now; }
        if (i >= S->n && t >= S->dur + 1.5) return R_END;   // 最後の音の残響を待ってから
        double nx = i < S->n ? (S->ev[i].t - t) / gSpeed : 0.02;
        sleepSec(nx > 0.005 ? 0.005 : (nx > 0 ? nx : 0));
    }
}

int main(int argc, char** argv) {
#ifdef _WIN32
    SetConsoleOutputCP(CP_UTF8); timeBeginPeriod(1);
    SetThreadExecutionState(ES_CONTINUOUS | ES_SYSTEM_REQUIRED | ES_DISPLAY_REQUIRED);   // 再生中はスリープ・画面オフにしない
    // 引数を UTF-8 で取り直す
    int wc; LPWSTR* wv = CommandLineToArgvW(GetCommandLineW(), &wc);
    char** av = (char**)malloc(sizeof(char*) * wc);
    for (int i = 0; i < wc; ++i) { int l = WideCharToMultiByte(CP_UTF8, 0, wv[i], -1, NULL, 0, NULL, NULL); av[i] = (char*)malloc(l); WideCharToMultiByte(CP_UTF8, 0, wv[i], -1, av[i], l, NULL, NULL); }
    argc = wc; argv = av;
#endif
    setvbuf(stdout, NULL, _IONBF, 0);
    printf("kitplayer — midi_keyboard_kit_synth 展示用プレーヤー\n");
    int once = 0, list = 0; const char* logDir = NULL;
    for (int i = 1; i < argc; ++i) {
        if (!strcmp(argv[i], "-port") && i + 1 < argc) { snprintf(gPortName, sizeof gPortName, "%s", argv[++i]); gPortGiven = 1; continue; }
        if (!strcmp(argv[i], "-gap") && i + 1 < argc) { gGap = atof(argv[++i]); continue; }
        if (!strcmp(argv[i], "-once")) { once = 1; continue; }
        if (!strcmp(argv[i], "-speed") && i + 1 < argc) { gSpeed = atof(argv[++i]); if (gSpeed <= 0) gSpeed = 1; continue; }
        if (!strcmp(argv[i], "-keys") && i + 1 < argc) {      // 動作確認用: "秒:キー,..."
            char* s = argv[++i];
            while (*s && gNScript < 64) {
                double t = strtod(s, &s); if (*s != ':') break; ++s;
                int k = *s == 's' ? ' ' : (unsigned char)*s; ++s;
                gScript[gNScript].t = t; gScript[gNScript].k = k; ++gNScript;
                if (*s == ',') ++s;
            }
            continue;
        }
        if (!strcmp(argv[i], "-list")) { list = 1; continue; }
        if (!strcmp(argv[i], "-dry")) { gDry = 1; continue; }
        if (isDirU8(argv[i])) { loadFolder(argv[i]); if (!logDir) logDir = argv[i]; }
        else addSong(argv[i]);
    }
    if (list) {
        int c = midiCount(); printf("MIDI 出力 %d 個:\n", c);
        for (int i = 0; i < c; ++i) { char b[256]; midiName(i, b, sizeof b); printf("  %s\n", b); }
        return 0;
    }
    if (!gNSongs) {                                         // 引数なし: 「最適化後」フォルダ、無ければ今いる場所
        const char* d = isDirU8("最適化後") ? "最適化後" : ".";
        loadFolder(d); logDir = d;
    }
    if (!gNSongs) { printf("再生する .mid が見つかりません\n"); return 1; }
    char lp[1024]; snprintf(lp, sizeof lp, "%s/再生ログ.txt", logDir ? logDir : ".");
    gLog = openU8(lp, "ab");
    printf("%d 曲を%s再生します（曲間 %.1f 秒）\n", gNSongs, once ? "1 回" : "繰り返し", gGap);
    printf("キー: スペース = 一時停止/再開、n(→) = 次、b(←) = 前、r = 頭から、q = 終了\n");
    signal(SIGINT, onSignal); signal(SIGTERM, onSignal);
    keysInit(); gT0 = nowSec();
    logf_("開始（%d 曲）", gNSongs);
    if (!connectPort()) { if (!waitDevice() && gQuit) { keysDone(); return 0; } }
    else { printf("出力: %s\n", gOpened); logf_("出力: %s", gOpened); }
    int idx = 0, quit = 0;
    while (!quit && !gQuit) {
        Song S; char err[128];
        const char* name = baseName(gSongs[idx]);
        if (!loadSong(gSongs[idx], &S, err, sizeof err)) {
            printf("\n  × %s: %s（飛ばします）\n", name, err); logf_("読めない: %s（%s）", name, err);
            idx = (idx + 1) % gNSongs; if (once && idx == 0) break; sleepSec(0.5); continue;
        }
        printf("\n▶ %s\n", name); logf_("再生: %s", name);
        long sent0 = gSent;
        int r = playSong(&S, name, idx);
        if (gDry) printf("\n  （送ったメッセージ %ld / この曲のイベント %d、終わり方 %d）\n", gSent - sent0, S.n, r);
        freeSong(&S);
        if (r == R_QUIT) quit = 1;
        else if (r == R_RESTART) continue;
        else if (r == R_PREV) idx = (idx + gNSongs - 1) % gNSongs;
        else {
            int wrapped = idx + 1 >= gNSongs;
            idx = (idx + 1) % gNSongs;
            if (once && wrapped) break;
            if (r == R_END) {                               // 曲間（キーは受け付ける）
                allNotesOff();
                double until = nowSec() + gGap;
                while (nowSec() < until && !gQuit) { int k = keyGet(); if (k == 'q' || k == 'Q') { quit = 1; break; } if (k == 'n' || k == 'N' || k == ' ') break; sleepSec(0.02); }
            }
        }
    }
    allNotesOff();
    printf("\n終了しました\n"); logf_("終了");
    keysDone(); midiClose();
    if (gLog) fclose(gLog);
    return 0;
}
