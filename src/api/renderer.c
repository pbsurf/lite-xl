#include <stdlib.h>
#include <string.h>
#include "api.h"
#include "../renderer.h"
#include "../rencache.h"
#include "../renwindow.h"
#include "lua.h"

// a reference index to a table that stores the fonts
static int RENDERER_FONT_REF = LUA_NOREF;

static int font_get_options(
  lua_State *L,
  ERenFontAntialiasing *antialiasing,
  ERenFontHinting *hinting,
  int *style
) {
  if (lua_gettop(L) > 2 && lua_istable(L, 3)) {
    lua_getfield(L, 3, "antialiasing");
    if (lua_isstring(L, -1)) {
      const char *antialiasing_str = lua_tostring(L, -1);
      if (antialiasing_str) {
        if (strcmp(antialiasing_str, "none") == 0) {
          *antialiasing = FONT_ANTIALIASING_NONE;
        } else if (strcmp(antialiasing_str, "grayscale") == 0) {
          *antialiasing = FONT_ANTIALIASING_GRAYSCALE;
        } else if (strcmp(antialiasing_str, "subpixel") == 0) {
          *antialiasing = FONT_ANTIALIASING_SUBPIXEL;
        } else {
          return luaL_error(
            L,
            "error in font options, unknown antialiasing option: \"%s\"",
            antialiasing_str
          );
        }
      }
    }
    lua_getfield(L, 3, "hinting");
    if (lua_isstring(L, -1)) {
      const char *hinting_str = lua_tostring(L, -1);
      if (hinting_str) {
        if (strcmp(hinting_str, "slight") == 0) {
          *hinting = FONT_HINTING_SLIGHT;
        } else if (strcmp(hinting_str, "none") == 0) {
          *hinting = FONT_HINTING_NONE;
        } else if (strcmp(hinting_str, "full") == 0) {
          *hinting = FONT_HINTING_FULL;
        } else {
          return luaL_error(
            L,
            "error in font options, unknown hinting option: \"%s\"",
            hinting
          );
        }
      }
    }
    int style_local = 0;
    lua_getfield(L, 3, "italic");
    if (lua_toboolean(L, -1))
      style_local |= FONT_STYLE_ITALIC;
    lua_getfield(L, 3, "bold");
    if (lua_toboolean(L, -1))
      style_local |= FONT_STYLE_BOLD;
    lua_getfield(L, 3, "underline");
    if (lua_toboolean(L, -1))
      style_local |= FONT_STYLE_UNDERLINE;
    lua_getfield(L, 3, "smoothing");
    if (lua_toboolean(L, -1))
      style_local |= FONT_STYLE_SMOOTH;
    lua_getfield(L, 3, "strikethrough");
    if (lua_toboolean(L, -1))
      style_local |= FONT_STYLE_STRIKETHROUGH;

    lua_pop(L, 5);

    if (style_local != 0)
      *style = style_local;
  }

  return 0;
}

static int f_font_load(lua_State *L) {
  const char *filename  = luaL_checkstring(L, 1);
  float size = luaL_checknumber(L, 2);
  int style = 0;
  ERenFontHinting hinting = FONT_HINTING_SLIGHT;
  ERenFontAntialiasing antialiasing = FONT_ANTIALIASING_SUBPIXEL;

  int ret_code = font_get_options(L, &antialiasing, &hinting, &style);
  if (ret_code > 0)
    return ret_code;

  RenFont** font = lua_newuserdata(L, sizeof(RenFont*));
  *font = ren_font_load(&window_renderer, filename, size, antialiasing, hinting, style);
  if (!*font)
    return luaL_error(L, "failed to load font: %s", SDL_GetError());
  luaL_setmetatable(L, API_TYPE_FONT);
  return 1;
}

static bool font_retrieve(lua_State* L, RenFont** fonts, int idx) {
  bool is_table;
  memset(fonts, 0, sizeof(RenFont*)*FONT_FALLBACK_MAX);
  if (lua_type(L, idx) != LUA_TTABLE) {
    fonts[0] = *(RenFont**)luaL_checkudata(L, idx, API_TYPE_FONT);
    is_table = false;
  } else {
    is_table = true;
    int len = luaL_len(L, idx); len = len > FONT_FALLBACK_MAX ? FONT_FALLBACK_MAX : len;
    for (int i = 0; i < len; i++) {
      lua_rawgeti(L, idx, i+1);
      fonts[i] = *(RenFont**) luaL_checkudata(L, -1, API_TYPE_FONT);
      lua_pop(L, 1);
    }
  }
#ifdef LITE_USE_SDL_RENDERER
  update_font_scale(&window_renderer, fonts);
#endif
  return is_table;
}

