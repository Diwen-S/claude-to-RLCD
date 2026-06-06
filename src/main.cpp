// Claude Code completion notifier — Waveshare ESP32-S3-RLCD-4.2
// 400x300 monochrome reflective LCD, ST7305 controller, U8g2 drawing.
//
// WiFi is provisioned via WiFiManager (captive portal "Claude-RLCD-Setup").
// Reachable at http://claude-rlcd.local/ once joined.
//
// HTTP endpoints (write endpoints require ?t=<token> once /pair has been called):
//   GET /                              status dump (incl. ip + paired y/n)
//   GET /notify?src=&status=&ts=&alert=&sp=&r=&wc=    update a source cell
//   GET /forget?src=  | /forget?all=1            clear source cell(s)
//   POST /todo?items=<lines>&date=<header>       replace today's calendar list (see handler for line format)
//   GET /pair?token=<4-32 alnum>                 set/rotate the pairing token
//   GET /unpair                                  clear token, back to open mode
//   GET /show-token                              flash token on LCD (unauth)
//   GET /reset-wifi                              wipe wifi creds, reopen portal
//   GET /quote-tour                              cycle every quote 5s for QA
//
// Multi-source: each `src` value gets its own cell in a grid that adapts to
// the count. Cells display a small label, a big status word, and an alert
// line drawn at the cell's bottom. Up to 4 sources are tracked; oldest evicts.
//
// Bottom strip rotates through a 20-quote pool (English Nobel + Hao Wang;
// simplified Chinese classical + modern intellectuals) keyed on UTC day index,
// with "A gift from Diwen Si" as the inscription.

#include <WiFi.h>
#include <WiFiManager.h>
#include <ESPmDNS.h>
#include <WebServer.h>
#include <Preferences.h>
#include <time.h>
#include <esp_rom_sys.h>
#include "ST7305_U8g2.h"

#define AP_SSID  "Claude-RLCD-Setup"
#define MDNS_HOST "claude-rlcd"

static Preferences g_prefs;
static String      g_token = "";   // empty = open mode (awaiting first /pair call)

// Pin map from Waveshare ESP32-S3-RLCD-4.2 official examples
#define RLCD_SCK_PIN   11
#define RLCD_MOSI_PIN  12
#define RLCD_DC_PIN     5
#define RLCD_CS_PIN    40
#define RLCD_RST_PIN   41
#define KEY_PIN        18   // on-board KEY button, active-low (per Waveshare pin table)

#define LCD_W 400
#define LCD_H 300

// Inverted theme: dark background, light foreground.
#define FG_COLOR 0
#define BG_COLOR 1

static ST7305_U8g2 lcd(RLCD_SCK_PIN, RLCD_MOSI_PIN, RLCD_DC_PIN, RLCD_CS_PIN, RLCD_RST_PIN);
static U8G2* u8g2 = nullptr;

WebServer server(80);

struct Source {
  String   id;       // short label, e.g. "Ubuntu (Code)"
  String   status;   // big word, e.g. "DONE", "WORKING"
  String   alert;    // optional line drawn at the cell's bottom (e.g. "Action required")
  uint32_t lastMs;   // millis() of last update — used for eviction order
};
static const int MAX_SRC = 4;
static Source g_src[MAX_SRC];
static int    g_nsrc = 0;

static String   g_lastStamp  = "--:--:--";
static uint32_t g_count      = 0;
static String   g_sessionPct = "--";
static String   g_resetAt    = "--:--";
static String   g_weeklyUsd  = "--";

// Today's calendar items, pushed by tools/calendar-push.py. Plain strings of
// the form "HH:MM <title>" or "--:-- <title>" for all-day events. Never
// persisted; sidecar reposts on its own timer.
static const int MAX_TODO = 8;
static String   g_todo[MAX_TODO];
static int      g_todoCount     = 0;
static uint32_t g_todoFetchedMs = 0;   // millis() at last successful push; 0 = never
static String   g_todoDate      = "";  // sidecar-provided header, e.g. "Sat  Jun 6"

// View = what stays on the LCD between KEY events. Toggled by single-tap; no
// auto-revert. Not persisted (a reboot returns to VIEW_MAIN).
enum ViewMode { VIEW_MAIN, VIEW_TODO };
static ViewMode g_view = VIEW_MAIN;

// Overlay = transient takeover that auto-dismisses back to the current view.
// Used by double-tap → pairing token. Kept non-blocking (no delay()) so the
// KEY handler can fire again before the overlay expires.
enum OverlayMode  { OVL_NONE, OVL_TOKEN };
static OverlayMode g_overlay        = OVL_NONE;
static uint32_t    g_overlayUntilMs = 0;

// Double-tap detection: the first short release arms a window; a second short
// release inside the window fires double-tap, expiry fires single-tap. 350ms
// is the conventional double-click threshold — short enough not to feel laggy.
static const uint32_t TAP_DOUBLE_MS  = 350;
static uint32_t       g_tapArmedUntilMs = 0;  // 0 = not armed

