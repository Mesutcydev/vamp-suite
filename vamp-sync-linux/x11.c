#include "x11.h"
#include <X11/Xatom.h>
#include <X11/Xutil.h>
#include <X11/Xlib-xcb.h>
#include <xcb/composite.h>
#include <xcb/screensaver.h>
#include <xcb/xtest.h>
#include <stdlib.h>
#include <string.h>

static int ignore_stale_window(Display *d, XErrorEvent *error) {
	(void)d;
	(void)error;
	return 0;
}

int vamp_init_x11(void) {
	if (!XInitThreads()) return 0;
	XSetErrorHandler(ignore_stale_window);
	return 1;
}

static Window root(Display *d) { return DefaultRootWindow(d); }

int vamp_unlocked(Display *d) {
	xcb_connection_t *c = XGetXCBConnection(d);
	xcb_screensaver_query_info_reply_t *info = xcb_screensaver_query_info_reply(
		c, xcb_screensaver_query_info(c, root(d)), NULL);
	int unlocked = info && info->state == XCB_SCREENSAVER_STATE_OFF;
	free(info);
	return unlocked;
}

int vamp_geometry_for(Display *d, Window w, vamp_geometry *g) {
	if (!w) w = root(d);
	XWindowAttributes a;
	Window child;
	if (!XGetWindowAttributes(d, w, &a) || a.map_state != IsViewable ||
		a.width < 2 || a.height < 2 || a.width > 8192 || a.height > 8192 ||
		!XTranslateCoordinates(d, w, root(d), 0, 0, &g->x, &g->y, &child)) return 0;
	g->width = a.width;
	g->height = a.height;
	return 1;
}

int vamp_windows(Display *d, Window *windows, int capacity) {
	Atom atom = XInternAtom(d, "_NET_CLIENT_LIST_STACKING", True), type;
	unsigned long count, after;
	unsigned char *data = NULL;
	int format;
	if (!atom || XGetWindowProperty(d, root(d), atom, 0, capacity, False, XA_WINDOW,
			&type, &format, &count, &after, &data) != Success) return -1;
	if (type != XA_WINDOW || format != 32 || count > (unsigned long)capacity) {
		XFree(data);
		return -1;
	}
	memcpy(windows, data, count * sizeof(Window));
	XFree(data);
	return (int)count;
}

int vamp_window_name(Display *d, Window w, char *name, int capacity) {
	Atom title = XInternAtom(d, "_NET_WM_NAME", True);
	Atom utf8 = XInternAtom(d, "UTF8_STRING", True);
	Atom type;
	unsigned long count, after;
	unsigned char *data = NULL;
	int format;
	int size = 0;
	if (title && utf8 && XGetWindowProperty(d, w, title, 0, (capacity-1)/4, False,
			utf8, &type, &format, &count, &after, &data) == Success) {
		if (type == utf8 && format == 8 && count < (unsigned long)capacity) {
			memcpy(name, data, count);
			size = (int)count;
		}
		XFree(data);
	}
	if (size) return size;

	char *legacy = NULL;
	if (XFetchName(d, w, &legacy) && legacy) {
		size = (int)strnlen(legacy, capacity - 1);
		memcpy(name, legacy, size);
		XFree(legacy);
	}
	return size;
}

static int checked(xcb_connection_t *c, xcb_void_cookie_t cookie) {
	xcb_generic_error_t *err = xcb_request_check(c, cookie);
	int ok = err == NULL;
	free(err);
	return ok;
}

Pixmap vamp_capture_window(Display *d, Window w) {
	xcb_connection_t *c = XGetXCBConnection(d);
	if (!checked(c, xcb_composite_redirect_window_checked(c, w, XCB_COMPOSITE_REDIRECT_AUTOMATIC))) return None;
	Pixmap pixmap = xcb_generate_id(c);
	if (!checked(c, xcb_composite_name_window_pixmap_checked(c, w, pixmap))) {
		xcb_composite_unredirect_window(c, w, XCB_COMPOSITE_REDIRECT_AUTOMATIC);
		return None;
	}
	return pixmap;
}

void vamp_release_window(Display *d, Window w, Pixmap p) {
	xcb_connection_t *c = XGetXCBConnection(d);
	xcb_free_pixmap(c, p);
	xcb_composite_unredirect_window(c, w, XCB_COMPOSITE_REDIRECT_AUTOMATIC);
	xcb_flush(c);
}

int vamp_frame(Display *d, Drawable drawable, int width, int height, void *pixels) {
	if (!drawable) drawable = root(d);
	XImage *img = XGetImage(d, drawable, 0, 0, width, height, AllPlanes, ZPixmap);
	if (!img) return 0;
	// Pixmaps may report zero channel masks. The root visual must therefore also
	// be the standard true-color visual before this byte layout is used.
	Visual *v = DefaultVisual(d, DefaultScreen(d));
	int ok = img->byte_order == LSBFirst && img->bits_per_pixel == 32 &&
		img->bytes_per_line == width * 4 && v->class == TrueColor &&
		v->red_mask == 0xff0000 && v->green_mask == 0xff00 && v->blue_mask == 0xff &&
		(!img->red_mask || img->red_mask == v->red_mask) &&
		(!img->green_mask || img->green_mask == v->green_mask) &&
		(!img->blue_mask || img->blue_mask == v->blue_mask);
	if (ok) memcpy(pixels, img->data, (size_t)img->bytes_per_line * height);
	XDestroyImage(img);
	return ok;
}

