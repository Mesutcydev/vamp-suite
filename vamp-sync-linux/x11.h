#include <X11/Xlib.h>

typedef struct {
	int x, y, width, height;
} vamp_geometry;

int vamp_init_x11(void);
int vamp_unlocked(Display *d);
int vamp_geometry_for(Display *d, Window w, vamp_geometry *g);
int vamp_windows(Display *d, Window *windows, int capacity);
int vamp_window_name(Display *d, Window w, char *name, int capacity);
Pixmap vamp_capture_window(Display *d, Window w);
void vamp_release_window(Display *d, Window w, Pixmap p);
int vamp_frame(Display *d, Drawable drawable, int width, int height, void *pixels);
int vamp_xtest(Display *d);
int vamp_move(Display *d, Window w, int x, int y, int relative);
int vamp_button(Display *d, Window w, int button, int down);
int vamp_keycode(Display *d, const char *symbol);
int vamp_key_level(Display *d, int code, const char *symbol);
int vamp_key(Display *d, Window w, int code, int down);
int vamp_activate(Display *d, Window w);
int vamp_request_close(Display *d, Window w);
int vamp_resize(Display *d, Window w, int width, int height);
int vamp_window_class(Display *d, Window w, char *name, int capacity);
