#include <SDL3/SDL.h>
#include <stdlib.h>
#include <string.h>
#include <stdbool.h>
#include <stdlib.h>
#include <ctype.h>
#include <errno.h>
#include <sys/types.h>
#include <sys/stat.h>
#include "api.h"
#include "../rencache.h"
#include "../renwindow.h"
#ifdef _WIN32
  #include <direct.h>
  #include <windows.h>
  #include <fileapi.h>
  #include "../utfconv.h"

  // Windows does not define the S_ISREG and S_ISDIR macros in stat.h, so we do.
  // We have to define _CRT_INTERNAL_NONSTDC_NAMES 1 before #including sys/stat.h
  // in order for Microsoft's stat.h to define names like S_IFMT, S_IFREG, and S_IFDIR,
  // rather than just defining  _S_IFMT, _S_IFREG, and _S_IFDIR as it normally does.
  #define _CRT_INTERNAL_NONSTDC_NAMES 1
  #include <sys/types.h>
  #include <sys/stat.h>
  #if !defined(S_ISREG) && defined(S_IFMT) && defined(S_IFREG)
    #define S_ISREG(m) (((m) & S_IFMT) == S_IFREG)
  #endif
  #if !defined(S_ISDIR) && defined(S_IFMT) && defined(S_IFDIR)
    #define S_ISDIR(m) (((m) & S_IFMT) == S_IFDIR)
  #endif
#else

#include <dirent.h>
#include <unistd.h>

#ifdef __linux__
  #include <sys/vfs.h>
#endif
#endif

static const char* button_name(int button) {
  switch (button) {
    case SDL_BUTTON_LEFT   : return "left";
    case SDL_BUTTON_MIDDLE : return "middle";
    case SDL_BUTTON_RIGHT  : return "right";
    case SDL_BUTTON_X1     : return "x";
    case SDL_BUTTON_X2     : return "y";
    default : return "?";
  }
}


static void str_tolower(char *p) {
  while (*p) {
    *p = tolower(*p);
    p++;
  }
}

#define MAX_HIT_TEST_RECTS 32

/* The borderless window's hit test, in Lua's coordinates: the title strip is
** draggable (moves the window) except for the controls at its right and the
** rects of other interactive items on it; edges and corners resize. */
struct HitTestInfo {
  int title_height;
  int controls_width;
  int resize_border;
  int rect_count;
  SDL_Rect rects[MAX_HIT_TEST_RECTS];
};
typedef struct HitTestInfo HitTestInfo;

static HitTestInfo window_hit_info[1] = {{0, 0, 0}};

/* The last press that started a window move (SDL's hit-test event). A press
** soon after it, near it, is a double-click: the hit test then lets it through
** to the app, as a press with 2 clicks, rather than starting another move. */
static struct {
  Uint64 ticks;
  float x, y; /* global */
  int clicks;
  bool pass_next;
} title_press;

#define TITLE_DOUBLE_CLICK_RADIUS 4

static Uint64 double_click_time(void) {
  const char *hint = SDL_GetHint(SDL_HINT_MOUSE_DOUBLE_CLICK_TIME);
  return hint && *hint ? (Uint64) SDL_atoi(hint) : 500;
}

/* Whether a press now at x, y (global) would be a double-click with the last
** title press. */
static bool title_double_click_at(float x, float y) {
  if (title_press.ticks == 0 || SDL_GetTicks() - title_press.ticks > double_click_time())
    return false;
  return SDL_fabsf(x - title_press.x) <= TITLE_DOUBLE_CLICK_RADIUS &&
    SDL_fabsf(y - title_press.y) <= TITLE_DOUBLE_CLICK_RADIUS;
}

static bool title_double_click(void) {
  float x, y;
  SDL_GetGlobalMouseState(&x, &y);
  return title_double_click_at(x, y);
}

static SDL_HitTestResult hit_test_area(SDL_Window *window, const SDL_Point *pt) {
  const HitTestInfo *hit_info = window_hit_info;
  const int x = pt->x * window_renderer.scale_x, y = pt->y * window_renderer.scale_y;
  int w, h;
  SDL_GetWindowSize(window, &w, &h);
  w *= window_renderer.scale_x;
  h *= window_renderer.scale_y;

  /* no resizing when maximized or fullscreen */
  const int b = (SDL_GetWindowFlags(window) & (SDL_WINDOW_MAXIMIZED | SDL_WINDOW_FULLSCREEN))
    ? 0 : hit_info->resize_border;
  const bool left = x < b, right = x >= w - b, top = y < b, bottom = y >= h - b;
  if (top && left) return SDL_HITTEST_RESIZE_TOPLEFT;
  if (top && right) return SDL_HITTEST_RESIZE_TOPRIGHT;
  if (bottom && left) return SDL_HITTEST_RESIZE_BOTTOMLEFT;
  if (bottom && right) return SDL_HITTEST_RESIZE_BOTTOMRIGHT;
  if (top) return SDL_HITTEST_RESIZE_TOP;
  if (bottom) return SDL_HITTEST_RESIZE_BOTTOM;
  if (left) return SDL_HITTEST_RESIZE_LEFT;
  if (right) return SDL_HITTEST_RESIZE_RIGHT;

  if (y < hit_info->title_height && x < w - hit_info->controls_width) {
    const SDL_Point p = { x, y };
    for (int i = 0; i < hit_info->rect_count; i++) {
      if (SDL_PointInRect(&p, &hit_info->rects[i])) return SDL_HITTEST_NORMAL;
    }
    return SDL_HITTEST_DRAGGABLE;
  }
  return SDL_HITTEST_NORMAL;
}

/* The last point tested and its area: what a press there would do (X11 calls
** the hit test on motion, and uses the last result on a press). */
static SDL_Point last_hit_point;
static SDL_HitTestResult last_hit_area;

static SDL_HitTestResult SDLCALL hit_test(SDL_Window *window, const SDL_Point *pt, void *data) {
  SDL_HitTestResult rc = hit_test_area(window, pt);
  last_hit_point = *pt;
  last_hit_area = rc;
  if (rc == SDL_HITTEST_DRAGGABLE && title_double_click()) {
    title_press.pass_next = true;
    return SDL_HITTEST_NORMAL;
  }
  return rc;
}

static const char *numpad[] = { "end", "down", "pagedown", "left", "", "right", "home", "up", "pageup", "ins", "delete" };

static const char *get_key_name(const SDL_Event *e, char *buf) {
  SDL_Scancode scancode = e->key.scancode;
  /* Is the scancode from the keypad and the number-lock off?
  ** We assume that SDL_SCANCODE_KP_1 up to SDL_SCANCODE_KP_9 and SDL_SCANCODE_KP_0
  ** and SDL_SCANCODE_KP_PERIOD are declared in SDL2 in that order. */
  if (scancode >= SDL_SCANCODE_KP_1 && scancode <= SDL_SCANCODE_KP_1 + 10 &&
    !(e->key.mod & SDL_KMOD_NUM)) {
    return numpad[scancode - SDL_SCANCODE_KP_1];
  } else {
    /* We need to correctly handle non-standard layouts such as dvorak.
       Therefore, if a Latin letter(code<128) is pressed in the current layout,
       then we transmit it as it is. But we also need to support shortcuts in
       other languages, so for non-Latin characters(code>128) we pass the
       scancode based name that matches the letter in the QWERTY layout.

       In SDL, the codes of all special buttons such as control, shift, arrows
       and others, are masked with SDLK_SCANCODE_MASK, which moves them outside
       the unicode range (>0x10FFFF). Users can remap these buttons, so we need
       to return the correct name, not scancode based. */
    if ((e->key.key < 128) || (e->key.key & SDLK_SCANCODE_MASK))
      strcpy(buf, SDL_GetKeyName(e->key.key));
    else
      strcpy(buf, SDL_GetScancodeName(scancode));
    str_tolower(buf);
    return buf;
  }
}