static int f_font_copy(lua_State *L) {
  RenFont* fonts[FONT_FALLBACK_MAX];
  bool table = font_retrieve(L, fonts, 1);
  float size = lua_gettop(L) >= 2 ? luaL_checknumber(L, 2) : ren_font_group_get_height(fonts);
  int style = -1;
  ERenFontHinting hinting = -1;
  ERenFontAntialiasing antialiasing = -1;

  int ret_code = font_get_options(L, &antialiasing, &hinting, &style);
  if (ret_code > 0)
    return ret_code;

  if (table) {
    lua_newtable(L);
    luaL_setmetatable(L, API_TYPE_FONT);
  }
  for (int i = 0; i < FONT_FALLBACK_MAX && fonts[i]; ++i) {
    RenFont** font = lua_newuserdata(L, sizeof(RenFont*));
    *font = ren_font_copy(&window_renderer, fonts[i], size, antialiasing, hinting, style);
    if (!*font)
      return luaL_error(L, "failed to copy font: %s", SDL_GetError());
    luaL_setmetatable(L, API_TYPE_FONT);
    if (table)
      lua_rawseti(L, -2, i+1);
  }
  return 1;
}

static int f_font_group(lua_State* L) {
  int table_size;
  luaL_checktype(L, 1, LUA_TTABLE);

  table_size = lua_rawlen(L, 1);
  if (table_size <= 0)
    return luaL_error(L, "failed to create font group: table is empty");
  if (table_size > FONT_FALLBACK_MAX)
    return luaL_error(L, "failed to create font group: table size too large");

  // we also need to ensure that there are no fontgroups inside it
  for (int i = 1; i <= table_size; i++) {
    if (lua_rawgeti(L, 1, i) != LUA_TUSERDATA)
      return luaL_typeerror(L, -1, API_TYPE_FONT "(userdata)");
    lua_pop(L, 1);
  }

  luaL_setmetatable(L, API_TYPE_FONT);
  return 1;
}

static int f_font_get_path(lua_State *L) {
  RenFont* fonts[FONT_FALLBACK_MAX];
  bool table = font_retrieve(L, fonts, 1);

  if (table) {
    lua_newtable(L);
  }
  for (int i = 0; i < FONT_FALLBACK_MAX && fonts[i]; ++i) {
    const char* path = ren_font_get_path(fonts[i]);
    lua_pushstring(L, path);
    if (table)
      lua_rawseti(L, -2, i+1);
  }
  return 1;
}

static int f_font_set_tab_size(lua_State *L) {
  RenFont* fonts[FONT_FALLBACK_MAX]; font_retrieve(L, fonts, 1);
  int n = luaL_checknumber(L, 2);
  ren_font_group_set_tab_size(fonts, n);
  return 0;
}

static int f_font_set_letter_spacing(lua_State *L) {
  RenFont* fonts[FONT_FALLBACK_MAX]; font_retrieve(L, fonts, 1);
  ren_font_group_set_letter_spacing(fonts, luaL_checknumber(L, 2));
  return 0;
}

static int f_font_get_letter_spacing(lua_State *L) {
  RenFont* fonts[FONT_FALLBACK_MAX]; font_retrieve(L, fonts, 1);
  lua_pushnumber(L, ren_font_group_get_letter_spacing(fonts));
  return 1;
}

static int f_font_gc(lua_State *L) {
  if (lua_istable(L, 1)) return 0; // do not run if its FontGroup
  RenFont** self = luaL_checkudata(L, 1, API_TYPE_FONT);
  ren_font_free(*self);

  return 0;
}


static int f_font_get_width(lua_State *L) {
  RenFont* fonts[FONT_FALLBACK_MAX]; font_retrieve(L, fonts, 1);
  size_t len;
  const char *text = luaL_checklstring(L, 2, &len);

  lua_pushnumber(L, ren_font_group_get_width(&window_renderer, fonts, text, len, NULL));
  return 1;
}

