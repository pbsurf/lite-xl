/*
** Watches sources of input (file descriptors; event handles on Windows) from
** a thread that pushes an SDL event when one has data to read (or is closed),
** so the main loop can block in system.wait_event() instead of polling them.
**
** A watch fires once: whoever reads re-arms it after reading what's there.
** The thread waits on its own duplicate of each source, which it closes
** itself, so the owner can close its source at any time, watched or not.
**
** On Windows only the first MAXIMUM_WAIT_OBJECTS - 1 watches are waited on.
*/
#include "api.h"

#include <stdbool.h>
#include <stdint.h>
#include <string.h>
#include <SDL3/SDL.h>

#ifdef _WIN32
  #include <windows.h>
#else
  #include <errno.h>
  #include <fcntl.h>
  #include <poll.h>
  #include <unistd.h>
#endif

unsigned int READWATCH_EVENT_TYPE = 0;

typedef struct {
  lua_Integer source;   // as given by the owner: the event's value
  intptr_t waited;      // our duplicate of it
  bool removed;         // unwatched: the thread closes `waited`
} watch_t;

static SDL_Mutex *mutex;
static watch_t *watches;
static int count, capacity;
#ifdef _WIN32
  static HANDLE interrupt;  // auto-reset event: the set of watches changed
#else
  static int interrupt[2];  // self-pipe: the set of watches changed
#endif


static void close_waited(intptr_t waited) {
#ifdef _WIN32
  CloseHandle((HANDLE) waited);
#else
  close((int) waited);
#endif
}


static void interrupt_thread(void) {
#ifdef _WIN32
  SetEvent(interrupt);
#else
  char c = 0;
  // the pipe is non-blocking; if it's full, the thread has wake-ups pending anyway
  (void) !write(interrupt[1], &c, 1);
#endif
}


// with the mutex held: drops removed watches; the thread is not waiting on them
static void compact(void) {
  int n = 0;
  for (int i = 0; i < count; ++i) {
    if (watches[i].removed)
      close_waited(watches[i].waited);
    else
      watches[n++] = watches[i];
  }
  count = n;
}


// a waited source is ready: drop its watch and tell the main loop
static void fire(intptr_t waited) {
  bool found = false;
  lua_Integer source = 0;
  SDL_LockMutex(mutex);
  for (int i = 0; i < count; ++i) {
    if (watches[i].waited == waited && !watches[i].removed) {
      source = watches[i].source;
      watches[i].removed = true;
      found = true;
      break;
    }
  }
  compact();
  SDL_UnlockMutex(mutex);
  if (found) {
    SDL_Event event = { .type = READWATCH_EVENT_TYPE };
    event.user.data1 = (void*) (intptr_t) source;
    SDL_PushEvent(&event);
  }
}


static int watch_thread(void *data) {
  (void) data;
#ifdef _WIN32
  HANDLE handles[MAXIMUM_WAIT_OBJECTS];
  for (;;) {
    SDL_LockMutex(mutex);
    compact();
    DWORD n = 0;
    handles[n++] = interrupt;
    for (int i = 0; i < count && n < MAXIMUM_WAIT_OBJECTS; ++i)
      handles[n++] = (HANDLE) watches[i].waited;
    SDL_UnlockMutex(mutex);
    DWORD r = WaitForMultipleObjects(n, handles, FALSE, INFINITE);
    if (r > WAIT_OBJECT_0 && r < WAIT_OBJECT_0 + n) {
      fire((intptr_t) handles[r - WAIT_OBJECT_0]);
    } else if (r == WAIT_FAILED) {
      // an invalid handle: fire those that aren't simply unsignaled, so they're dropped
      for (DWORD i = 1; i < n; ++i) {
        if (WaitForSingleObject(handles[i], 0) != WAIT_TIMEOUT)
          fire((intptr_t) handles[i]);
      }
    }
  }
#else
  struct pollfd *fds = NULL;
  int fds_capacity = 0;
  for (;;) {
    SDL_LockMutex(mutex);
    compact();
    if (count + 1 > fds_capacity) {
      fds_capacity = (count + 1) * 2;
      fds = SDL_realloc(fds, fds_capacity * sizeof(struct pollfd));
    }
    int n = 0;
    fds[n++] = (struct pollfd) { .fd = interrupt[0], .events = POLLIN };
    for (int i = 0; i < count; ++i)
      fds[n++] = (struct pollfd) { .fd = (int) watches[i].waited, .events = POLLIN };
    SDL_UnlockMutex(mutex);
    if (poll(fds, n, -1) < 0) {
      if (errno != EINTR) SDL_Delay(10);  // shouldn't happen; don't spin if it does
      continue;
    }
    if (fds[0].revents) {
      char buf[64];
      while (read(interrupt[0], buf, sizeof(buf)) > 0);
    }
    // readable, hung up, error or invalid: in each case the owner should read
    for (int i = 1; i < n; ++i) {
      if (fds[i].revents)
        fire(fds[i].fd);
    }
  }
#endif
  return 0;
}