// ---- Daily quote pool --------------------------------------------------------
// Drawn from once per UTC day (index = days_since_epoch % NQ). Each quote line
// + author + the "A gift from Diwen Si" inscription occupy a 60-px strip below
// the source-cell grid. Mixed English (Nobel lecture / Hao Wang) and simplified
// Chinese (classical + modern Chinese intellectuals). All verified against
// primary sources — see obsidian/ESP32_RLCD/Development_log.md if updating.
struct Quote { const char* text; const char* author; bool chinese; };
static const Quote QUOTES[] = {
  // English (11)
  {"Economists are drawn to areas with simple, elegant, and uncontroversial models.", "O. Hart",      false},
  {"The logic of this model is refreshingly simple.",                                  "B. Holmstrom", false},
  {"There is no one right way about theorizing.",                                      "B. Holmstrom", false},
  {"Truth is not a Nash equilibrium.",                                                 "L. Hurwicz",   false},
  {"In mechanism design theory the direction of inquiry is reversed.",                 "E. Maskin",    false},
  {"Questions about fundamental social reforms require fundamental social theory.",    "R. Myerson",   false},
  {"Why do economists rely on such unrealistic assumptions?",                          "P. Milgrom",   false},
  {"It builds models that capture the essence of the situation.",                      "J. Tirole",    false},
  {"As any researcher, we know that our ideas can be used or abused -- or ignored.",   "J. Stiglitz",  false},
  {"The task is as intellectually exciting as it is difficult.",                       "G. Akerlof",   false},
  {"Zest for both system and objectivity is the formal logician's original sin.",      "H. Wang",      false},
  // Chinese (9, simplified)
  {"独立之精神，自由之思想。",                     "陈寅恪", true},
  {"不以物喜，不以己悲。",                         "范仲淹", true},
  {"回首向来萧瑟处，归去，也无风雨也无晴。",       "苏轼",   true},
  {"必神游冥想，与立说之古人，处于同一境界。",     "陈寅恪", true},
  {"衣带渐宽终不悔，为伊消得人憔悴。",             "柳永",   true},
  {"古人之所未及就，后世之所不可无，而后为之。",   "顾炎武", true},
  {"东海西海，心理攸同；南学北学，道术未裂。",     "钱钟书", true},
  {"史所贵者义也，而所具者事也，所凭者文也。",     "章学诚", true},
  {"捉住了这个主要矛盾，一切问题就迎刃而解了。",   "毛泽东", true},
};
static const int NQ = sizeof(QUOTES) / sizeof(QUOTES[0]);

// Calendar order: shuffled so that consecutive days alternate between the
// English (Nobel/Wang) and Chinese (classical + modern) pools. Two English
// quotes land back-to-back exactly once per 20-day cycle (positions 18-19
// across the wrap, since English outnumbers Chinese 11 to 9). Edit this
// table — not the QUOTES[] order above — if you want a different sequence.
static const uint8_t QUOTE_ORDER[] = {
   0,  // Hart                  (E)
  11,  // 陈寅恪 独立之精神      (C)
   1,  // Holmstrom logic       (E)
  12,  // 范仲淹  不以物喜       (C)
   3,  // Hurwicz               (E)
  13,  // 苏轼    回首向来       (C)
   4,  // Maskin                (E)
  14,  // 陈寅恪 神游冥想        (C)
   5,  // Myerson               (E)
  15,  // 柳永    衣带渐宽       (C)
   6,  // Milgrom               (E)
  16,  // 顾炎武 古人之所未及    (C)
   2,  // Holmstrom no one way  (E)
  17,  // 钱钟书 东海西海        (C)
   7,  // Tirole                (E)
  18,  // 章学诚 史所贵者        (C)
   9,  // Akerlof               (E)
  19,  // 毛泽东 主要矛盾        (C)
   8,  // Stiglitz              (E)
  10,  // Hao Wang              (E)
};
static_assert(sizeof(QUOTE_ORDER) == NQ, "QUOTE_ORDER must match QUOTES length");

// Returns the quote index for today, or -1 if NTP hasn't synced yet.
// `/quote-tour` overrides the slot transiently to cycle every quote for QA.
static int      g_quoteOverride   = -1;
static int      g_quoteTourIdx    = -1;       // -1 = not touring
static uint32_t g_quoteTourStart  = 0;
static const uint32_t QUOTE_TOUR_MS = 5000;   // 5s per quote

static int dailyQuoteIndex() {
  int slot;
  if (g_quoteOverride >= 0 && g_quoteOverride < NQ) {
    slot = g_quoteOverride;
  } else {
    time_t t = time(nullptr);
    if (t < 1700000000) return -1;   // not synced (Unix time before 2023-11)
    slot = (int)((t / 86400) % NQ);
  }
  return QUOTE_ORDER[slot];
}

static int findOrAddSource(const String& id) {
  for (int i = 0; i < g_nsrc; i++) if (g_src[i].id == id) { g_src[i].lastMs = millis(); return i; }
  if (g_nsrc < MAX_SRC) {
    g_src[g_nsrc] = {id, "", "", millis()};
    return g_nsrc++;
  }
  // At capacity: evict the oldest slot.
  int oldest = 0;
  for (int i = 1; i < MAX_SRC; i++) if (g_src[i].lastMs < g_src[oldest].lastMs) oldest = i;
  g_src[oldest] = {id, "", "", millis()};
  return oldest;
}

// 8-ray Claude burst (alternating long/short rays).
static void drawClaudeBurst(int cx, int cy, int rLong) {
  int rShort = rLong * 0.45f;
  u8g2->setDrawColor(FG_COLOR);
  for (int i = 0; i < 16; i++) {
    float a = i * (PI / 8.0f);
    int r = (i % 2 == 0) ? rLong : rShort;
    int x = cx + (int)(cosf(a) * r);
    int y = cy + (int)(sinf(a) * r);
    u8g2->drawLine(cx, cy, x, y);
    u8g2->drawLine(cx + 1, cy, x + 1, y);
    u8g2->drawLine(cx, cy + 1, x, y + 1);
    u8g2->drawLine(cx - 1, cy, x - 1, y);
    u8g2->drawLine(cx, cy - 1, x, y - 1);
  }
  u8g2->drawDisc(cx, cy, 5);
  u8g2->setDrawColor(BG_COLOR);
  u8g2->drawDisc(cx, cy, 3);
  u8g2->setDrawColor(FG_COLOR);
}

