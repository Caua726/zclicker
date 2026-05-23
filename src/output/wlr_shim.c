#include <wayland-client.h>
#include <string.h>
#include "wlr-virtual-pointer-unstable-v1-client-protocol.h"

static struct wl_display *display;
static struct wl_seat *seat;
static struct zwlr_virtual_pointer_manager_v1 *vp_manager;
static struct zwlr_virtual_pointer_v1 *pointer;
static uint32_t click_time;

static void reg_global(void *data, struct wl_registry *reg, uint32_t name,
                       const char *iface, uint32_t version) {
    (void)data; (void)version;
    if (strcmp(iface, wl_seat_interface.name) == 0) {
        seat = wl_registry_bind(reg, name, &wl_seat_interface, 1);
    } else if (strcmp(iface, zwlr_virtual_pointer_manager_v1_interface.name) == 0) {
        vp_manager = wl_registry_bind(reg, name, &zwlr_virtual_pointer_manager_v1_interface, 1);
    }
}
static void reg_global_remove(void *d, struct wl_registry *r, uint32_t n) { (void)d;(void)r;(void)n; }
static const struct wl_registry_listener reg_listener = { .global = reg_global, .global_remove = reg_global_remove };

// returns 0 ok, negative on failure (no compositor / no virtual-pointer support)
int zc_wlr_init(void) {
    display = wl_display_connect(NULL);
    if (!display) return -1;
    struct wl_registry *reg = wl_display_get_registry(display);
    wl_registry_add_listener(reg, &reg_listener, NULL);
    wl_display_roundtrip(display);
    if (!vp_manager || !seat) return -2;
    pointer = zwlr_virtual_pointer_manager_v1_create_virtual_pointer(vp_manager, seat);
    if (!pointer) return -3;
    wl_display_roundtrip(display);
    return 0;
}

void zc_wlr_click(unsigned int button) {
    if (!pointer) return;
    click_time += 10;
    zwlr_virtual_pointer_v1_button(pointer, click_time, button, 1); // pressed
    zwlr_virtual_pointer_v1_frame(pointer);
    zwlr_virtual_pointer_v1_button(pointer, click_time, button, 0); // released
    zwlr_virtual_pointer_v1_frame(pointer);
    wl_display_flush(display);
}

void zc_wlr_deinit(void) {
    if (pointer) { zwlr_virtual_pointer_v1_destroy(pointer); pointer = NULL; }
    if (display) { wl_display_flush(display); wl_display_disconnect(display); display = NULL; }
}