#ifdef _WIN32
static char *win32_error(DWORD rc) {
  LPSTR message;
  FormatMessage(
    FORMAT_MESSAGE_ALLOCATE_BUFFER |
    FORMAT_MESSAGE_FROM_SYSTEM |
    FORMAT_MESSAGE_IGNORE_INSERTS,
    NULL,
    rc,
    MAKELANGID(LANG_NEUTRAL, SUBLANG_DEFAULT),
    (LPTSTR) &message,
    0,
    NULL
  );

  return message;
}

static void push_win32_error(lua_State *L, DWORD rc) {
  LPSTR message = win32_error(rc);
  lua_pushstring(L, message);
  LocalFree(message);
}
#endif

// posted by file dialogs (SDL calls their callbacks from any thread)
static unsigned int DIALOG_EVENT_TYPE = 0;
typedef enum { DIALOG_OK, DIALOG_CANCEL, DIALOG_ERROR } DialogState;

static int push_dialog_event(lua_State *L, SDL_Event *e) {
  lua_pushstring(L, "dialogfinished");
  lua_pushinteger(L, (lua_Integer) (intptr_t) e->user.data1);
  switch ((DialogState) e->user.code) {
    case DIALOG_OK: {
      // the paths, one after another, each NUL-terminated; an empty one ends them
      lua_pushstring(L, "accept");
      lua_newtable(L);
      const char *path = e->user.data2;
      for (int i = 1; *path; i++) {
        lua_pushstring(L, path);
        lua_rawseti(L, -2, i);
        path += strlen(path) + 1;
      }
      SDL_free(e->user.data2);
      return 4;
    }
    case DIALOG_CANCEL:
      lua_pushstring(L, "cancel");
      return 3;
    default:
      lua_pushstring(L, "error");
      lua_pushstring(L, e->user.data2 ? e->user.data2 : "out of memory");
      SDL_free(e->user.data2);
      return 4;
  }
}