// Pick a status font that fits a given cell width × height.
static const uint8_t* pickStatusFont(int w, int h) {
  if (w >= 380 && h >= 150) return u8g2_font_osb41_tr;  // single cell
  if (h >= 150) return u8g2_font_osb29_tr;              // 2 cells (full height)
  return u8g2_font_osb21_tr;                            // 2x2 or short cells
}

static void renderCell(int x, int y, int w, int h, const Source& s) {
  u8g2->setDrawColor(FG_COLOR);

  // Label at the top of the cell
  if (s.id.length()) {
    u8g2->setFont(u8g2_font_6x13_tf);
    int lw = u8g2->getStrWidth(s.id.c_str());
    u8g2->drawStr(x + (w - lw) / 2, y + 13, s.id.c_str());
  }

  // Big status word, centered vertically inside the cell
  if (s.status.length()) {
    u8g2->setFont(pickStatusFont(w, h));
    int sw = u8g2->getStrWidth(s.status.c_str());
    int ascent  = u8g2->getAscent();
    int descent = u8g2->getDescent();      // negative
    int textH   = ascent - descent;
    int baseY   = y + (h - textH) / 2 + ascent;
    u8g2->drawStr(x + (w - sw) / 2, baseY, s.status.c_str());
  }

  // Alert at the bottom — bigger font for visibility (helvB14 ≈ 14px).
  if (s.alert.length()) {
    u8g2->setFont(u8g2_font_helvB14_tr);
    int aw = u8g2->getStrWidth(s.alert.c_str());
    u8g2->drawStr(x + (w - aw) / 2, y + h - 5, s.alert.c_str());
  }
}

// Cell region: y = 102 .. 234 (133 px tall). Bottom strip (235..295) holds
// the daily quote + inscription.
static void renderGrid() {
  const int Y0 = 102, H = 235 - Y0;   // 133 px tall
  if (g_nsrc == 0) {
    Source placeholder = {"", "READY", "", 0};
    renderCell(0, Y0, LCD_W, H, placeholder);
    return;
  }
  if (g_nsrc == 1) {
    renderCell(0, Y0, LCD_W, H, g_src[0]);
    return;
  }
  int rows = (g_nsrc + 1) / 2;
  int cellW = LCD_W / 2;
  int cellH = H / rows;
  for (int i = 0; i < g_nsrc; i++) {
    int row = i / 2;
    int col = i % 2;
    renderCell(col * cellW, Y0 + row * cellH, cellW, cellH, g_src[i]);
  }
}

// Bottom strip: daily quote, author attribution, and the gift inscription.
// Layout (y = 235..295):
//   y=235      top divider
//   ~y=255     quote — one line, or two lines for long English (>65 chars)
//   y=283      attribution (left)  +  inscription (right)
// Chinese quotes: WQY 12px GB2312 (covers hanzi + em-dash). English short
// (≤50): helvR10. English medium (51-65): helvR08, single line. English
// long (>65): helvR08 wrapped to two lines at the nearest space to midpoint.
static void renderBottomStrip() {
  u8g2->drawHLine(20, 235, 360);

  static const char* INSCRIPTION = "A gift from Diwen Si";

  int idx = dailyQuoteIndex();
  if (idx < 0) {
    u8g2->setFont(u8g2_font_helvR08_tr);
    int w = u8g2->getStrWidth(INSCRIPTION);
    u8g2->drawStr((LCD_W - w) / 2, 270, INSCRIPTION);
    return;
  }

  const Quote& q = QUOTES[idx];

  // ---- Quote line(s) -----------------------------------------------------
  if (q.chinese) {
    u8g2->setFont(u8g2_font_wqy12_t_gb2312);
    u8g2->drawUTF8(20, 260, q.text);
  } else {
    int len = strlen(q.text);
    if (len <= 65) {
      u8g2->setFont(len <= 50 ? u8g2_font_helvR10_tr : u8g2_font_helvR08_tr);
      u8g2->drawStr(20, 260, q.text);
    } else {
      // Wrap at the space closest to the midpoint.
      int mid = len / 2;
      int brk = mid;
      while (brk > 0 && q.text[brk] != ' ') brk--;
      if (brk == 0) brk = mid;
      char line1[120];
      int n = brk < 119 ? brk : 119;
      memcpy(line1, q.text, n);
      line1[n] = '\0';
      const char* line2 = q.text + brk + 1;
      u8g2->setFont(u8g2_font_helvR08_tr);
      u8g2->drawStr(20, 252, line1);
      u8g2->drawStr(20, 266, line2);
    }
  }

  // ---- Attribution (left) + Inscription (right) -------------------------
  // For Chinese authors the WQY font is required to render the hanzi (and
  // the em-dash, which is outside Latin-1). English-author attributions use
  // a compact "-- Name" in helvR08 for visual balance with the quote.
  if (q.chinese) {
    u8g2->setFont(u8g2_font_wqy12_t_gb2312);
    String att = String("— ") + q.author;
    u8g2->drawUTF8(20, 286, att.c_str());
  } else {
    u8g2->setFont(u8g2_font_helvR08_tr);
    String att = String("-- ") + q.author;
    u8g2->drawStr(20, 286, att.c_str());
  }
  u8g2->setFont(u8g2_font_helvR08_tr);
  int iw = u8g2->getStrWidth(INSCRIPTION);
  u8g2->drawStr(LCD_W - iw - 20, 286, INSCRIPTION);
}