static int f_font_get_height(lua_State *L) {
  RenFont* fonts[FONT_FALLBACK_MAX]; font_retrieve(L, fonts, 1);
  lua_pushnumber(L, ren_font_group_get_height(fonts));
  return 1;
}

static int f_font_get_size(lua_State *L) {
  RenFont* fonts[FONT_FALLBACK_MAX]; font_retrieve(L, fonts, 1);
  lua_pushnumber(L, ren_font_group_get_size(fonts));
  return 1;
}

static int f_font_set_size(lua_State *L) {
  RenFont* fonts[FONT_FALLBACK_MAX]; font_retrieve(L, fonts, 1);
  float size = luaL_checknumber(L, 2);
  ren_font_group_set_size(&window_renderer, fonts, size);
  return 0;
}

static int color_value_error(lua_State *L, int idx, int table_idx) {
  const char *type, *msg;
  // generate an appropriate error message
  if (luaL_getmetafield(L, -1, "__name") == LUA_TSTRING) {
    type = lua_tostring(L, -1); // metatable name
  } else if (lua_type(L, -1) == LUA_TLIGHTUSERDATA) {
    type = "light userdata"; // special name for light userdata
  } else {
    type = lua_typename(L, lua_type(L, -1)); // default name
  }
  // the reason it went through so much hoops is to generate the correct error
  // message (with function name and proper index).
  msg = lua_pushfstring(L, "table[%d]: %s expected, got %s", table_idx, lua_typename(L, LUA_TNUMBER), type);
  return luaL_argerror(L, idx, msg);
}

static int get_color_value(lua_State *L, int idx, int table_idx) {
  lua_rawgeti(L, idx, table_idx);
  return lua_isnumber(L, -1) ? lua_tonumber(L, -1) : color_value_error(L, idx, table_idx);
}

static int get_color_value_opt(lua_State *L, int idx, int table_idx, int default_value) {
  lua_rawgeti(L, idx, table_idx);
  if (lua_isnoneornil(L, -1))
    return default_value;
  else if (lua_isnumber(L, -1))
    return lua_tonumber(L, -1);
  else
    return color_value_error(L, idx, table_idx);
}

static RenColor checkcolor(lua_State *L, int idx, int def) {
  RenColor color;
  if (lua_isnoneornil(L, idx)) {
    return (RenColor) { def, def, def, 255 };
  }
  luaL_checktype(L, idx, LUA_TTABLE);
  color.r = get_color_value(L, idx, 1);
  color.g = get_color_value(L, idx, 2);
  color.b = get_color_value(L, idx, 3);
  color.a = get_color_value_opt(L, idx, 4, 255);
  lua_pop(L, 4);
  return color;
}


static int f_show_debug(lua_State *L) {
  luaL_checkany(L, 1);
  rencache_show_debug(lua_toboolean(L, 1));
  return 0;
}


static int f_get_size(lua_State *L) {
  int w, h;
  ren_get_size(&window_renderer, &w, &h);
  lua_pushnumber(L, w);
  lua_pushnumber(L, h);
  return 2;
}


static int f_begin_frame(UNUSED lua_State *L) {
  rencache_begin_frame(&window_renderer);
  return 0;
}


static int f_end_frame(UNUSED lua_State *L) {
  rencache_end_frame(&window_renderer);
  // clear the font reference table
  lua_newtable(L);
  lua_rawseti(L, LUA_REGISTRYINDEX, RENDERER_FONT_REF);
  return 0;
}


static RenRect rect_to_grid(lua_Number x, lua_Number y, lua_Number w, lua_Number h) {
  int x1 = (int) (x + 0.5), y1 = (int) (y + 0.5);
  int x2 = (int) (x + w + 0.5), y2 = (int) (y + h + 0.5);
  return (RenRect) {x1, y1, x2 - x1, y2 - y1};
}


static int f_set_clip_rect(lua_State *L) {
  lua_Number x = luaL_checknumber(L, 1);
  lua_Number y = luaL_checknumber(L, 2);
  lua_Number w = luaL_checknumber(L, 3);
  lua_Number h = luaL_checknumber(L, 4);
  RenRect rect = rect_to_grid(x, y, w, h);
  rencache_set_clip_rect(&window_renderer, rect);
  return 0;
}