static int f_poll_event(lua_State *L) {
  char buf[16];
  float mx, my;
  int w, h;
  SDL_Event e;
  SDL_Event event_plus;

top:
  if ( !SDL_PollEvent(&e) ) {
    return 0;
  }

  // background threads' events (registered at run time, so not switch cases)
  if (DIR_EVENT_TYPE && e.type == DIR_EVENT_TYPE) {
    // a dirmonitor posts one every millisecond until its changes are checked
    SDL_FlushEvent(DIR_EVENT_TYPE);
    lua_pushstring(L, "dirchange");
    return 1;
  }
  if (READWATCH_EVENT_TYPE && e.type == READWATCH_EVENT_TYPE) {
    lua_pushstring(L, "readable");
    lua_pushinteger(L, (lua_Integer) (intptr_t) e.user.data1);
    return 2;
  }
  if (DIALOG_EVENT_TYPE && e.type == DIALOG_EVENT_TYPE)
    return push_dialog_event(L, &e);

  switch (e.type) {
    case SDL_EVENT_QUIT:
      lua_pushstring(L, "quit");
      return 1;

    case SDL_EVENT_WINDOW_RESIZED:
      {
        ren_resize_window(&window_renderer);
        lua_pushstring(L, "resized");
        /* The size below will be in points. */
        lua_pushinteger(L, e.window.data1);
        lua_pushinteger(L, e.window.data2);
        return 3;
      }

    case SDL_EVENT_WINDOW_EXPOSED:
      rencache_invalidate();
      lua_pushstring(L, "exposed");
      return 1;

    case SDL_EVENT_WINDOW_MINIMIZED:
      lua_pushstring(L, "minimized");
      return 1;

    case SDL_EVENT_WINDOW_MAXIMIZED:
      lua_pushstring(L, "maximized");
      return 1;

    case SDL_EVENT_WINDOW_RESTORED:
      lua_pushstring(L, "restored");
      return 1;

    case SDL_EVENT_WINDOW_MOUSE_LEAVE:
      lua_pushstring(L, "mouseleft");
      return 1;

    case SDL_EVENT_WINDOW_FOCUS_LOST:
      lua_pushstring(L, "focuslost");
      return 1;

    case SDL_EVENT_WINDOW_FOCUS_GAINED:
      /* on some systems, when alt-tabbing to the window SDL will queue up
      ** several KEYDOWN events for the `tab` key; we flush all keydown
      ** events on focus so these are discarded */
      SDL_FlushEvent(SDL_EVENT_KEY_DOWN);
      lua_pushstring(L, "focusgained");
      return 1;


    case SDL_EVENT_DROP_FILE:
      {
        SDL_GetMouseState(&mx, &my);
        lua_pushstring(L, "filedropped");
        lua_pushstring(L, e.drop.data);
        lua_pushinteger(L, mx * window_renderer.scale_x);
        lua_pushinteger(L, my * window_renderer.scale_y);
        return 4;
      }

    case SDL_EVENT_KEY_DOWN:
#ifdef __APPLE__
      /* on macos 11.2.3 with sdl 2.0.14 the keyup handler for cmd+w below
      ** was not enough. Maybe the quit event started to be triggered from the
      ** keydown handler? In any case, flushing the quit event here too helped. */
      if ((e.key.key == SDLK_W) && (e.key.mod & SDL_KMOD_GUI)) {
        SDL_FlushEvent(SDL_EVENT_QUIT);
      }
#endif
      lua_pushstring(L, "keypressed");
      lua_pushstring(L, get_key_name(&e, buf));
      return 2;

    case SDL_EVENT_KEY_UP:
#ifdef __APPLE__
      /* on macos command+w will close the current window
      ** we want to flush this event and let the keymapper
      ** handle this key combination.
      ** Thanks to mathewmariani, taken from his lite-macos github repository. */
      if ((e.key.key == SDLK_W) && (e.key.mod & SDL_KMOD_GUI)) {
        SDL_FlushEvent(SDL_EVENT_QUIT);
      }
#endif
      lua_pushstring(L, "keyreleased");
      lua_pushstring(L, get_key_name(&e, buf));
      return 2;

    case SDL_EVENT_TEXT_INPUT:
      lua_pushstring(L, "textinput");
      lua_pushstring(L, e.text.text);
      return 2;

    case SDL_EVENT_TEXT_EDITING:
      lua_pushstring(L, "textediting");
      lua_pushstring(L, e.edit.text);
      lua_pushinteger(L, e.edit.start);
      lua_pushinteger(L, e.edit.length);
      return 4;

    case SDL_EVENT_MOUSE_BUTTON_DOWN:
      {
        if (e.button.button == 1) { SDL_CaptureMouse(1); }
        /* the second press of a double-click on the drag area, which SDL
        ** counts as the first (it didn't get the first) */
        int clicks = e.button.clicks;
        if (title_press.pass_next && e.button.button == 1 && title_double_click()) {
          clicks = title_press.clicks + 1;
          title_press.ticks = 0;
        }
        title_press.pass_next = false;
        lua_pushstring(L, "mousepressed");
        lua_pushstring(L, button_name(e.button.button));
        lua_pushinteger(L, e.button.x * window_renderer.scale_x);
        lua_pushinteger(L, e.button.y * window_renderer.scale_y);
        lua_pushinteger(L, clicks);
        return 5;
      }

    case SDL_EVENT_WINDOW_HIT_TEST:
      {
        /* a press the hit test took (a move or resize started); SDL doesn't
        ** pass the press on */
        /* X11 reports a press twice, from the master and the slave device,
        ** each starting a move */
        static Uint64 last_timestamp;
        const bool duplicate = e.window.timestamp - last_timestamp < SDL_MS_TO_NS(20);
        last_timestamp = e.window.timestamp;
        if (duplicate || last_hit_area != SDL_HITTEST_DRAGGABLE) goto top;
        int wx, wy;
        SDL_GetWindowPosition(window_renderer.window, &wx, &wy);
        const float gx = wx + last_hit_point.x, gy = wy + last_hit_point.y;
        title_press.clicks = title_double_click_at(gx, gy) ? title_press.clicks + 1 : 1;
        title_press.ticks = SDL_GetTicks();
        title_press.x = gx;
        title_press.y = gy;
        lua_pushstring(L, "hittest");
        lua_pushinteger(L, last_hit_point.x * window_renderer.scale_x);
        lua_pushinteger(L, last_hit_point.y * window_renderer.scale_y);
        lua_pushinteger(L, title_press.clicks);
        return 4;
      }

    case SDL_EVENT_MOUSE_BUTTON_UP:
      {
        if (e.button.button == 1) { SDL_CaptureMouse(0); }
        lua_pushstring(L, "mousereleased");
        lua_pushstring(L, button_name(e.button.button));
        lua_pushinteger(L, e.button.x * window_renderer.scale_x);
        lua_pushinteger(L, e.button.y * window_renderer.scale_y);
        return 4;
      }

    case SDL_EVENT_MOUSE_MOTION:
      {
        SDL_PumpEvents();
        while (SDL_PeepEvents(&event_plus, 1, SDL_GETEVENT, SDL_EVENT_MOUSE_MOTION, SDL_EVENT_MOUSE_MOTION) > 0) {
          e.motion.x = event_plus.motion.x;
          e.motion.y = event_plus.motion.y;
          e.motion.xrel += event_plus.motion.xrel;
          e.motion.yrel += event_plus.motion.yrel;
        }
        lua_pushstring(L, "mousemoved");
        lua_pushinteger(L, e.motion.x * window_renderer.scale_x);
        lua_pushinteger(L, e.motion.y * window_renderer.scale_y);
        lua_pushinteger(L, e.motion.xrel * window_renderer.scale_x);
        lua_pushinteger(L, e.motion.yrel * window_renderer.scale_y);
        return 5;
      }

    case SDL_EVENT_MOUSE_WHEEL:
      lua_pushstring(L, "mousewheel");
      lua_pushnumber(L, e.wheel.y);
      // Use -x to keep consistency with vertical scrolling values (e.g. shift+scroll)
      lua_pushnumber(L, -e.wheel.x);
      return 3;

    case SDL_EVENT_FINGER_DOWN:
      {
        SDL_GetWindowSize(window_renderer.window, &w, &h);

        lua_pushstring(L, "touchpressed");
        lua_pushnumber(L, e.tfinger.x * w * window_renderer.scale_x);
        lua_pushnumber(L, e.tfinger.y * h * window_renderer.scale_y);
        lua_pushinteger(L, e.tfinger.fingerID);
        return 4;
      }

    case SDL_EVENT_FINGER_UP:
      {
        SDL_GetWindowSize(window_renderer.window, &w, &h);

        lua_pushstring(L, "touchreleased");
        lua_pushnumber(L, e.tfinger.x * w * window_renderer.scale_x);
        lua_pushnumber(L, e.tfinger.y * h * window_renderer.scale_y);
        lua_pushinteger(L, e.tfinger.fingerID);
        return 4;
      }

    case SDL_EVENT_FINGER_MOTION:
      {
        SDL_PumpEvents();
        while (SDL_PeepEvents(&event_plus, 1, SDL_GETEVENT, SDL_EVENT_FINGER_MOTION, SDL_EVENT_FINGER_MOTION) > 0) {
          e.tfinger.x = event_plus.tfinger.x;
          e.tfinger.y = event_plus.tfinger.y;
          e.tfinger.dx += event_plus.tfinger.dx;
          e.tfinger.dy += event_plus.tfinger.dy;
        }
        SDL_GetWindowSize(window_renderer.window, &w, &h);

        lua_pushstring(L, "touchmoved");
        lua_pushnumber(L, e.tfinger.x * w * window_renderer.scale_x);
        lua_pushnumber(L, e.tfinger.y * h * window_renderer.scale_y);
        lua_pushnumber(L, e.tfinger.dx * w * window_renderer.scale_x);
        lua_pushnumber(L, e.tfinger.dy * h * window_renderer.scale_y);
        lua_pushinteger(L, e.tfinger.fingerID);
        return 6;
      }

    case SDL_EVENT_WILL_ENTER_FOREGROUND:
    case SDL_EVENT_DID_ENTER_FOREGROUND:
      {
        #ifdef LITE_USE_SDL_RENDERER
          rencache_invalidate();
        #else
          SDL_UpdateWindowSurface(window_renderer.window);
        #endif
        lua_pushstring(L, e.type == SDL_EVENT_WILL_ENTER_FOREGROUND ? "enteringforeground" : "enteredforeground");
        return 1;
      }

    case SDL_EVENT_WILL_ENTER_BACKGROUND:
      lua_pushstring(L, "enteringbackground");
      return 1;

    case SDL_EVENT_DID_ENTER_BACKGROUND:
      lua_pushstring(L, "enteredbackground");
      return 1;

    case SDL_EVENT_WINDOW_DISPLAY_SCALE_CHANGED:
    case SDL_EVENT_WINDOW_PIXEL_SIZE_CHANGED:
      {
        ren_resize_window(&window_renderer);
      }

    default:
      goto top;
  }

  return 0;
}


static int f_wait_event(lua_State *L) {
  int nargs = lua_gettop(L);
  if (nargs >= 1) {
    double n = luaL_checknumber(L, 1);
    if (n < 0) n = 0;
    // round up: SDL takes whole milliseconds, and truncating made waits under
    // 1 ms return at once, so the main loop spun until the next thread was due
    double ms = SDL_ceil(n * 1000);
    lua_pushboolean(L, SDL_WaitEventTimeout(NULL, ms < SDL_MAX_SINT32 ? (Sint32) ms : SDL_MAX_SINT32));
  } else {
    lua_pushboolean(L, SDL_WaitEvent(NULL));
  }
  return 1;
}


static SDL_Cursor* cursor_cache[SDL_SYSTEM_CURSOR_POINTER + 1];

static const char *cursor_opts[] = {
  "arrow",
  "ibeam",
  "sizeh",
  "sizev",
  "hand",
  NULL
};

static const int cursor_enums[] = {
  SDL_SYSTEM_CURSOR_DEFAULT,
  SDL_SYSTEM_CURSOR_TEXT,
  SDL_SYSTEM_CURSOR_EW_RESIZE,
  SDL_SYSTEM_CURSOR_NS_RESIZE,
  SDL_SYSTEM_CURSOR_POINTER
};