static void renderMainView() {
  u8g2->clearBuffer();
  u8g2->setDrawColor(BG_COLOR);
  u8g2->drawBox(0, 0, LCD_W, LCD_H);
  u8g2->setDrawColor(FG_COLOR);

  // Top-left: Claude burst
  drawClaudeBurst(55, 55, 38);

  // Top-right: title, then two side-by-side blocks (usage | activity)
  u8g2->setFont(u8g2_font_helvB12_tr);
  u8g2->drawStr(120, 32, "Claude Code");

  // Usage block (left half of the top-right strip)
  u8g2->setFont(u8g2_font_6x13_tf);
  String l1 = "5h " + g_sessionPct + "%   reset " + g_resetAt;
  String l2 = "week $" + g_weeklyUsd;
  u8g2->drawStr(120, 58, l1.c_str());
  u8g2->drawStr(120, 78, l2.c_str());

  // Vertical separator between the two blocks
  u8g2->drawVLine(252, 44, 50);

  // Activity block (right half) — last update + response count
  String act1 = "last " + g_lastStamp;
  String act2 = "resp " + String(g_count);
  u8g2->drawStr(262, 58, act1.c_str());
  u8g2->drawStr(262, 78, act2.c_str());

  // IP, small, just above the divider
  if (WiFi.status() == WL_CONNECTED) {
    u8g2->setFont(u8g2_font_5x7_tf);
    String ip = "ip " + WiFi.localIP().toString();
    u8g2->drawStr(120, 96, ip.c_str());
  }

  // Single divider — cells extend all the way to the bottom edge.
  u8g2->drawHLine(20, 102, 360);

  renderGrid();

  // Pair hint as a subtitle under the big status word, while unpaired.
  if (g_token.length() == 0) {
    u8g2->setFont(u8g2_font_6x13_tf);
    const char* hint = "PAIR ME via ./install.sh in /claude-to-RLCD";
    int hw = u8g2->getStrWidth(hint);
    u8g2->drawStr((LCD_W - hw) / 2, 218, hint);
  }

  renderBottomStrip();

  u8g2->sendBuffer();
}

// Validate the ?t=... query arg against the saved token.
// When no token is saved (open mode), accept anything — covers the
// freshly-flashed / just-unpaired state until the first /pair call.
static bool authorized() {
  if (g_token.length() == 0) return true;
  if (!server.hasArg("t")) return false;
  return server.arg("t") == g_token;
}