static int f_draw_rect(lua_State *L) {
  lua_Number x = luaL_checknumber(L, 1);
  lua_Number y = luaL_checknumber(L, 2);
  lua_Number w = luaL_checknumber(L, 3);
  lua_Number h = luaL_checknumber(L, 4);
  RenRect rect = rect_to_grid(x, y, w, h);
  RenColor color = checkcolor(L, 5, 255);
  rencache_draw_rect(&window_renderer, rect, color);
  return 0;
}

static int f_draw_text(lua_State *L) {
  RenFont* fonts[FONT_FALLBACK_MAX];
  font_retrieve(L, fonts, 1);

  // stores a reference to this font to the reference table
  lua_rawgeti(L, LUA_REGISTRYINDEX, RENDERER_FONT_REF);
  if (lua_istable(L, -1))
  {
    lua_pushvalue(L, 1);
    lua_pushboolean(L, 1);
    lua_rawset(L, -3);
  } else {
    fprintf(stderr, "warning: failed to reference count fonts\n");
  }
  lua_pop(L, 1);

  size_t len;
  const char *text = luaL_checklstring(L, 2, &len);
  double x = luaL_checknumber(L, 3);
  int y = luaL_checknumber(L, 4);
  RenColor color = checkcolor(L, 5, 255);
  x = rencache_draw_text(&window_renderer, fonts, text, len, x, y, color);
  lua_pushnumber(L, x);
  return 1;
}

/* path: {"M", x, y, "L", x, y, "Q", cx, cy, x, y, "C", c1x, c1y, c2x, c2y, x, y, "Z", ...} */
static int f_draw_path(lua_State *L) {
  luaL_checktype(L, 1, LUA_TTABLE);
  RenColor color = checkcolor(L, 2, 255);
  float stroke_width = luaL_optnumber(L, 3, 0);
  int len = luaL_len(L, 1), ncmds = 0, ncoords = 0;
  for (int i = 1; i <= len; i++) {
    if (lua_rawgeti(L, 1, i) == LUA_TSTRING) ncmds++; else ncoords++;
    lua_pop(L, 1);
  }
  char *cmds = lua_newuserdatauv(L, ncmds + 1, 0);
  float *coords = lua_newuserdatauv(L, (ncoords + 1) * sizeof(float), 0);
  int c = 0, n = 0, need = 0;
  for (int i = 1; i <= len; i++) {
    if (lua_rawgeti(L, 1, i) == LUA_TSTRING) {
      const char *s = lua_tostring(L, -1);
      if (need > 0)
        return luaL_error(L, "path element %d: '%c' needs %d more coordinates", i, cmds[c-1], need);
      if (c == 0 && s[0] != 'M')
        return luaL_error(L, "path element %d: path must begin with 'M'", i);
      if (c > 0 && cmds[c-1] == 'Z' && s[0] != 'M')
        return luaL_error(L, "path element %d: 'Z' must be followed by 'M'", i);
      switch (s[0]) {
        case 'M': case 'L': need = 2; break;
        case 'Q': need = 4; break;
        case 'C': need = 6; break;
        case 'Z': need = 0; break;
        default: return luaL_error(L, "path element %d: unknown command '%s'", i, s);
      }
      cmds[c++] = s[0];
    } else {
      if (!lua_isnumber(L, -1))
        return luaL_error(L, "path element %d: expected a command or a number", i);
      if (need-- <= 0)
        return luaL_error(L, "path element %d: unexpected coordinate", i);
      coords[n++] = lua_tonumber(L, -1);
    }
    lua_pop(L, 1);
  }
  if (need > 0)
    return luaL_error(L, "path: '%c' needs %d more coordinates", cmds[c-1], need);
  if (n / 2 > 32767)
    return luaL_error(L, "path: too many points");
  rencache_draw_path(&window_renderer, cmds, c, coords, n, stroke_width, color);
  return 0;
}