static int f_set_cursor(lua_State *L) {
  int opt = luaL_checkoption(L, 1, "arrow", cursor_opts);
  int n = cursor_enums[opt];
  SDL_Cursor *cursor = cursor_cache[n];
  if (!cursor) {
    cursor = SDL_CreateSystemCursor(n);
    cursor_cache[n] = cursor;
  }
  SDL_SetCursor(cursor);
  return 0;
}


static int f_set_window_title(lua_State *L) {
  const char *title = luaL_checkstring(L, 1);
  SDL_SetWindowTitle(window_renderer.window, title);
  return 0;
}


static const char *window_opts[] = { "normal", "minimized", "maximized", "fullscreen", 0 };
enum { WIN_NORMAL, WIN_MINIMIZED, WIN_MAXIMIZED, WIN_FULLSCREEN };

static int f_set_window_mode(lua_State *L) {
  int n = luaL_checkoption(L, 1, "normal", window_opts);
  SDL_SetWindowFullscreen(window_renderer.window, n == WIN_FULLSCREEN);
  if (n == WIN_NORMAL) { SDL_RestoreWindow(window_renderer.window); }
  if (n == WIN_MAXIMIZED) { SDL_MaximizeWindow(window_renderer.window); }
  if (n == WIN_MINIMIZED) { SDL_MinimizeWindow(window_renderer.window); }
  return 0;
}


static int f_set_window_bordered(lua_State *L) {
  /* finish pending changes first (X11 applies them asynchronously): the size
  ** restored from the session would be lost otherwise */
  SDL_SyncWindow(window_renderer.window);
  SDL_SetWindowBordered(window_renderer.window, lua_toboolean(L, 1));
  return 0;
}


static int f_set_window_hit_test(lua_State *L) {
  if (lua_isnoneornil(L, 1)) {
    SDL_SetWindowHitTest(window_renderer.window, NULL, NULL);
    return 0;
  }
  window_hit_info->title_height = luaL_checknumber(L, 1);
  window_hit_info->controls_width = luaL_checknumber(L, 2);
  window_hit_info->resize_border = luaL_checknumber(L, 3);
  window_hit_info->rect_count = 0;
  if (!lua_isnoneornil(L, 4)) {
    luaL_checktype(L, 4, LUA_TTABLE);
    int n = luaL_len(L, 4);
    for (int i = 1; i <= n && i <= MAX_HIT_TEST_RECTS; i++) {
      lua_rawgeti(L, 4, i);
      luaL_checktype(L, -1, LUA_TTABLE);
      int v[4];
      for (int j = 0; j < 4; j++) {
        lua_rawgeti(L, -1, j + 1);
        v[j] = luaL_checknumber(L, -1);
        lua_pop(L, 1);
      }
      lua_pop(L, 1);
      window_hit_info->rects[i - 1] = (SDL_Rect) { v[0], v[1], v[2], v[3] };
      window_hit_info->rect_count = i;
    }
  }
  SDL_SetWindowHitTest(window_renderer.window, &hit_test, window_hit_info);
  return 0;
}


static int f_get_window_size(lua_State *L) {
  int x, y, w, h;
  SDL_GetWindowSize(window_renderer.window, &w, &h);
  SDL_GetWindowPosition(window_renderer.window, &x, &y);
  lua_pushinteger(L, w);
  lua_pushinteger(L, h);
  lua_pushinteger(L, x);
  lua_pushinteger(L, y);
  return 4;
}


static int f_set_window_size(lua_State *L) {
  double w = luaL_checknumber(L, 1);
  double h = luaL_checknumber(L, 2);
  double x = luaL_checknumber(L, 3);
  double y = luaL_checknumber(L, 4);
  SDL_SetWindowSize(window_renderer.window, w, h);
  SDL_SetWindowPosition(window_renderer.window, x, y);
  ren_resize_window(&window_renderer);
  return 0;
}


static int f_window_has_focus(lua_State *L) {
  unsigned flags = SDL_GetWindowFlags(window_renderer.window);
  lua_pushboolean(L, flags & SDL_WINDOW_INPUT_FOCUS);
  return 1;
}


static int f_get_window_mode(lua_State *L) {
  unsigned flags = SDL_GetWindowFlags(window_renderer.window);
  if (flags & SDL_WINDOW_FULLSCREEN) {
    lua_pushstring(L, "fullscreen");
  } else if (flags & SDL_WINDOW_MINIMIZED) {
    lua_pushstring(L, "minimized");
  } else if (flags & SDL_WINDOW_MAXIMIZED) {
    lua_pushstring(L, "maximized");
  } else {
    lua_pushstring(L, "normal");
  }
  return 1;
}

static int f_set_text_input_rect(lua_State *L) {
  SDL_Rect rect;
  rect.x = luaL_checknumber(L, 1);
  rect.y = luaL_checknumber(L, 2);
  rect.w = luaL_checknumber(L, 3);
  rect.h = luaL_checknumber(L, 4);
  SDL_SetTextInputArea(window_renderer.window, &rect, 0);
  return 0;
}

static int f_clear_ime(lua_State *L) {
  SDL_ClearComposition(window_renderer.window);
  return 0;
}


static int f_raise_window(lua_State *L) {
  SDL_RaiseWindow(window_renderer.window);
  return 0;
}


static int f_show_fatal_error(lua_State *L) {
  const char *title = luaL_checkstring(L, 1);
  const char *msg = luaL_checkstring(L, 2);

  // LITE_XL_NO_DIALOG: for headless testing and scripts, which can't dismiss a dialog
  const char *no_dialog = getenv("LITE_XL_NO_DIALOG");
  if (no_dialog && *no_dialog && strcmp(no_dialog, "0") != 0) {
    fprintf(stderr, "%s: %s\n", title, msg);
    return 0;
  }

#ifdef _WIN32
  MessageBox(0, msg, title, MB_OK | MB_ICONERROR);
#else
  SDL_ShowSimpleMessageBox(SDL_MESSAGEBOX_ERROR, title, msg, NULL);
#endif
  return 0;
}


// removes an empty directory
static int f_rmdir(lua_State *L) {
  lua_pushboolean(L, SDL_RemovePath(luaL_checkstring(L, 1)));
  if (!lua_toboolean(L, -1)) {
    lua_pushstring(L, SDL_GetError());
    return 2;
  }
  return 1;
}


static int f_chdir(lua_State *L) {
  const char *path = luaL_checkstring(L, 1);
#ifdef _WIN32
  LPWSTR wpath = utfconv_utf8towc(path);
  if (wpath == NULL) { return luaL_error(L, UTFCONV_ERROR_INVALID_CONVERSION ); }
  int err = _wchdir(wpath);
  SDL_free(wpath);
#else
  int err = chdir(path);
#endif
  if (err) { luaL_error(L, "chdir() failed: %s", strerror(errno)); }
  return 0;
}

static SDL_EnumerationResult list_dir_enumeration_callback(void *userdata, const char *dirname, const char *fname) {
  (void) dirname;
  lua_State *L = userdata;
  int len = lua_rawlen(L, -1);
  lua_pushstring(L, fname);
  lua_rawseti(L, -2, len + 1);
  return SDL_ENUM_CONTINUE;
}