int vamp_xtest(Display *d) {
	xcb_connection_t *c = XGetXCBConnection(d);
	xcb_test_get_version_reply_t *reply = xcb_test_get_version_reply(c, xcb_test_get_version(c, 2, 2), NULL);
	int ok = reply != NULL;
	free(reply);
	return ok;
}

static int fake(Display *d, int type, int code, int x, int y) {
	xcb_connection_t *c = XGetXCBConnection(d);
	return checked(c, xcb_test_fake_input_checked(c, type, code, CurrentTime, root(d), x, y, 0));
}

static int pointer(Display *d, int *x, int *y, Window *child) {
	Window r;
	int local_x, local_y;
	unsigned int mask;
	return XQueryPointer(d, root(d), &r, child, x, y, &local_x, &local_y, &mask);
}

static int within(Display *d, Window w, int x, int y) {
	Window child;
	// Walk topmost visible children at the target point. A window covered by
	// another application must not send a click through to that application.
	Window parent = root(d);
	for (int depth = 0; depth < 32; ++depth) {
		if (!XTranslateCoordinates(d, root(d), parent, x, y, &(int){0}, &(int){0}, &child) ||
			!child || child == parent) return 0;
		if (child == w) return 1;
		parent = child;
	}
	return 0;
}

int vamp_move(Display *d, Window w, int x, int y, int relative) {
	vamp_geometry g;
	if (!vamp_geometry_for(d, w, &g)) return 0;
	if (relative) {
		int current_x, current_y;
		Window child;
		if (!pointer(d, &current_x, &current_y, &child)) return 0;
		x += current_x - g.x;
		y += current_y - g.y;
	}
	x = g.x + (x < 0 ? 0 : x >= g.width ? g.width-1 : x);
	y = g.y + (y < 0 ? 0 : y >= g.height ? g.height-1 : y);
	if (w && !within(d, w, x, y)) return 0;
	return fake(d, MotionNotify, 0, x, y);
}

int vamp_button(Display *d, Window w, int button, int down) {
	if (w && down) {
		int x, y;
		Window child;
		if (!pointer(d, &x, &y, &child) || !within(d, w, x, y)) return 0;
	}
	return fake(d, down ? ButtonPress : ButtonRelease, button, 0, 0);
}

static int focused(Display *d, Window w) {
	Window focus, r, parent, *children;
	unsigned int count;
	int revert;
	XGetInputFocus(d, &focus, &revert);
	for (int depth = 0; depth < 32 && focus > PointerRoot && focus != root(d); ++depth) {
		if (focus == w) return 1;
		if (!XQueryTree(d, focus, &r, &parent, &children, &count)) return 0;
		XFree(children);
		focus = parent;
	}
	return 0;
}

int vamp_keycode(Display *d, const char *symbol) {
	return XKeysymToKeycode(d, XStringToKeysym(symbol));
}

int vamp_key_level(Display *d, int code, const char *symbol) {
	int length;
	KeySym key = XStringToKeysym(symbol);
	KeySym *symbols = XGetKeyboardMapping(d, code, 1, &length);
	if (!symbols) return -1;
	int level = -1;
	for (int i = 0; i < length && i < 2; i++) {
		if (symbols[i] == key) { level = i; break; }
	}
	XFree(symbols);
	return level;
}

int vamp_key(Display *d, Window w, int code, int down) {
	if (w && down && !focused(d, w)) return 0;
	return fake(d, down ? KeyPress : KeyRelease, code, 0, 0);
}

static int client_message(Display *d, Window w, Window destination, long mask,
	const char *name, long a, long b, long c, long e, long f) {
	Atom type = XInternAtom(d, name, True);
	if (!type) return 0;
	XEvent event = {0};
	event.xclient.type = ClientMessage;
	event.xclient.window = w;
	event.xclient.message_type = type;
	event.xclient.format = 32;
	event.xclient.data.l[0] = a;
	event.xclient.data.l[1] = b;
	event.xclient.data.l[2] = c;
	event.xclient.data.l[3] = e;
	event.xclient.data.l[4] = f;
	int sent = XSendEvent(d, destination, False, mask, &event);
	XFlush(d);
	return sent;
}

int vamp_activate(Display *d, Window w) {
	return client_message(d, w, root(d), SubstructureNotifyMask | SubstructureRedirectMask,
		"_NET_ACTIVE_WINDOW", 1, CurrentTime, 0, 0, 0);
}

int vamp_request_close(Display *d, Window w) {
	Atom close = XInternAtom(d, "WM_DELETE_WINDOW", True);
	Atom *protocols;
	int count;
	if (!close || !XGetWMProtocols(d, w, &protocols, &count)) return 0;
	int supported = 0;
	for (int i = 0; i < count; ++i) supported |= protocols[i] == close;
	XFree(protocols);
	return supported && client_message(d, w, w, NoEventMask,
		"WM_PROTOCOLS", close, CurrentTime, 0, 0, 0);
}

int vamp_resize(Display *d, Window w, int width, int height) {
	long flags = StaticGravity | (1 << 10) | (1 << 11) | (1 << 12);
	return client_message(d, w, root(d), SubstructureNotifyMask | SubstructureRedirectMask,
		"_NET_MOVERESIZE_WINDOW", flags, 0, 0, width, height);
}

int vamp_window_class(Display *d, Window w, char *name, int capacity) {
	XClassHint hint = {0};
	if (!XGetClassHint(d, w, &hint)) return 0;
	int size = 0;
	if (hint.res_class) {
		size = (int)strnlen(hint.res_class, capacity - 1);
		memcpy(name, hint.res_class, size);
	}
	XFree(hint.res_name);
	XFree(hint.res_class);
	return size;
}