// Tokens must be 4–32 chars, alphanumeric only (keeps URL-encoding trivial).
static bool validTokenShape(const String& t) {
  if (t.length() < 4 || t.length() > 32) return false;
  for (size_t i = 0; i < t.length(); i++) {
    char c = t.charAt(i);
    if (!((c >= '0' && c <= '9') || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z'))) return false;
  }
  return true;
}

// Briefly flash the current token on the LCD for visual recovery.
static void renderTokenBanner(const String& tok) {
  u8g2->clearBuffer();
  u8g2->setDrawColor(BG_COLOR);
  u8g2->drawBox(0, 0, LCD_W, LCD_H);
  u8g2->setDrawColor(FG_COLOR);
  u8g2->setFont(u8g2_font_helvB14_tr);
  const char* label = "Pairing token";
  int lw = u8g2->getStrWidth(label);
  u8g2->drawStr((LCD_W - lw) / 2, 100, label);
  u8g2->setFont(u8g2_font_osb29_tr);
  int tw = u8g2->getStrWidth(tok.c_str());
  u8g2->drawStr((LCD_W - tw) / 2, 175, tok.c_str());
  u8g2->setFont(u8g2_font_6x13_tf);
  const char* hint = "Type this into install.sh on your machine";
  int hw = u8g2->getStrWidth(hint);
  u8g2->drawStr((LCD_W - hw) / 2, 225, hint);
  u8g2->sendBuffer();
}

// Full-screen takeover shown on the calendar view. Each stored line is three
// tab-separated fields: "<start>\t<end>\t<title>". Start is bold and large;
// end is rendered after a thin en-dash in a smaller weight so the eye snags
// on the start time (the conventional "ambient calendar" cue used by
// Fantastical/BusyCal). A row whose start field is literally "now" is
// rendered as a horizontal divider with the current HH:MM labelled at left.
static void renderTodoBanner() {
  u8g2->clearBuffer();
  u8g2->setDrawColor(BG_COLOR);
  u8g2->drawBox(0, 0, LCD_W, LCD_H);
  u8g2->setDrawColor(FG_COLOR);

  // Header band — date at left in display weight, freshness right-aligned and
  // tucked into the small font so the eye reads "<date>" first.
  u8g2->setFont(u8g2_font_helvB18_tr);
  const char* dateStr = g_todoDate.length() ? g_todoDate.c_str() : "Today";
  u8g2->drawStr(20, 36, dateStr);
  u8g2->setFont(u8g2_font_6x10_tf);
  String age;
  if (g_todoFetchedMs) {
    uint32_t ageMin = (millis() - g_todoFetchedMs) / 60000;
    age = "updated " + String(ageMin) + "m ago";
  } else {
    age = "no sidecar push yet";
  }
  int aw = u8g2->getStrWidth(age.c_str());
  u8g2->drawStr(LCD_W - 20 - aw, 36, age.c_str());
  u8g2->drawHLine(20, 48, LCD_W - 40);

  if (g_todoCount == 0) {
    u8g2->setFont(u8g2_font_helvR14_tr);
    u8g2->drawStr(20, 96, "no events today");
    u8g2->sendBuffer();
    return;
  }

  const int kRowH      = 30;
  const int kStartX    = 20;
  const int kEndOffX   = 8;    // gap between start and the dash
  const int kEndGapX   = 4;    // gap between dash and end string
  const int kTitleX    = 160;  // shared baseline for titles
  const int kFirstBase = 82;

  for (int i = 0; i < g_todoCount; i++) {
    int y = kFirstBase + i * kRowH;
    String line = g_todo[i];
    int t1 = line.indexOf('\t');
    int t2 = (t1 >= 0) ? line.indexOf('\t', t1 + 1) : -1;
    String sField = (t1 >= 0) ? line.substring(0, t1)        : line;
    String eField = (t2 >= 0) ? line.substring(t1 + 1, t2)   : String("");
    String mField = (t2 >= 0) ? line.substring(t2 + 1)
                             : (t1 >= 0 ? line.substring(t1 + 1) : String(""));

    if (sField == "now") {
      // Now-divider. Dashed HLine across the row with a bold time pill at the
      // left so the eye locates "now" at a glance and the past/future split is
      // unambiguous. Row pitch unchanged so spacing stays consistent.
      int by = y - 8;  // visual middle of the row
      u8g2->setFont(u8g2_font_helvB12_tr);
      String nowLabel = "now  " + mField;
      int nw = u8g2->getStrWidth(nowLabel.c_str());
      u8g2->drawStr(kStartX, y - 2, nowLabel.c_str());
      // dashed line to the right of the label
      int lineStart = kStartX + nw + 10;
      int lineEnd   = LCD_W - 20;
      for (int x = lineStart; x < lineEnd; x += 6) {
        int seg = (lineEnd - x < 3) ? (lineEnd - x) : 3;
        u8g2->drawHLine(x, by, seg);
      }
      continue;
    }

    // Start time: bold and full size, draws the eye.
    u8g2->setFont(u8g2_font_helvB14_tr);
    u8g2->drawStr(kStartX, y, sField.c_str());

    // End time + dash: render only if present, smaller and regular weight so
    // it reads as secondary information.
    if (eField.length()) {
      int sw = u8g2->getStrWidth(sField.c_str());
      u8g2->setFont(u8g2_font_helvR10_tr);
      int dashX = kStartX + sw + kEndOffX;
      u8g2->drawStr(dashX, y - 1, "-");
      int dashW = u8g2->getStrWidth("-");
      u8g2->drawStr(dashX + dashW + kEndGapX, y - 1, eField.c_str());
    }

    // Title: regular weight, slightly larger than the end-time to dominate
    // visually over the secondary metadata.
    u8g2->setFont(u8g2_font_helvR14_tr);
    u8g2->drawStr(kTitleX, y, mField.c_str());
  }
  u8g2->sendBuffer();
}

// Public repaint entrypoint: dispatch on the active view. Every existing
// call site (HTTP handlers, KEY holds, quote tour, boot) goes through here,
// so the calendar view isn't yanked away by a /notify or daily-quote tick.
static void render() {
  if (g_view == VIEW_TODO) renderTodoBanner();
  else                     renderMainView();
}

// Full-screen takeover shown while the WiFi config portal is open.
static void renderPortalScreen(const String& apIp) {
  u8g2->clearBuffer();
  u8g2->setDrawColor(BG_COLOR);
  u8g2->drawBox(0, 0, LCD_W, LCD_H);
  u8g2->setDrawColor(FG_COLOR);

  drawClaudeBurst(55, 55, 38);

  u8g2->setFont(u8g2_font_helvB14_tr);
  u8g2->drawStr(120, 45, "WiFi setup needed");

  u8g2->setFont(u8g2_font_6x13_tf);
  u8g2->drawStr(120, 72, "From your phone, join:");
  u8g2->setFont(u8g2_font_helvB14_tr);
  u8g2->drawStr(120, 92, AP_SSID);

  u8g2->drawHLine(20, 115, 360);

  u8g2->setFont(u8g2_font_6x13_tf);
  u8g2->drawStr(30, 145, "1. Open WiFi settings on phone");
  u8g2->drawStr(30, 165, "2. Join " AP_SSID);
  u8g2->drawStr(30, 185, "3. Browser opens; pick your WiFi");
  u8g2->drawStr(30, 205, "4. Device reboots and shows IP");

  u8g2->drawHLine(20, 225, 360);

  u8g2->setFont(u8g2_font_5x7_tf);
  String hint = "Portal IP: " + apIp + "  (auto-opens on most phones)";
  u8g2->drawStr(30, 250, hint.c_str());
  u8g2->drawStr(30, 270, "Reach later at: http://" MDNS_HOST ".local/");

  u8g2->sendBuffer();
}

static void handleRoot() {
  String s = "Claude RLCD notifier\n";
  s += "sources = " + String(g_nsrc) + "\n";
  for (int i = 0; i < g_nsrc; i++) {
    s += "  [" + g_src[i].id + "] status=" + g_src[i].status;
    if (g_src[i].alert.length()) s += " alert=\"" + g_src[i].alert + "\"";
    s += "\n";
  }
  s += "last   = " + g_lastStamp + "\n";
  s += "count  = " + String(g_count) + "\n";
  s += "5h%    = " + g_sessionPct + "\n";
  s += "reset  = " + g_resetAt + "\n";
  s += "week$  = " + g_weeklyUsd + "\n";
  s += "todo   = " + String(g_todoCount) + " items";
  if (g_todoFetchedMs) {
    s += " (updated " + String((millis() - g_todoFetchedMs) / 60000) + "m ago)\n";
  } else {
    s += " (no push yet)\n";
  }
  for (int i = 0; i < g_todoCount; i++) {
    s += "         " + g_todo[i] + "\n";
  }
  s += "ip     = " + WiFi.localIP().toString() + "\n";
  s += "paired = " + String(g_token.length() ? "yes" : "no (open mode — call /pair)") + "\n";
  server.send(200, "text/plain", s);
}

static void handleNotify() {
  if (!authorized()) { server.send(403, "text/plain", "forbidden: missing or wrong ?t=<token>\n"); return; }
  String srcId = (server.hasArg("src") && server.arg("src").length())
                  ? server.arg("src") : String("main");
  int idx = findOrAddSource(srcId);
  Source& src = g_src[idx];

  if (server.hasArg("status") && server.arg("status").length()) {
    String st = server.arg("status"); st.toUpperCase();
    src.status = st;
    if (server.hasArg("ts") && server.arg("ts").length()) g_lastStamp = server.arg("ts");
    if (st == "DONE") g_count++;
  }
  if (server.hasArg("alert")) src.alert = server.arg("alert");
  if (server.hasArg("sp") && server.arg("sp").length()) g_sessionPct = server.arg("sp");
  if (server.hasArg("r")  && server.arg("r").length())  g_resetAt    = server.arg("r");
  if (server.hasArg("wc") && server.arg("wc").length()) g_weeklyUsd  = server.arg("wc");

  render();
  server.send(200, "text/plain", "ok\n");
}

// ---- KEY button handler -----------------------------------------------------
// Gestures (no laptop / no network needed):
//   single tap:     toggle main Claude view ↔ calendar view (both persist; no auto-revert)
//   double tap:     flash pairing token on the LCD for 5s, then back to the active view
//   hold 5s:        clear all source cells (= /forget?all=1)
//   hold 15s:       factory reset — wipe WiFi creds + token, reboot into portal
// Tap timing: the first short release arms a ~350ms window. A second release
// inside that window fires double-tap; expiry fires single-tap. The slight
// latency on single-tap is the cost of unambiguous single/double detection.
// Holding past 1s shows an on-screen prompt with a progress bar so the user
// can release in time. Releasing at 1-5s aborts.
static int      g_keyState        = HIGH;
static uint32_t g_keyDownMs       = 0;
static uint32_t g_keyLastChangeMs = 0;
static uint32_t g_keyLastHintMs   = 0;
static int      g_keyTier         = 0;   // 0=armed-nothing, 1=clear-armed, 2=reset-armed

static void renderKeyHint(uint32_t heldMs) {
  u8g2->clearBuffer();
  u8g2->setDrawColor(BG_COLOR);
  u8g2->drawBox(0, 0, LCD_W, LCD_H);
  u8g2->setDrawColor(FG_COLOR);
  u8g2->setFont(u8g2_font_helvB14_tr);
  if (heldMs < 5000) {
    u8g2->drawStr(40, 60, "Holding KEY...");
    u8g2->setFont(u8g2_font_6x13_tf);
    u8g2->drawStr(40, 110, "Release now: nothing happens");
    u8g2->drawStr(40, 135, "Hold 5s: clear all source cells");
    u8g2->drawStr(40, 160, "Hold 15s: factory reset");
    int barW = (int)((uint64_t)heldMs * (LCD_W - 80) / 5000);
    u8g2->drawFrame(40, 220, LCD_W - 80, 16);
    u8g2->drawBox(40, 220, barW, 16);
    u8g2->setFont(u8g2_font_5x7_tf);
    u8g2->drawStr(40, 250, "next: clear cells (5s)");
  } else {
    u8g2->drawStr(40, 60, "Clear-cells armed");
    u8g2->setFont(u8g2_font_6x13_tf);
    u8g2->drawStr(40, 110, "Release now: clears all source cells");
    u8g2->drawStr(40, 135, "Hold 15s total: FACTORY RESET");
    u8g2->drawStr(40, 160, "(wipes WiFi + pairing token)");
    int barW = (int)((uint64_t)(heldMs - 5000) * (LCD_W - 80) / 10000);
    u8g2->drawFrame(40, 220, LCD_W - 80, 16);
    u8g2->drawBox(40, 220, barW, 16);
    u8g2->setFont(u8g2_font_5x7_tf);
    u8g2->drawStr(40, 250, "next: factory reset (15s)");
  }
  u8g2->sendBuffer();
}

static void handleKey() {
  int v = digitalRead(KEY_PIN);
  uint32_t now = millis();

  if (v != g_keyState && (now - g_keyLastChangeMs > 30)) {
    g_keyState        = v;
    g_keyLastChangeMs = now;
    if (v == LOW) {
      g_keyDownMs     = now;
      g_keyLastHintMs = 0;
      g_keyTier       = 0;
    } else {
      uint32_t held = now - g_keyDownMs;
      g_keyDownMs = 0;
      if (held < 1000) {
        // Single tap = toggle main↔todo view (persistent). Double tap = show
        // pairing token for 5s. The first release arms a window; if a second
        // release lands inside it we've seen a double; otherwise the loop
        // fires the single after the window expires (so the gestures don't
        // collide).
        if (g_tapArmedUntilMs && (int32_t)(now - g_tapArmedUntilMs) <= 0) {
          g_tapArmedUntilMs = 0;
          if (g_token.length()) {
            renderTokenBanner(g_token);
            g_overlay        = OVL_TOKEN;
            g_overlayUntilMs = now + 5000;
          }
        } else {
          g_tapArmedUntilMs = now + TAP_DOUBLE_MS;
        }
      } else if (g_keyTier == 1) {
        g_nsrc = 0;
        esp_rom_printf("[key] cleared all source cells\n");
      }
      g_keyTier = 0;
      // Don't repaint if a tap just put us into an overlay — it would erase
      // the banner the user is trying to read. Otherwise refresh whichever
      // view the user has chosen (main or calendar).
      if (g_overlay == OVL_NONE) render();
    }
  }

  if (g_keyDownMs && (now - g_keyDownMs) > 1000) {
    uint32_t held = now - g_keyDownMs;
    if (now - g_keyLastHintMs > 500) {
      renderKeyHint(held);
      g_keyLastHintMs = now;
    }
    if (held >= 5000  && g_keyTier < 1) g_keyTier = 1;
    if (held >= 15000 && g_keyTier < 2) {
      g_keyTier = 2;
      esp_rom_printf("[key] FACTORY RESET\n");
      g_prefs.clear();
      g_token = "";
      WiFiManager wm2;
      wm2.resetSettings();
      u8g2->clearBuffer();
      u8g2->setDrawColor(BG_COLOR);
      u8g2->drawBox(0, 0, LCD_W, LCD_H);
      u8g2->setDrawColor(FG_COLOR);
      u8g2->setFont(u8g2_font_helvB14_tr);
      u8g2->drawStr(80, 150, "FACTORY RESET");
      u8g2->setFont(u8g2_font_6x13_tf);
      u8g2->drawStr(80, 180, "rebooting...");
      u8g2->sendBuffer();
      delay(2000);
      ESP.restart();
    }
  }
}

void setup() {
  esp_rom_printf("[boot] Claude RLCD notifier\n");

  pinMode(KEY_PIN, INPUT_PULLUP);

  g_prefs.begin("claude-rlcd", false);
  g_token = g_prefs.getString("token", "");
  esp_rom_printf("[auth] %s\n", g_token.length() ? "paired" : "OPEN MODE — call /pair?token=...");

  lcd.begin(0, U8G2_R1);
  u8g2 = lcd.getU8g2();
  esp_rom_printf("[boot] LCD ok\n");

  render();
  esp_rom_printf("[boot] BOOT painted\n");

  WiFi.mode(WIFI_STA);

  WiFiManager wm;
  wm.setConfigPortalBlocking(true);
  wm.setConfigPortalTimeout(0);   // wait forever; user is expected to finish setup
  wm.setAPCallback([](WiFiManager* m) {
    esp_rom_printf("[wifi] portal open, AP=%s ip=%s\n",
                   AP_SSID, WiFi.softAPIP().toString().c_str());
    renderPortalScreen(WiFi.softAPIP().toString());
  });

  if (!wm.autoConnect(AP_SSID)) {
    esp_rom_printf("[wifi] autoConnect failed, rebooting\n");
    delay(1500);
    ESP.restart();
  }
  esp_rom_printf("[wifi] ip=%s\n", WiFi.localIP().toString().c_str());

  if (MDNS.begin(MDNS_HOST)) {
    MDNS.addService("http", "tcp", 80);
    esp_rom_printf("[mdns] http://%s.local/\n", MDNS_HOST);
  } else {
    esp_rom_printf("[mdns] begin failed\n");
  }

  // NTP — UTC only; used solely to index the daily quote pool by
  // days-since-epoch. Display timestamps still come from the driving machine.
  configTzTime("UTC0", "pool.ntp.org", "time.google.com");

  server.on("/",       handleRoot);
  server.on("/notify", handleNotify);

  // Pair / re-pair. In open mode anyone on LAN can pair; once paired, the
  // existing token is required to change it. ?token=NEWVAL sets a new token.
  server.on("/pair", []() {
    if (g_token.length() != 0 && !authorized()) {
      server.send(403, "text/plain", "forbidden: device already paired, supply current ?t=<token>\n");
      return;
    }
    if (!server.hasArg("token")) {
      server.send(400, "text/plain", "usage: /pair?token=<4-32 alnum>[&t=<current-token>]\n");
      return;
    }
    String nt = server.arg("token");
    if (!validTokenShape(nt)) {
      server.send(400, "text/plain", "token must be 4-32 alphanumeric chars\n");
      return;
    }
    g_token = nt;
    g_prefs.putString("token", g_token);
    esp_rom_printf("[auth] paired with new token (%d chars)\n", g_token.length());
    renderTokenBanner(g_token);
    delay(2500);
    render();
    server.send(200, "text/plain", "paired ok\n");
  });

  // Flash the current token on the LCD for visual recovery — unauth on
  // purpose: needs physical line-of-sight to be useful.
  server.on("/show-token", []() {
    if (g_token.length() == 0) {
      server.send(200, "text/plain", "no token set (open mode)\n");
      return;
    }
    renderTokenBanner(g_token);
    server.send(200, "text/plain", "token shown on LCD for ~5s\n");
    delay(5000);
    render();
  });

  // Clear the saved pairing token — device returns to open mode (any LAN
  // host can now /pair it). Doesn't touch WiFi creds or source cells.
  server.on("/unpair", []() {
    if (!authorized()) { server.send(403, "text/plain", "forbidden: missing or wrong ?t=<token>\n"); return; }
    g_prefs.remove("token");
    g_token = "";
    esp_rom_printf("[auth] unpaired — back to open mode\n");
    render();
    server.send(200, "text/plain", "unpaired — device is now in open mode, /pair to re-secure\n");
  });

  server.on("/reset-wifi", []() {
    if (!authorized()) { server.send(403, "text/plain", "forbidden: missing or wrong ?t=<token>\n"); return; }
    server.send(200, "text/plain", "wiping wifi creds, rebooting\n");
    delay(300);
    WiFiManager wm2;
    wm2.resetSettings();
    delay(300);
    ESP.restart();
  });

  // Cycle through every quote in the pool, 5s each. Non-blocking — the loop
  // advances the index from millis(). Useful for visual QA after editing the
  // pool. No auth required: read-only effect that auto-clears.
  server.on("/quote-tour", []() {
    g_quoteTourIdx   = 0;
    g_quoteTourStart = millis();
    g_quoteOverride  = 0;
    render();
    String s = "quote tour started — " + String(NQ) + " quotes, " +
               String(QUOTE_TOUR_MS / 1000) + "s each (~" +
               String((NQ * QUOTE_TOUR_MS) / 1000) + "s total)\n";
    server.send(200, "text/plain", s.c_str());
  });

  // Receive today's calendar list from tools/calendar-push.py. `items` is a
  // newline-separated body where each line is three tab-separated fields:
  //   "<start>\t<end>\t<title>"
  // <start> = "HH:MM" | "all day" | "now"
  // <end>   = "HH:MM" | "" (empty if unknown / instantaneous / all-day)
  // <title> = the event title, or for the special "now" row, the current HH:MM
  // We store up to MAX_TODO lines and also save the optional `date` arg as
  // the header label (e.g. "Sat  Jun 6"). Accepts GET or POST; sidecar uses
  // POST with a query string so the body doesn't end up in shell history.
  server.on("/todo", []() {
    if (!authorized()) { server.send(403, "text/plain", "forbidden: missing or wrong ?t=<token>\n"); return; }
    String items = server.hasArg("items") ? server.arg("items") : String("");
    if (server.hasArg("date")) g_todoDate = server.arg("date");
    g_todoCount = 0;
    int start = 0;
    while (start <= (int)items.length() && g_todoCount < MAX_TODO) {
      int nl = items.indexOf('\n', start);
      if (nl < 0) nl = items.length();
      String line = items.substring(start, nl);
      line.trim();
      if (line.length() > 0) g_todo[g_todoCount++] = line;
      if (nl >= (int)items.length()) break;
      start = nl + 1;
    }
    g_todoFetchedMs = millis();
    if (g_view == VIEW_TODO) render();  // refresh in-place if user is on the calendar view
    String resp = "ok (" + String(g_todoCount) + " items)\n";
    server.send(200, "text/plain", resp.c_str());
  });

  server.on("/forget", []() {
    if (!authorized()) { server.send(403, "text/plain", "forbidden: missing or wrong ?t=<token>\n"); return; }
    if (server.hasArg("all")) { g_nsrc = 0; }
    else if (server.hasArg("src")) {
      for (int i = 0; i < g_nsrc; i++) {
        if (g_src[i].id == server.arg("src")) {
          for (int j = i; j < g_nsrc - 1; j++) g_src[j] = g_src[j + 1];
          g_nsrc--;
          break;
        }
      }
    }
    render();
    server.send(200, "text/plain", "ok\n");
  });
  server.begin();
  esp_rom_printf("[http] listening on :80\n");

  render();
  esp_rom_printf("[boot] READY\n");
}

void loop() {
  server.handleClient();
  handleKey();

  // Auto-dismiss the token overlay once its 5s window expires, returning to
  // whichever view (main or todo) the user had toggled to. Done in loop()
  // rather than via delay() so KEY remains responsive while the banner is up.
  if (g_overlay != OVL_NONE && (int32_t)(millis() - g_overlayUntilMs) >= 0) {
    g_overlay = OVL_NONE;
    render();
  }

  // Fire the single-tap action once the double-tap window has lapsed without
  // a second release. Single-tap = toggle main↔todo view.
  if (g_tapArmedUntilMs && (int32_t)(millis() - g_tapArmedUntilMs) >= 0) {
    g_tapArmedUntilMs = 0;
    g_view = (g_view == VIEW_MAIN) ? VIEW_TODO : VIEW_MAIN;
    render();
  }

  // Advance the quote tour, if one is running.
  if (g_quoteTourIdx >= 0) {
    int newIdx = (millis() - g_quoteTourStart) / QUOTE_TOUR_MS;
    if (newIdx >= NQ) {
      g_quoteTourIdx  = -1;
      g_quoteOverride = -1;
      render();
    } else if (newIdx != g_quoteTourIdx) {
      g_quoteTourIdx  = newIdx;
      g_quoteOverride = newIdx;
      render();
    }
  }

  // Re-render once when the UTC day rolls over so the daily quote updates
  // even if no hook fires that day.
  static int s_lastDay = -2;
  int d = dailyQuoteIndex();
  if (d != s_lastDay && g_quoteTourIdx < 0) {
    s_lastDay = d;
    render();
  }

  delay(2);
}