static int f_list_dir(lua_State *L) {
  const char *path = luaL_checkstring(L, 1);
  lua_newtable(L);
  bool res = SDL_EnumerateDirectory(path, list_dir_enumeration_callback, L);
  if (!res) {
    lua_pushnil(L);
    lua_pushstring(L, SDL_GetError());
    return 2;
  }
  return 1;
}


#ifdef _WIN32
  #define realpath(x, y) _wfullpath(y, x, MAX_PATH)
#endif

static int f_absolute_path(lua_State *L) {
  const char *path = luaL_checkstring(L, 1);
#ifdef _WIN32
  LPWSTR wpath = utfconv_utf8towc(path);
  if (!wpath) { return 0; }

  LPWSTR wfullpath = realpath(wpath, NULL);
  SDL_free(wpath);
  if (!wfullpath) { return 0; }

  char *res = utfconv_wctoutf8(wfullpath);
  SDL_free(wfullpath);
#else
  char *res = realpath(path, NULL);
#endif
  if (!res) { return 0; }
  lua_pushstring(L, res);
  SDL_free(res);
  return 1;
}


static int f_get_file_info(lua_State *L) {
  const char *path = luaL_checkstring(L, 1);

#ifdef _WIN32
  struct _stat s;
  LPWSTR wpath = utfconv_utf8towc(path);
  if (wpath == NULL) {
    lua_pushnil(L);
    lua_pushstring(L, UTFCONV_ERROR_INVALID_CONVERSION);
    return 2;
  }
  int err = _wstat(wpath, &s);
  SDL_free(wpath);
#else
  struct stat s;
  int err = stat(path, &s);
#endif
  if (err < 0) {
    lua_pushnil(L);
    lua_pushstring(L, strerror(errno));
    return 2;
  }

  lua_newtable(L);
  lua_pushinteger(L, s.st_mtime);
  lua_setfield(L, -2, "modified");

  lua_pushinteger(L, s.st_size);
  lua_setfield(L, -2, "size");

  if (S_ISREG(s.st_mode)) {
    lua_pushstring(L, "file");
  } else if (S_ISDIR(s.st_mode)) {
    lua_pushstring(L, "dir");
  } else {
    lua_pushnil(L);
  }
  lua_setfield(L, -2, "type");

#if __linux__
  if (S_ISDIR(s.st_mode)) {
    if (lstat(path, &s) == 0) {
      lua_pushboolean(L, S_ISLNK(s.st_mode));
      lua_setfield(L, -2, "symlink");
    }
  }
#endif
  return 1;
}

#if __linux__
// https://man7.org/linux/man-pages/man2/statfs.2.html

struct f_type_names {
  uint32_t magic;
  const char *name;
};

static struct f_type_names fs_names[] = {
  { 0xef53,     "ext2/ext3" },
  { 0x6969,     "nfs"       },
  { 0x65735546, "fuse"      },
  { 0x517b,     "smb"       },
  { 0xfe534d42, "smb2"      },
  { 0x52654973, "reiserfs"  },
  { 0x01021994, "tmpfs"     },
  { 0x858458f6, "ramfs"     },
  { 0x5346544e, "ntfs"      },
  { 0x0,        NULL        },
};

#endif

static int f_get_fs_type(lua_State *L) {
  #if __linux__
    const char *path = luaL_checkstring(L, 1);
    struct statfs buf;
    int status = statfs(path, &buf);
    if (status != 0) {
      return luaL_error(L, "error calling statfs on %s", path);
    }
    for (int i = 0; fs_names[i].magic; i++) {
      if (fs_names[i].magic == buf.f_type) {
        lua_pushstring(L, fs_names[i].name);
        return 1;
      }
    }
  #endif
  lua_pushstring(L, "unknown");
  return 1;
}


static int f_mkdir(lua_State *L) {
  const char *path = luaL_checkstring(L, 1);

#ifdef _WIN32
  LPWSTR wpath = utfconv_utf8towc(path);
  if (wpath == NULL) {
    lua_pushboolean(L, 0);
    lua_pushstring(L, UTFCONV_ERROR_INVALID_CONVERSION);
    return 2;
  }

  int err = _wmkdir(wpath);
  SDL_free(wpath);
#else
  int err = mkdir(path, S_IRUSR|S_IWUSR|S_IXUSR|S_IRGRP|S_IXGRP|S_IROTH|S_IXOTH);
#endif
  if (err < 0) {
    lua_pushboolean(L, 0);
    lua_pushstring(L, strerror(errno));
    return 2;
  }

  lua_pushboolean(L, 1);
  return 1;
}


static int f_get_clipboard(lua_State *L) {
  char *text = SDL_GetClipboardText();
  if (!text) { return 0; }
#ifdef _WIN32
  // on windows, text-based clipboard formats must terminate with \r\n
  // we need to convert it to \n for Lite XL to read them properly
  // https://learn.microsoft.com/en-us/windows/win32/dataxchg/standard-clipboard-formats
  luaL_gsub(L, text, "\r\n", "\n");
#else
  lua_pushstring(L, text);
#endif
  SDL_free(text);
  return 1;
}


#if defined(__linux__) && __has_include(<X11/Xlib.h>)
#include <X11/Xlib.h>
#include <X11/Xatom.h>
#include <dlfcn.h>

/* SDL doesn't answer requests for the TIMESTAMP target of the clipboard, and
** VMware's guest tools copy the clipboard to the host only when it answers
** (otherwise they read PRIMARY, which we don't own). We answer for SDL, with the
** time of the last input event before the copy, as ICCCM asks. We use the libX11
** SDL loaded rather than linking it. */
static struct {
  Atom (*InternAtom)(Display*, const char*, Bool);
  int (*ChangeProperty)(Display*, Window, Atom, Atom, int, int, const unsigned char*, int);
  Status (*SendEvent)(Display*, Window, Bool, long, XEvent*);
  Atom clipboard, timestamp;
  Time last_event, owned_since;
} x11clip;

static bool x11_event_hook(void *userdata, XEvent *e) {
  if (!x11clip.clipboard) {
    x11clip.clipboard = x11clip.InternAtom(e->xany.display, "CLIPBOARD", False);
    x11clip.timestamp = x11clip.InternAtom(e->xany.display, "TIMESTAMP", False);
  }
  switch (e->type) {
    case KeyPress: case KeyRelease: x11clip.last_event = e->xkey.time; break;
    case ButtonPress: case ButtonRelease: x11clip.last_event = e->xbutton.time; break;
    case SelectionRequest: {
      XSelectionRequestEvent *req = &e->xselectionrequest;
      if (req->selection != x11clip.clipboard || req->target != x11clip.timestamp)
        break;
      XEvent reply = { .xselection = { .type = SelectionNotify, .display = req->display,
        .requestor = req->requestor, .selection = req->selection, .target = req->target,
        .property = req->property ? req->property : req->target, .time = req->time } };
      long t = x11clip.owned_since;  /* format 32 is a long in Xlib */
      x11clip.ChangeProperty(req->display, req->requestor, reply.xselection.property,
        XA_INTEGER, 32, PropModeReplace, (unsigned char*) &t, 1);
      x11clip.SendEvent(req->display, req->requestor, False, 0, &reply);
      return false;
    }
  }
  return true;
}