static int f_draw_glyph(lua_State *L) {
  RenFont* fonts[FONT_FALLBACK_MAX];
  font_retrieve(L, fonts, 1);

  // stores a reference to this font to the reference table
  lua_rawgeti(L, LUA_REGISTRYINDEX, RENDERER_FONT_REF);
  if (lua_istable(L, -1))
  {
    lua_pushvalue(L, 1);
    lua_pushboolean(L, 1);
    lua_rawset(L, -3);
  } else {
    fprintf(stderr, "warning: failed to reference count fonts\n");
  }
  lua_pop(L, 1);

  size_t len;
  const char *text = luaL_checklstring(L, 2, &len);
  float x = luaL_checknumber(L, 3), y = luaL_checknumber(L, 4);
  float w = luaL_checknumber(L, 5), h = luaL_checknumber(L, 6);
  RenColor color = checkcolor(L, 7, 255);
  rencache_draw_glyph(&window_renderer, fonts, ren_utf8_codepoint(text, len), x, y, w, h, color);
  return 0;
}

static int f_draw_shadow(lua_State *L) {
  float x = luaL_checknumber(L, 1), y = luaL_checknumber(L, 2);
  float w = luaL_checknumber(L, 3), h = luaL_checknumber(L, 4);
  float blur = luaL_checknumber(L, 5);
  RenColor color = checkcolor(L, 6, 255);
  rencache_draw_shadow(&window_renderer, x, y, w, h, blur, color);
  return 0;
}

// Saves what the window shows as a PNG, for inspecting a running editor (scripts/screenshot).
// Stored (uncompressed) deflate blocks keep the encoder tiny; the files are large, not slow.
static uint32_t png_crc(uint32_t crc, const uint8_t *p, size_t n) {
  static uint32_t table[256];
  if (!table[1]) {
    for (uint32_t i = 0; i < 256; i++) {
      uint32_t c = i;
      for (int k = 0; k < 8; k++) c = (c & 1) ? 0xEDB88320u ^ (c >> 1) : c >> 1;
      table[i] = c;
    }
  }
  crc = ~crc;
  while (n--) crc = table[(crc ^ *p++) & 0xFF] ^ (crc >> 8);
  return ~crc;
}

static void png_be32(uint8_t *p, uint32_t v) {
  p[0] = v >> 24; p[1] = v >> 16; p[2] = v >> 8; p[3] = v;
}

static bool png_chunk(SDL_IOStream *io, const char *type, const uint8_t *data, size_t len) {
  uint8_t head[8], tail[4];
  png_be32(head, (uint32_t) len);
  memcpy(head + 4, type, 4);
  png_be32(tail, png_crc(png_crc(0, head + 4, 4), data, len));
  return SDL_WriteIO(io, head, 8) == 8 && (!len || SDL_WriteIO(io, data, len) == len)
      && SDL_WriteIO(io, tail, 4) == 4;
}