static bool init(void) {
  if (mutex) return true;
  READWATCH_EVENT_TYPE = SDL_RegisterEvents(1);
  if (READWATCH_EVENT_TYPE == 0) return false;
#ifdef _WIN32
  if (!(interrupt = CreateEvent(NULL, FALSE, FALSE, NULL))) return false;
#else
  if (pipe(interrupt) != 0) return false;
  for (int i = 0; i < 2; ++i) {
    fcntl(interrupt[i], F_SETFL, O_NONBLOCK);
    fcntl(interrupt[i], F_SETFD, FD_CLOEXEC);
  }
#endif
  mutex = SDL_CreateMutex();
  SDL_Thread *thread = SDL_CreateThread(watch_thread, "readwatch", NULL);
  if (!mutex || !thread) return false;
  SDL_DetachThread(thread);
  return true;
}


/*
** system.watch_readable(source): arms a one-shot watch on source, a file
** descriptor (on Windows an event handle) such as process:watch_source()
** returns. When it has data to read, or is closed, system.poll_event()
** returns "readable", source. Returns true, or nil and an error.
*/
int f_watch_readable(lua_State *L) {
  lua_Integer source = luaL_checkinteger(L, 1);
  if (!init()) {
    lua_pushnil(L);
    lua_pushstring(L, "can't start the watch thread");
    return 2;
  }
  SDL_LockMutex(mutex);
  for (int i = 0; i < count; ++i) {
    if (watches[i].source == source && !watches[i].removed) {
      SDL_UnlockMutex(mutex);
      lua_pushboolean(L, 1);
      return 1;
    }
  }
  intptr_t waited;
#ifdef _WIN32
  HANDLE dup;
  if (!DuplicateHandle(GetCurrentProcess(), (HANDLE) (intptr_t) source, GetCurrentProcess(), &dup, 0, FALSE, DUPLICATE_SAME_ACCESS)) {
    SDL_UnlockMutex(mutex);
    lua_pushnil(L);
    lua_pushfstring(L, "can't duplicate the handle (error %d)", (int) GetLastError());
    return 2;
  }
  waited = (intptr_t) dup;
#else
  int dup = fcntl((int) source, F_DUPFD_CLOEXEC, 0);
  if (dup < 0) {
    SDL_UnlockMutex(mutex);
    lua_pushnil(L);
    lua_pushfstring(L, "can't duplicate the file descriptor: %s", strerror(errno));
    return 2;
  }
  waited = dup;
#endif
  if (count == capacity) {
    capacity = capacity ? capacity * 2 : 8;
    watches = SDL_realloc(watches, capacity * sizeof(watch_t));
  }
  watches[count++] = (watch_t) { .source = source, .waited = waited, .removed = false };
  SDL_UnlockMutex(mutex);
  interrupt_thread();
  lua_pushboolean(L, 1);
  return 1;
}


/*
** system.unwatch_readable(source): drops the watch on source, if any.
*/
int f_unwatch_readable(lua_State *L) {
  lua_Integer source = luaL_checkinteger(L, 1);
  if (!mutex) return 0;
  bool found = false;
  SDL_LockMutex(mutex);
  for (int i = 0; i < count; ++i) {
    if (watches[i].source == source && !watches[i].removed) {
      watches[i].removed = true;
      found = true;
    }
  }
  SDL_UnlockMutex(mutex);
  if (found) interrupt_thread();
  return 0;
}