static void x11_clipboard_init(void) {
  if (x11clip.InternAtom) { return; }
  const char *driver = SDL_GetCurrentVideoDriver();
  void *lib = dlopen("libX11.so.6", RTLD_NOW | RTLD_NOLOAD);
  if (!driver || strcmp(driver, "x11") || !lib) { return; }
  x11clip.InternAtom = dlsym(lib, "XInternAtom");
  x11clip.ChangeProperty = dlsym(lib, "XChangeProperty");
  x11clip.SendEvent = dlsym(lib, "XSendEvent");
  if (!x11clip.InternAtom || !x11clip.ChangeProperty || !x11clip.SendEvent) { return; }
  SDL_SetX11EventHook(x11_event_hook, NULL);
}
#endif

static int f_set_clipboard(lua_State *L) {
  const char *text = luaL_checkstring(L, 1);
#if defined(__linux__) && __has_include(<X11/Xlib.h>)
  x11clip.owned_since = x11clip.last_event;
#endif
  SDL_SetClipboardText(text);
  return 0;
}


static int f_get_process_id(lua_State *L) {
#ifdef _WIN32
  lua_pushinteger(L, GetCurrentProcessId());
#else
  lua_pushinteger(L, getpid());
#endif
  return 1;
}


static int f_get_time(lua_State *L) {
  double n = SDL_GetPerformanceCounter() / (double) SDL_GetPerformanceFrequency();
  lua_pushnumber(L, n);
  return 1;
}


static int f_sleep(lua_State *L) {
  double n = luaL_checknumber(L, 1);
  if (n < 0) n = 0;
  SDL_Delay(n * 1000);
  return 0;
}


static int f_exec(lua_State *L) {
  size_t len;
  const char *cmd = luaL_checklstring(L, 1, &len);
  char *buf = SDL_malloc(len + 32);
  if (!buf) { luaL_error(L, "buffer allocation failed"); }
#if _WIN32
  sprintf(buf, "cmd /c \"%s\"", cmd);
  WinExec(buf, SW_HIDE);
#else
  sprintf(buf, "%s &", cmd);
  int res = system(buf);
  (void) res;
#endif
  SDL_free(buf);
  return 0;
}

static int f_open_url(lua_State *L) {
  const char *url = luaL_checkstring(L, 1);
  if (!SDL_OpenURL(url)) {
    lua_pushboolean(L, 0);
    lua_pushstring(L, SDL_GetError());
    return 2;
  }
  lua_pushboolean(L, 1);
  return 1;
}

static int f_fuzzy_match(lua_State *L) {
  size_t strLen, ptnLen;
  const char *str = luaL_checklstring(L, 1, &strLen);
  const char *ptn = luaL_checklstring(L, 2, &ptnLen);
  // If true match things *backwards*. This allows for better matching on filenames than the above
  // function. For example, in the lite project, opening "renderer" has lib/font_render/build.sh
  // as the first result, rather than src/renderer.c. Clearly that's wrong.
  bool files = lua_gettop(L) > 2 && lua_isboolean(L,3) && lua_toboolean(L, 3);
  int score = 0, run = 0, increment = files ? -1 : 1;
  const char* strTarget = files ? str + strLen - 1 : str;
  const char* ptnTarget = files ? ptn + ptnLen - 1 : ptn;
  while (strTarget >= str && ptnTarget >= ptn && *strTarget && *ptnTarget) {
    while (strTarget >= str && *strTarget == ' ') { strTarget += increment; }
    while (ptnTarget >= ptn && *ptnTarget == ' ') { ptnTarget += increment; }
    if (tolower(*strTarget) == tolower(*ptnTarget)) {
      score += run * 10 - (*strTarget != *ptnTarget);
      run++;
      ptnTarget += increment;
    } else {
      score -= 10;
      run = 0;
    }
    strTarget += increment;
  }
  if (ptnTarget >= ptn && *ptnTarget) { return 0; }
  lua_pushinteger(L, score - (int)strLen * 10);
  return 1;
}

static int f_set_window_opacity(lua_State *L) {
  double n = luaL_checknumber(L, 1);
  int r = SDL_SetWindowOpacity(window_renderer.window, n);
  lua_pushboolean(L, r > -1);
  return 1;
}

typedef void (*fptr)(void);

typedef struct lua_function_node {
  const char *symbol;
  fptr address;
} lua_function_node;

#define P(FUNC) { "lua_" #FUNC, (fptr)(lua_##FUNC) }
#define U(FUNC) { "luaL_" #FUNC, (fptr)(luaL_##FUNC) }
#define S(FUNC) { #FUNC, (fptr)(FUNC) }
static void* api_require(const char* symbol) {
  static const lua_function_node nodes[] = {
    #if LUA_VERSION_NUM == 501 || LUA_VERSION_NUM == 502 || LUA_VERSION_NUM == 503 || LUA_VERSION_NUM == 504
    U(addlstring), U(addstring), U(addvalue), U(argerror), U(buffinit),
    U(callmeta), U(checkany), U(checkinteger), U(checklstring),
    U(checknumber), U(checkoption), U(checkstack), U(checktype),
    U(checkudata), U(error), U(getmetafield), U(gsub), U(loadstring),
    U(newmetatable), U(newstate), U(openlibs), U(optinteger), U(optlstring),
    U(optnumber), U(pushresult), U(ref), U(unref), U(where), P(atpanic),
    P(checkstack), P(close), P(concat), P(createtable), P(dump), P(error),
    P(gc), P(getallocf), P(getfield), P(gethook), P(gethookcount),
    P(gethookmask), P(getinfo), P(getlocal), P(getmetatable), P(getstack),
    P(gettable), P(gettop), P(getupvalue), P(iscfunction), P(isnumber),
    P(isstring), P(isuserdata), P(load), P(newstate), P(newthread), P(next),
    P(pushboolean), P(pushcclosure), P(pushfstring), P(pushinteger),
    P(pushlightuserdata), P(pushlstring), P(pushnil), P(pushnumber),
    P(pushstring), P(pushthread), P(pushvalue), P(pushvfstring), P(rawequal),
    P(rawget), P(rawgeti), P(rawset), P(rawseti), P(resume), P(setallocf),
    P(setfield), P(sethook), P(setlocal), P(setmetatable), P(settable),
    P(settop), P(setupvalue), P(status), P(toboolean), P(tocfunction),
    P(tolstring), P(topointer), P(tothread), P(touserdata), P(type),
    P(typename), P(xmove), S(luaopen_base), S(luaopen_debug), S(luaopen_io),
    S(luaopen_math), S(luaopen_os), S(luaopen_package), S(luaopen_string),
    S(luaopen_table), S(api_load_libs),
    #endif
    #if LUA_VERSION_NUM == 502 || LUA_VERSION_NUM == 503 || LUA_VERSION_NUM == 504
    U(buffinitsize), U(checkversion_), U(execresult), U(fileresult),
    U(getsubtable), U(len), U(loadbufferx), U(loadfilex), U(prepbuffsize),
    U(pushresultsize), U(requiref), U(setfuncs), U(setmetatable),
    U(testudata), U(tolstring), U(traceback), P(absindex), P(arith),
    P(callk), P(compare), P(copy), P(getglobal), P(len), P(pcallk),
    P(rawgetp), P(rawlen), P(rawsetp), P(setglobal), P(tointegerx),
    P(tonumberx), P(upvalueid), P(upvaluejoin), P(version), P(yieldk),
    S(luaopen_coroutine),
    #endif
    #if LUA_VERSION_NUM == 501 || LUA_VERSION_NUM == 502 || LUA_VERSION_NUM == 503
    P(newuserdata),
    #endif
    #if LUA_VERSION_NUM == 503 || LUA_VERSION_NUM == 504
    P(geti), P(isinteger), P(isyieldable), P(rotate), P(seti),
    P(stringtonumber), S(luaopen_utf8),
    #endif
    #if LUA_VERSION_NUM == 502 || LUA_VERSION_NUM == 503
    P(getuservalue), P(setuservalue), S(luaopen_bit32),
    #endif
    #if LUA_VERSION_NUM == 501 || LUA_VERSION_NUM == 502
    P(insert), P(remove), P(replace),
    #endif
    #if LUA_VERSION_NUM == 504
    U(addgsub), U(typeerror), P(closeslot), P(getiuservalue),
    P(newuserdatauv), P(resetthread), P(setcstacklimit), P(setiuservalue),
    P(setwarnf), P(toclose), P(warning),
    #endif
    #if LUA_VERSION_NUM == 502
    U(checkunsigned), U(optunsigned), P(getctx), P(pushunsigned),
    P(tounsignedx),
    #endif
    #if LUA_VERSION_NUM == 501
    U(findtable), U(loadbuffer), U(loadfile), U(openlib), U(prepbuffer),
    U(register), U(typerror), P(call), P(cpcall), P(equal), P(getfenv),
    P(lessthan), P(objlen), P(pcall), P(setfenv), P(setlevel), P(tointeger),
    P(tonumber), P(yield),
    #endif
  };
  for (size_t i = 0; i < sizeof(nodes) / sizeof(lua_function_node); ++i) {
    if (strcmp(nodes[i].symbol, symbol) == 0)
      return *(void**)(&nodes[i].address);
  }
  return NULL;
}