// renderer.save_screenshot(path [, x, y, w, h [, zoom]]): the window surface (or the part
// at x, y of size w, h, in surface pixels), scaled up by an integer zoom with nearest
// neighbor, as a PNG. Returns true, or nil and an error.
static int f_save_screenshot(lua_State *L) {
  const char *path = luaL_checkstring(L, 1);
  SDL_Surface *src = renwin_get_surface(&window_renderer).surface;
  if (!src) { lua_pushnil(L); lua_pushstring(L, "no window surface"); return 2; }
  int x0 = luaL_optinteger(L, 2, 0), y0 = luaL_optinteger(L, 3, 0);
  int w = luaL_optinteger(L, 4, src->w), h = luaL_optinteger(L, 5, src->h);
  int zoom = luaL_optinteger(L, 6, 1);
  if (x0 < 0 || y0 < 0 || x0 >= src->w || y0 >= src->h) return luaL_error(L, "area outside the window");
  if (w > src->w - x0) w = src->w - x0;
  if (h > src->h - y0) h = src->h - y0;
  if (w <= 0 || h <= 0 || zoom < 1 || zoom > 16) return luaL_error(L, "bad area or zoom");

  SDL_Surface *rgb = SDL_ConvertSurface(src, SDL_PIXELFORMAT_RGB24);
  if (!rgb) { lua_pushnil(L); lua_pushstring(L, SDL_GetError()); return 2; }
  size_t ow = (size_t) w * zoom, oh = (size_t) h * zoom;
  size_t stride = ow * 3 + 1, rawlen = stride * oh;
  size_t nblocks = (rawlen + 65534) / 65535;
  size_t zlen = 2 + rawlen + nblocks * 5 + 4;
  uint8_t *raw = malloc(rawlen), *z = malloc(zlen);
  if (!raw || !z) { free(raw); free(z); SDL_DestroySurface(rgb); return luaL_error(L, "out of memory"); }

  for (size_t y = 0; y < oh; y++) {
    uint8_t *row = raw + y * stride;
    const uint8_t *s = (const uint8_t *) rgb->pixels + (y0 + y / zoom) * (size_t) rgb->pitch + x0 * 3;
    *row++ = 0; // filter: none
    for (size_t x = 0; x < ow; x++, row += 3) memcpy(row, s + (x / zoom) * 3, 3);
  }
  SDL_DestroySurface(rgb);

  uint32_t a = 1, b = 0;
  for (size_t i = 0; i < rawlen; i++) { a = (a + raw[i]) % 65521; b = (b + a) % 65521; }
  uint8_t *p = z;
  *p++ = 0x78; *p++ = 0x01;
  for (size_t off = 0; off < rawlen; off += 65535) {
    uint16_t n = rawlen - off < 65535 ? rawlen - off : 65535;
    *p++ = off + n == rawlen; // final block
    *p++ = n; *p++ = n >> 8; *p++ = ~n; *p++ = (uint8_t) (~n >> 8);
    memcpy(p, raw + off, n); p += n;
  }
  png_be32(p, (b << 16) | a); p += 4;

  uint8_t ihdr[13];
  png_be32(ihdr, (uint32_t) ow); png_be32(ihdr + 4, (uint32_t) oh);
  ihdr[8] = 8; ihdr[9] = 2; ihdr[10] = ihdr[11] = ihdr[12] = 0; // 8-bit RGB
  static const uint8_t sig[8] = { 0x89, 'P', 'N', 'G', '\r', '\n', 0x1A, '\n' };
  SDL_IOStream *io = SDL_IOFromFile(path, "wb");
  bool ok = io && SDL_WriteIO(io, sig, 8) == 8 && png_chunk(io, "IHDR", ihdr, 13)
         && png_chunk(io, "IDAT", z, (size_t) (p - z)) && png_chunk(io, "IEND", NULL, 0);
  if (io && !SDL_CloseIO(io)) ok = false;
  free(raw); free(z);
  if (!ok) { lua_pushnil(L); lua_pushstring(L, SDL_GetError()); return 2; }
  lua_pushboolean(L, 1);
  return 1;
}

static const luaL_Reg lib[] = {
  { "show_debug",         f_show_debug         },
  { "get_size",           f_get_size           },
  { "save_screenshot",    f_save_screenshot    },
  { "begin_frame",        f_begin_frame        },
  { "end_frame",          f_end_frame          },
  { "set_clip_rect",      f_set_clip_rect      },
  { "draw_rect",          f_draw_rect          },
  { "draw_text",          f_draw_text          },
  { "draw_path",          f_draw_path          },
  { "draw_glyph",         f_draw_glyph         },
  { "draw_shadow",        f_draw_shadow        },
  { NULL,                 NULL                 }
};

static const luaL_Reg fontLib[] = {
  { "__gc",               f_font_gc                 },
  { "load",               f_font_load               },
  { "copy",               f_font_copy               },
  { "group",              f_font_group              },
  { "set_tab_size",       f_font_set_tab_size       },
  { "set_letter_spacing", f_font_set_letter_spacing },
  { "get_letter_spacing", f_font_get_letter_spacing },
  { "get_width",          f_font_get_width          },
  { "get_height",         f_font_get_height         },
  { "get_size",           f_font_get_size           },
  { "set_size",           f_font_set_size           },
  { "get_path",           f_font_get_path           },
  { NULL, NULL }
};

int luaopen_renderer(lua_State *L) {
  // gets a reference on the registry to store font data
  lua_newtable(L);
  RENDERER_FONT_REF = luaL_ref(L, LUA_REGISTRYINDEX);

  luaL_newlib(L, lib);
  luaL_newmetatable(L, API_TYPE_FONT);
  luaL_setfuncs(L, fontLib, 0);
  lua_pushvalue(L, -1);
  lua_setfield(L, -2, "__index");
  lua_setfield(L, -2, "font");
  return 1;
}