static int f_library_gc(lua_State *L) {
  lua_getfield(L, 1, "handle");
  void* handle = lua_touserdata(L, -1);
  SDL_UnloadObject(handle);
  
  return 0;
}

static int f_load_native_plugin(lua_State *L) {
  char entrypoint_name[512]; entrypoint_name[sizeof(entrypoint_name) - 1] = '\0';
  int result;

  const char *name = luaL_checkstring(L, 1);
  const char *path = luaL_checkstring(L, 2);
  void *library = SDL_LoadObject(path);
  if (!library)
    return (lua_pushstring(L, SDL_GetError()), lua_error(L));

  lua_getglobal(L, "package");
  lua_getfield(L, -1, "native_plugins");
  lua_newtable(L);
  lua_pushlightuserdata(L, library);
  lua_setfield(L, -2, "handle");
  luaL_setmetatable(L, API_TYPE_NATIVE_PLUGIN);
  lua_setfield(L, -2, name);
  lua_pop(L, 2);

  const char *basename = strrchr(name, '.');
  basename = !basename ? name : basename + 1;
  snprintf(entrypoint_name, sizeof(entrypoint_name), "luaopen_lite_xl_%s", basename);
  int (*ext_entrypoint) (lua_State *L, void* (*)(const char*));
  *(void**)(&ext_entrypoint) = SDL_LoadFunction(library, entrypoint_name);
  if (!ext_entrypoint) {
    snprintf(entrypoint_name, sizeof(entrypoint_name), "luaopen_%s", basename);
    int (*entrypoint)(lua_State *L);
    *(void**)(&entrypoint) = SDL_LoadFunction(library, entrypoint_name);
    if (!entrypoint)
      return luaL_error(L, "Unable to load %s: Can't find %s(lua_State *L, void *XL)", name, entrypoint_name);
    result = entrypoint(L);
  } else {
    result = ext_entrypoint(L, api_require);
  }

  if (!result)
    return luaL_error(L, "Unable to load %s: entrypoint must return a value", name);

  return result;
}

#ifdef _WIN32
#define PATHSEP '\\'
#else
#define PATHSEP '/'
#endif

/* Special purpose filepath compare function. Corresponds to the
   order used in the TreeView view of the project's files. Returns true if
   path1 < path2 in the TreeView order. */
static int f_path_compare(lua_State *L) {
  size_t len1, len2;
  const char *path1 = luaL_checklstring(L, 1, &len1);
  const char *type1_s = luaL_checkstring(L, 2);
  const char *path2 = luaL_checklstring(L, 3, &len2);
  const char *type2_s = luaL_checkstring(L, 4);
  int type1 = strcmp(type1_s, "dir") != 0;
  int type2 = strcmp(type2_s, "dir") != 0;
  /* Find the index of the common part of the path. */
  size_t offset = 0, i, j;
  for (i = 0; i < len1 && i < len2; i++) {
    if (path1[i] != path2[i]) break;
    if (path1[i] == PATHSEP) {
      offset = i + 1;
    }
  }
  /* If a path separator is present in the name after the common part we consider
     the entry like a directory. */
  if (strchr(path1 + offset, PATHSEP)) {
    type1 = 0;
  }
  if (strchr(path2 + offset, PATHSEP)) {
    type2 = 0;
  }
  /* If types are different "dir" types comes before "file" types. */
  if (type1 != type2) {
    lua_pushboolean(L, type1 < type2);
    return 1;
  }
  /* If types are the same compare the files' path alphabetically. */
  int cfr = -1;
  bool same_len = len1 == len2;
  for (i = offset, j = offset; i <= len1 && j <= len2; i++, j++) {
    if (path1[i] == 0 || path2[j] == 0) {
      if (cfr < 0) cfr = 0; // The strings are equal
      if (!same_len) {
        cfr = (path1[i] == 0);
      }
    } else if (isdigit(path1[i]) && isdigit(path2[j])) {
      size_t ii = 0, ij = 0;
      while (isdigit(path1[i+ii])) { ii++; }
      while (isdigit(path2[j+ij])) { ij++; }

      size_t di = 0, dj = 0;
      for (size_t ai = 0; ai < ii; ++ai) {
        di = di * 10 + (path1[i+ai] - '0');
      }
      for (size_t aj = 0; aj < ij; ++aj) {
        dj = dj * 10 + (path2[j+aj] - '0');
      }

      if (di == dj) {
        continue;
      }
      cfr = (di < dj);
    } else if (path1[i] == path2[j]) {
      continue;
    } else if (path1[i] == PATHSEP || path2[j] == PATHSEP) {
      /* For comparison we treat PATHSEP as if it was the string terminator. */
      cfr = (path1[i] == PATHSEP);
    } else {
      char a = path1[i], b = path2[j];
      if (a >= 'A' && a <= 'Z') a += 32;
      if (b >= 'A' && b <= 'Z') b += 32;
      if (a == b) {
        /* If the strings have the same length, we need
           to keep the first case sensitive difference. */
        if (same_len && cfr < 0) {
          /* Give priority to lower-case characters */
          cfr = (path1[i] > path2[j]);
        }
        continue;
      }
      cfr = (a < b);
    }
    break;
  }
  lua_pushboolean(L, cfr);
  return 1;
}


// File dialogs, from upstream lite-xl f580d020 (without its window argument and
// custom event registry): they return at once, and the result comes as a
// "dialogfinished" event with the id given; see core.open_file_dialog.

typedef struct {
  intptr_t id;
  SDL_DialogFileFilter *filters;
  int n_filters;
} DialogData;

static void free_dialog_data(DialogData *dd) {
  for (int i = 0; i < dd->n_filters; i++) {
    SDL_free((char *) dd->filters[i].name);
    SDL_free((char *) dd->filters[i].pattern);
  }
  SDL_free(dd->filters);
  SDL_free(dd);
}

static void dialog_callback(void *userdata, const char * const *filelist, int filter) {
  DialogData *dd = userdata;
  SDL_Event event;
  SDL_zero(event);
  event.type = DIALOG_EVENT_TYPE;
  event.user.data1 = (void *) dd->id;
  // the filters had to last until now
  free_dialog_data(dd);
  if (filelist == NULL) {
    event.user.code = DIALOG_ERROR;
    event.user.data2 = SDL_strdup(SDL_GetError());
  } else {
    // empty paths are left out (zenity's cancel can give one); none is a cancel
    size_t bytes = 1;
    for (int i = 0; filelist[i]; i++) if (*filelist[i]) bytes += strlen(filelist[i]) + 1;
    char *data = event.user.data2 = bytes > 1 ? SDL_malloc(bytes) : NULL;
    if (bytes == 1) {
      event.user.code = DIALOG_CANCEL;
    } else if (!data) {
      event.user.code = DIALOG_ERROR;
    } else {
      event.user.code = DIALOG_OK;
      for (int i = 0; filelist[i]; i++) {
        if (!*filelist[i]) continue;
        size_t len = strlen(filelist[i]) + 1;
        memcpy(data, filelist[i], len);
        data += len;
      }
      *data = '\0';
    }
  }
  if (!SDL_PushEvent(&event)) SDL_free(event.user.data2);
}

static int open_dialog(lua_State *L, SDL_FileDialogType type) {
  intptr_t id = luaL_checkinteger(L, 1);
  bool has_options = !lua_isnoneornil(L, 2);
  if (has_options) luaL_checktype(L, 2, LUA_TTABLE);
  DialogData *dd = SDL_calloc(1, sizeof(DialogData));
  if (!dd) return luaL_error(L, "out of memory");
  dd->id = id;
  SDL_PropertiesID props = SDL_CreateProperties();
  if (!props) {
    SDL_free(dd);
    return luaL_error(L, "cannot create SDL properties: %s", SDL_GetError());
  }
  SDL_SetPointerProperty(props, SDL_PROP_FILE_DIALOG_WINDOW_POINTER, window_renderer.window);
  if (has_options) {
    // SDL copies the strings; the filters must last until the callback
    static const struct { const char *field, *prop; } strings[] = {
      { "default_location", SDL_PROP_FILE_DIALOG_LOCATION_STRING },
      { "title",            SDL_PROP_FILE_DIALOG_TITLE_STRING },
      { "accept_label",     SDL_PROP_FILE_DIALOG_ACCEPT_STRING },
      { "cancel_label",     SDL_PROP_FILE_DIALOG_CANCEL_STRING },
    };
    for (size_t i = 0; i < sizeof(strings) / sizeof(*strings); i++) {
      lua_getfield(L, 2, strings[i].field);
      if (lua_isstring(L, -1)) SDL_SetStringProperty(props, strings[i].prop, lua_tostring(L, -1));
      lua_pop(L, 1);
    }
    if (type != SDL_FILEDIALOG_SAVEFILE) {
      lua_getfield(L, 2, "allow_many");
      SDL_SetBooleanProperty(props, SDL_PROP_FILE_DIALOG_MANY_BOOLEAN, lua_toboolean(L, -1));
      lua_pop(L, 1);
    }
    if (type != SDL_FILEDIALOG_OPENFOLDER) {
      lua_getfield(L, 2, "filters");
      int n = lua_istable(L, -1) ? (int) luaL_len(L, -1) : 0;
      if (n > 0 && (dd->filters = SDL_calloc(n, sizeof(SDL_DialogFileFilter)))) {
        for (int i = 0; i < n; i++, dd->n_filters++) {
          lua_geti(L, -1, i + 1);
          lua_getfield(L, -1, "name");
          lua_getfield(L, -2, "pattern");
          dd->filters[i].name = SDL_strdup(luaL_optstring(L, -2, ""));
          dd->filters[i].pattern = SDL_strdup(luaL_optstring(L, -1, "*"));
          lua_pop(L, 3);
        }
        SDL_SetPointerProperty(props, SDL_PROP_FILE_DIALOG_FILTERS_POINTER, dd->filters);
        SDL_SetNumberProperty(props, SDL_PROP_FILE_DIALOG_NFILTERS_NUMBER, dd->n_filters);
      }
      lua_pop(L, 1);
    }
  }
  SDL_ShowFileDialogWithProperties(type, dialog_callback, dd, props);
  SDL_DestroyProperties(props);
  return 0;
}

static int f_open_file_dialog(lua_State *L) { return open_dialog(L, SDL_FILEDIALOG_OPENFILE); }
static int f_save_file_dialog(lua_State *L) { return open_dialog(L, SDL_FILEDIALOG_SAVEFILE); }
static int f_open_directory_dialog(lua_State *L) { return open_dialog(L, SDL_FILEDIALOG_OPENFOLDER); }


static const luaL_Reg lib[] = {
  { "poll_event",          f_poll_event          },
  { "wait_event",          f_wait_event          },
  { "watch_readable",      f_watch_readable      },
  { "unwatch_readable",    f_unwatch_readable    },
  { "set_cursor",          f_set_cursor          },
  { "set_window_title",    f_set_window_title    },
  { "set_window_mode",     f_set_window_mode     },
  { "get_window_mode",     f_get_window_mode     },
  { "set_window_bordered", f_set_window_bordered },
  { "set_window_hit_test", f_set_window_hit_test },
  { "get_window_size",     f_get_window_size     },
  { "set_window_size",     f_set_window_size     },
  { "set_text_input_rect", f_set_text_input_rect },
  { "clear_ime",           f_clear_ime           },
  { "window_has_focus",    f_window_has_focus    },
  { "raise_window",        f_raise_window        },
  { "show_fatal_error",    f_show_fatal_error    },
  { "rmdir",               f_rmdir               },
  { "chdir",               f_chdir               },
  { "mkdir",               f_mkdir               },
  { "list_dir",            f_list_dir            },
  { "absolute_path",       f_absolute_path       },
  { "get_file_info",       f_get_file_info       },
  { "get_clipboard",       f_get_clipboard       },
  { "set_clipboard",       f_set_clipboard       },
  { "get_process_id",      f_get_process_id      },
  { "get_time",            f_get_time            },
  { "sleep",               f_sleep               },
  { "exec",                f_exec                },
  { "open_url",            f_open_url            },
  { "fuzzy_match",         f_fuzzy_match         },
  { "set_window_opacity",  f_set_window_opacity  },
  { "load_native_plugin",  f_load_native_plugin  },
  { "path_compare",        f_path_compare        },
  { "get_fs_type",         f_get_fs_type         },
  { "open_file_dialog",      f_open_file_dialog      },
  { "save_file_dialog",      f_save_file_dialog      },
  { "open_directory_dialog", f_open_directory_dialog },
  { NULL, NULL }
};


int luaopen_system(lua_State *L) {
  DIALOG_EVENT_TYPE = SDL_RegisterEvents(1);
#if defined(__linux__) && __has_include(<X11/Xlib.h>)
  x11_clipboard_init();
#endif
  luaL_newmetatable(L, API_TYPE_NATIVE_PLUGIN); 
  lua_pushcfunction(L, f_library_gc);
  lua_setfield(L, -2, "__gc");
  luaL_newlib(L, lib);
  return 1;
}
