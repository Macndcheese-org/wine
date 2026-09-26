/*
 * Native callback table used by the D3DMetal host layer.
 *
 * This is compiled into winemac.so because the Apple-side D3D layer looks up
 * native symbols, not PE exports.
 */

#if 0
#pragma makedep unix
#endif

#if defined(__x86_64__)

#include "config.h"

#include <dispatch/dispatch.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "macdrv.h"
#include "winuser.h"
#include "winreg.h"
#define WIN32_NO_STATUS
#include "winternl.h"

WINE_DEFAULT_DEBUG_CHANNEL(macd3dmetal);

void OnMainThread(dispatch_block_t block);

struct d3dmetal_macdrv_exports
{
    void (*refresh_display_devices)(BOOL);
    struct macdrv_win_data *(*get_win_data)(HWND);
    void (*release_win_data)(struct macdrv_win_data *);
    macdrv_window (*get_cocoa_window)(HWND, BOOL);
    macdrv_metal_device (*create_metal_device)(void);
    void (*release_metal_device)(macdrv_metal_device);
    macdrv_metal_view (*view_create_metal_view)(macdrv_view, macdrv_metal_device);
    macdrv_metal_layer (*view_get_metal_layer)(macdrv_metal_view);
    void (*view_release_metal_view)(macdrv_metal_view);
    void (*on_main_thread)(dispatch_block_t);
    LSTATUS (WINAPI *reg_query_value_a)(HKEY, LPCSTR, LPDWORD, LPDWORD, BYTE *, LPDWORD);
    LSTATUS (WINAPI *reg_set_value_a)(HKEY, LPCSTR, DWORD, DWORD, const BYTE *, DWORD);
    LSTATUS (WINAPI *reg_open_key_a)(HKEY, LPCSTR, DWORD, REGSAM, HKEY *);
    LSTATUS (WINAPI *reg_create_key_a)(HKEY, LPCSTR, DWORD, LPSTR, DWORD, REGSAM,
                                       LPSECURITY_ATTRIBUTES, HKEY *, LPDWORD);
    LSTATUS (WINAPI *reg_close_key)(HKEY);
    BOOL (WINAPI *enum_display_monitors)(HDC, LPRECT, MONITORENUMPROC, LPARAM);
    BOOL (WINAPI *get_monitor_info_a)(HMONITOR, LPMONITORINFO);
    BOOL (WINAPI *adjust_window_rect_ex)(LPRECT, DWORD, BOOL, DWORD);
    LONG_PTR (WINAPI *get_window_long_ptr_w)(HWND, INT);
    BOOL (WINAPI *get_window_rect)(HWND, LPRECT);
    BOOL (WINAPI *move_window)(HWND, INT, INT, INT, INT, BOOL);
    BOOL (WINAPI *set_window_pos)(HWND, HWND, INT, INT, INT, INT, UINT);
    INT (WINAPI *get_system_metrics)(INT);
    LONG_PTR (WINAPI *set_window_long_ptr_w)(HWND, INT, LONG_PTR);
};

C_ASSERT(sizeof(struct d3dmetal_macdrv_exports) == 24 * sizeof(void *));
C_ASSERT(FIELD_OFFSET(struct macdrv_win_data, client_view) == 16);

/* MNC HACK 9: layout that the GPTK PE-side dxgi/d3d11/d3d12 dispatch
 * expects when it reads window data through this bridge.
 *
 * We discovered (by disassembling GPTK's WineSwapchainCallbacks::
 * InitializeForHWND) that the PE side performs:
 *
 *      get_win_data(hwnd)              -> macdrv_win_data*
 *      view = *(macdrv_view*)(data + 24)
 *      create_metal_view(view, device) -> CAMetalLayer attach
 *
 * i.e. it ignores the field at offset 16 entirely and reads the NSView
 * at +24. Our actual `struct macdrv_win_data` has `client_view` at +16
 * and `struct window_rects` starting at +24, so the GPTK side ends up
 * casting a LONG (window_rect.left) to NSView*, attaching CAMetalLayer
 * to garbage, and the swapchain initializes but never paints — exactly
 * the "process alive, no window contents" symptom we kept hitting.
 *
 * Fix: when the PE bridge asks for win_data, hand it a synthetic
 * fixed-size record whose +24 slot is the WineContentView of the
 * cocoa_window. The original win_data lock is released before we
 * return so we don't hold it across a GPTK call. */
struct mnc_pe_win_data
{
    HWND          hwnd;                /* +0  */
    macdrv_window cocoa_window;        /* +8  */
    macdrv_view   cocoa_view;          /* +16 */
    macdrv_view   client_cocoa_view;   /* +24 — what GPTK actually reads */
    RECT          window_rect;         /* +32 */
    RECT          whole_rect;          /* +48 */
    RECT          client_rect;         /* +64 */
    int           pixel_format;        /* +80 */
    int           _pad0;
    HANDLE        drag_event;          /* +88 */
    unsigned int  bits;                /* +96 */
    int           _pad1;
    void         *surface;             /* +104 */
    void         *unminimized_surface; /* +112 */
};
C_ASSERT(sizeof(struct mnc_pe_win_data) == 120);
C_ASSERT(FIELD_OFFSET(struct mnc_pe_win_data, client_cocoa_view) == 24);

/* Defined in cocoa_window.m (MNC HACK 9 helper). Returns a retained
 * WineContentView cast to macdrv_view for the HWND, or NULL. The PE
 * side never releases this — we use it transiently in the shim. */
extern macdrv_view mnc_d3dmetal_get_content_view(HWND hwnd);

/* Per-thread scratch buffer for the bridge call. PE side always calls
 * get_win_data and release_win_data as a matched pair without nesting,
 * so a single per-thread buffer is sufficient. */
static __thread struct mnc_pe_win_data mnc_pe_win_data_scratch;

/* MNC HACK 32 gate: set the first time GPTK's PE side actually uses this
 * bridge.  Nothing but D3DMetal reaches these entry points -- DXMT talks to
 * winemetal instead -- so this is a true "D3DMetal is driving this process"
 * signal, and it is set before macdrv_create_metal_device() because GPTK's
 * fixed sequence is get_win_data -> create_metal_device -> view_create_metal_view.
 * It replaces the old exe-name list, which only approximated the same thing and
 * mis-classified any non-Steam process rendering through DXMT. */
static int mnc_d3dmetal_bridge_active;

int mnc_d3dmetal_in_use(void)
{
    return mnc_d3dmetal_bridge_active;
}

static struct macdrv_win_data *mnc_bridge_get_win_data(HWND hwnd)
{
    mnc_d3dmetal_bridge_active = 1;

    /* MNC HACK 14 (extends MNC HACK 9): create a dedicated wine
     * client_surface for this swap-chain so we can route present-
     * notifications through it. The client_surface has its own
     * cocoa_view (separate from the window's content view) — that's
     * the NSView GPTK should attach its CAMetalLayer to. We stash
     * the surface pointer as an objc associated object on the view
     * so MNCMetalLayer -nextDrawable can pick it up later.
     *
     * GPTK calls this exactly once per swap-chain creation, in the
     * fixed sequence:
     *   get_win_data -> create_metal_device -> view_create_metal_view
     *     -> get_metal_layer -> release_win_data
     * so the surface lifetime aligns with the swap-chain. We don't
     * release the create reference; the surface lives until the HWND
     * is destroyed (acceptable leak — typically 1–2 swap chains per
     * game). */
    /* wine 11.13 renamed macdrv_client_surface_create(hwnd) to
     * macdrv_CreateClientSurface(hwnd, pixel_format) and moved it to the
     * generic client_surface return type. The pixel format is unused by the
     * macdrv implementation, so 0 keeps the old behaviour; raw (added in
     * 11.17) stays FALSE, as for win32u's Vulkan surfaces. */
    struct client_surface *client = macdrv_CreateClientSurface(hwnd, 0, FALSE);
    struct macdrv_client_surface *surface = client ? impl_from_client_surface(client) : NULL;

    /* get_win_data must follow create_surface or the win_data lock
     * conflicts with the surface-create path. */
    struct macdrv_win_data *real = get_win_data(hwnd);
    if (!real)
    {
        if (surface) client_surface_release(&surface->client);
        return NULL;
    }

    struct mnc_pe_win_data *buf = &mnc_pe_win_data_scratch;
    memset(buf, 0, sizeof(*buf));
    buf->hwnd              = real->hwnd;
    buf->cocoa_window      = real->cocoa_window;
    buf->window_rect       = real->rects.window;
    buf->whole_rect        = real->rects.visible;
    buf->client_rect       = real->rects.client;
    buf->pixel_format      = real->pixel_format;
    buf->drag_event        = real->drag_event;
    HWND hwnd_copy         = real->hwnd;
    release_win_data(real);

    if (surface && surface->cocoa_view)
    {
        /* Hand GPTK the dedicated swap-chain view at +24. */
        buf->cocoa_view        = surface->cocoa_view;
        buf->client_cocoa_view = surface->cocoa_view;
        /* Tag the view with the client_surface pointer so
         * MNCMetalLayer -nextDrawable can find it. */
        macdrv_set_view_d3dmetal_client_surface(surface->cocoa_view,
                                                &surface->client);
    }
    else
    {
        /* Fallback: no surface — keep the content view path so
         * legacy callers (notepad, vconsole2 wined3d path) don't
         * regress. They won't get present-notifications, which is
         * fine because they don't use D3DMetal. */
        macdrv_view content = mnc_d3dmetal_get_content_view(hwnd_copy);
        buf->cocoa_view        = content;
        buf->client_cocoa_view = content;
    }
    return (struct macdrv_win_data *)buf;
}

static void mnc_bridge_release_win_data(struct macdrv_win_data *data)
{
    /* No real lock was held past mnc_bridge_get_win_data return. The
     * caller's pointer is into thread-local storage so there's nothing
     * to free or unlock. The client_surface reference is intentionally
     * not released here — see MNC HACK 14 comment in get_win_data. */
    (void)data;
}

static WCHAR *strdupAtoW(LPCSTR str, ULONG *bytes)
{
    size_t len = str ? strlen(str) : 0;
    WCHAR *ret = malloc((len + 1) * sizeof(*ret));

    if (!ret) return NULL;
    ascii_to_unicode(ret, str ? str : "", len);
    ret[len] = 0;
    if (bytes) *bytes = len * sizeof(*ret);
    return ret;
}

static HKEY open_registry_root_ascii(const char *path)
{
    ULONG bytes;
    WCHAR *pathW = strdupAtoW(path, &bytes);
    HKEY ret = pathW ? reg_open_key(NULL, pathW, bytes) : 0;

    free(pathW);
    return ret;
}

static HKEY open_current_user_root(void)
{
    char buffer[256];
    WCHAR bufferW[256];
    DWORD_PTR sid_data[(sizeof(TOKEN_USER) + SECURITY_MAX_SID_SIZE) / sizeof(DWORD_PTR)];
    DWORD i, len = sizeof(sid_data);
    SID *sid;

    if (NtQueryInformationToken(GetCurrentThreadEffectiveToken(), TokenUser, sid_data, len, &len))
        return 0;

    sid = ((TOKEN_USER *)sid_data)->User.Sid;
    len = snprintf(buffer, sizeof(buffer), "\\Registry\\User\\S-%u-%u", sid->Revision,
                   MAKELONG(MAKEWORD(sid->IdentifierAuthority.Value[5],
                                      sid->IdentifierAuthority.Value[4]),
                             MAKEWORD(sid->IdentifierAuthority.Value[3],
                                      sid->IdentifierAuthority.Value[2])));
    for (i = 0; i < sid->SubAuthorityCount; i++)
        len += snprintf(buffer + len, sizeof(buffer) - len, "-%u", sid->SubAuthority[i]);

    ascii_to_unicode(bufferW, buffer, len);
    return reg_open_key(NULL, bufferW, len * sizeof(WCHAR));
}

static HKEY resolve_registry_root(HKEY hkey, BOOL *close_root)
{
    *close_root = TRUE;

    if (hkey == HKEY_CURRENT_USER) return open_current_user_root();
    if (hkey == HKEY_LOCAL_MACHINE) return open_registry_root_ascii("\\Registry\\Machine");
    if (hkey == HKEY_CLASSES_ROOT) return open_registry_root_ascii("\\Registry\\Machine\\Software\\Classes");
    if (hkey == HKEY_USERS) return open_registry_root_ascii("\\Registry\\User");
    if (hkey == HKEY_CURRENT_CONFIG)
        return open_registry_root_ascii("\\Registry\\Machine\\System\\CurrentControlSet\\Hardware Profiles\\Current");

    *close_root = FALSE;
    if ((LONG_PTR)hkey < 0) return 0;
    return hkey;
}

static LSTATUS close_if_needed(HKEY hkey, BOOL close_key)
{
    if (!close_key || !hkey) return ERROR_SUCCESS;
    return RtlNtStatusToDosError(NtClose(hkey));
}

static LSTATUS WINAPI bridge_RegOpenKeyExA(HKEY hkey, LPCSTR name, DWORD options, REGSAM access, HKEY *retkey)
{
    BOOL close_root;
    HKEY root, key;
    WCHAR *nameW;
    ULONG name_len;

    TRACE("%p %s %#x %#x %p\n", hkey, debugstr_a(name), options, access, retkey);

    if (!retkey) return ERROR_INVALID_PARAMETER;
    *retkey = 0;
    if (!(root = resolve_registry_root(hkey, &close_root))) return ERROR_INVALID_HANDLE;
    if (!(nameW = strdupAtoW(name, &name_len)))
    {
        close_if_needed(root, close_root);
        return ERROR_OUTOFMEMORY;
    }

    key = reg_open_key(root, nameW, name_len);
    free(nameW);
    close_if_needed(root, close_root);
    if (!key) return ERROR_FILE_NOT_FOUND;

    *retkey = key;
    return ERROR_SUCCESS;
}

static LSTATUS WINAPI bridge_RegCreateKeyExA(HKEY hkey, LPCSTR name, DWORD reserved, LPSTR class,
                                             DWORD options, REGSAM access, LPSECURITY_ATTRIBUTES sa,
                                             HKEY *retkey, LPDWORD disposition)
{
    BOOL close_root;
    HKEY root, key;
    WCHAR *nameW;
    ULONG name_len;

    TRACE("%p %s %#x %#x %p %p\n", hkey, debugstr_a(name), options, access, retkey, disposition);

    if (!retkey) return ERROR_INVALID_PARAMETER;
    *retkey = 0;
    if (disposition) *disposition = 0;
    if (!(root = resolve_registry_root(hkey, &close_root))) return ERROR_INVALID_HANDLE;
    if (!(nameW = strdupAtoW(name, &name_len)))
    {
        close_if_needed(root, close_root);
        return ERROR_OUTOFMEMORY;
    }

    key = reg_create_key(root, nameW, name_len, options, disposition);
    free(nameW);
    close_if_needed(root, close_root);
    if (!key) return ERROR_FILE_NOT_FOUND;

    *retkey = key;
    return ERROR_SUCCESS;
}

static LSTATUS WINAPI bridge_RegCloseKey(HKEY hkey)
{
    TRACE("%p\n", hkey);

    if (!hkey) return ERROR_INVALID_HANDLE;
    if ((LONG_PTR)hkey < 0) return ERROR_SUCCESS;
    return RtlNtStatusToDosError(NtClose(hkey));
}

static BYTE *copy_registry_data_a(DWORD type, const BYTE *data, DWORD len, DWORD *out_len)
{
    BYTE *ret;

    *out_len = len;
    if ((type == REG_SZ || type == REG_EXPAND_SZ || type == REG_MULTI_SZ) && len >= sizeof(WCHAR))
    {
        DWORD converted_len = 0;
        ret = malloc(len);
        if (ret && !RtlUnicodeToUTF8N((char *)ret, len, &converted_len, (const WCHAR *)data, len))
        {
            *out_len = converted_len;
            return ret;
        }
        free(ret);
    }

    ret = malloc(len ? len : 1);
    if (ret && len) memcpy(ret, data, len);
    return ret;
}

static LSTATUS WINAPI bridge_RegQueryValueExA(HKEY hkey, LPCSTR name, LPDWORD reserved,
                                              LPDWORD type, BYTE *data, LPDWORD count)
{
    BOOL close_key;
    HKEY key;
    WCHAR *nameW;
    UNICODE_STRING nameU;
    KEY_VALUE_PARTIAL_INFORMATION *info;
    DWORD size = 512, needed = 0, out_len = 0;
    NTSTATUS status;
    BYTE *out;

    TRACE("%p %s %p %p %p %p\n", hkey, debugstr_a(name), reserved, type, data, count);

    if (reserved) *reserved = 0;
    if (data && !count) return ERROR_INVALID_PARAMETER;
    if (!(key = resolve_registry_root(hkey, &close_key))) return ERROR_INVALID_HANDLE;
    if (!(nameW = strdupAtoW(name, NULL)))
    {
        close_if_needed(key, close_key);
        return ERROR_OUTOFMEMORY;
    }

    RtlInitUnicodeString(&nameU, nameW);
    if (!(info = malloc(size)))
    {
        free(nameW);
        close_if_needed(key, close_key);
        return ERROR_OUTOFMEMORY;
    }

    status = NtQueryValueKey(key, &nameU, KeyValuePartialInformation, info, size, &needed);
    if (status == STATUS_BUFFER_TOO_SMALL || status == STATUS_BUFFER_OVERFLOW)
    {
        KEY_VALUE_PARTIAL_INFORMATION *new_info;
        size = needed;
        new_info = realloc(info, size);
        if (!new_info)
        {
            free(info);
            free(nameW);
            close_if_needed(key, close_key);
            return ERROR_OUTOFMEMORY;
        }
        info = new_info;
        status = NtQueryValueKey(key, &nameU, KeyValuePartialInformation, info, size, &needed);
    }
    free(nameW);
    close_if_needed(key, close_key);
    if (status)
    {
        free(info);
        return RtlNtStatusToDosError(status);
    }

    if (type) *type = info->Type;
    out = copy_registry_data_a(info->Type, info->Data, info->DataLength, &out_len);
    if (!out)
    {
        free(info);
        return ERROR_OUTOFMEMORY;
    }

    if (count)
    {
        if (!data)
            *count = out_len;
        else if (*count < out_len)
        {
            *count = out_len;
            free(out);
            free(info);
            return ERROR_MORE_DATA;
        }
        else
        {
            memcpy(data, out, out_len);
            *count = out_len;
        }
    }

    free(out);
    free(info);
    return ERROR_SUCCESS;
}

static BYTE *copy_registry_data_w(DWORD type, const BYTE *data, DWORD len, DWORD *out_len)
{
    BYTE *ret;

    *out_len = len;
    if ((type == REG_SZ || type == REG_EXPAND_SZ || type == REG_MULTI_SZ) && data && len)
    {
        DWORD converted_len = (len + 1) * sizeof(WCHAR);
        ret = malloc(converted_len);
        if (ret && !RtlUTF8ToUnicodeN((WCHAR *)ret, converted_len, out_len, (const char *)data, len))
            return ret;
        free(ret);
    }

    ret = malloc(len ? len : 1);
    if (ret && len) memcpy(ret, data, len);
    return ret;
}

static LSTATUS WINAPI bridge_RegSetValueExA(HKEY hkey, LPCSTR name, DWORD reserved,
                                            DWORD type, const BYTE *data, DWORD count)
{
    BOOL close_key;
    HKEY key;
    WCHAR *nameW;
    UNICODE_STRING nameU;
    BYTE *value_data;
    DWORD value_len;
    NTSTATUS status;

    TRACE("%p %s %#x %p %u\n", hkey, debugstr_a(name), type, data, count);

    if (!(key = resolve_registry_root(hkey, &close_key))) return ERROR_INVALID_HANDLE;
    if (!(nameW = strdupAtoW(name, NULL)))
    {
        close_if_needed(key, close_key);
        return ERROR_OUTOFMEMORY;
    }
    if (!(value_data = copy_registry_data_w(type, data, count, &value_len)))
    {
        free(nameW);
        close_if_needed(key, close_key);
        return ERROR_OUTOFMEMORY;
    }

    RtlInitUnicodeString(&nameU, nameW);
    status = NtSetValueKey(key, &nameU, 0, type, value_data, value_len);
    free(value_data);
    free(nameW);
    close_if_needed(key, close_key);
    return RtlNtStatusToDosError(status);
}

static void bridge_refresh_display_devices(BOOL force)
{
    DISPLAY_DEVICEW device;
    NTSTATUS status;

    TRACE("%d\n", force);
    macdrv_reset_device_metrics();

    memset(&device, 0, sizeof(device));
    device.cb = sizeof(device);
    status = NtUserEnumDisplayDevices(NULL, 0, &device, 0);
    fprintf(stderr, "[D3DMETAL_BRIDGE] refresh_display_devices force=%d enum_status=%#lx flags=%#lx name=%s\n",
            force, (unsigned long)status, (unsigned long)device.StateFlags, wine_dbgstr_w(device.DeviceName));
    fflush(stderr);
}

static void bridge_OnMainThread(dispatch_block_t block)
{
    TRACE("%p\n", block);
    OnMainThread(block);
}

static BOOL WINAPI bridge_GetMonitorInfoA(HMONITOR monitor, LPMONITORINFO info)
{
    MONITORINFOEXW infoW;
    BOOL ret;

    TRACE("%p %p\n", monitor, info);

    if (info->cbSize == sizeof(MONITORINFO)) return NtUserGetMonitorInfo(monitor, info);
    if (info->cbSize != sizeof(MONITORINFOEXA)) return FALSE;

    infoW.cbSize = sizeof(infoW);
    ret = NtUserGetMonitorInfo(monitor, (MONITORINFO *)&infoW);
    if (ret)
    {
        MONITORINFOEXA *infoA = (MONITORINFOEXA *)info;
        DWORD len = 0;

        infoA->rcMonitor = infoW.rcMonitor;
        infoA->rcWork = infoW.rcWork;
        infoA->dwFlags = infoW.dwFlags;
        RtlUnicodeToUTF8N(infoA->szDevice, sizeof(infoA->szDevice) - 1, &len,
                          infoW.szDevice, lstrlenW(infoW.szDevice) * sizeof(WCHAR));
        infoA->szDevice[min(len, sizeof(infoA->szDevice) - 1)] = 0;
    }
    return ret;
}

static BOOL WINAPI bridge_AdjustWindowRectEx(LPRECT rect, DWORD style, BOOL menu, DWORD ex_style)
{
    TRACE("%p %#x %d %#x\n", rect, style, menu, ex_style);
    return NtUserAdjustWindowRect(rect, style, menu, ex_style, NtUserGetSystemDpiForProcess(NULL));
}

static BOOL WINAPI bridge_GetWindowRect(HWND hwnd, LPRECT rect)
{
    TRACE("%p %p\n", hwnd, rect);
    return NtUserGetWindowRect(hwnd, rect, NtUserGetSystemDpiForProcess(NULL));
}

static LONG_PTR WINAPI bridge_SetWindowLongPtrW(HWND hwnd, INT offset, LONG_PTR newval)
{
    TRACE("%p %d %#lx\n", hwnd, offset, newval);
    return NtUserSetWindowLongPtr(hwnd, offset, newval, FALSE);
}

__attribute__((visibility("default"), used))
struct d3dmetal_macdrv_exports macdrv_functions =
{
    bridge_refresh_display_devices,
    /* MNC HACK 9: route win-data fetches through the layout-compatibility
     * shim so GPTK PE DLLs see the WineContentView at offset 24. */
    mnc_bridge_get_win_data,
    mnc_bridge_release_win_data,
    macdrv_get_cocoa_window,
    macdrv_create_metal_device,
    macdrv_release_metal_device,
    macdrv_view_create_metal_view,
    macdrv_view_get_metal_layer,
    macdrv_view_release_metal_view,
    bridge_OnMainThread,
    bridge_RegQueryValueExA,
    bridge_RegSetValueExA,
    bridge_RegOpenKeyExA,
    bridge_RegCreateKeyExA,
    bridge_RegCloseKey,
    NtUserEnumDisplayMonitors,
    bridge_GetMonitorInfoA,
    bridge_AdjustWindowRectEx,
    NtUserGetWindowLongPtrW,
    bridge_GetWindowRect,
    NtUserMoveWindow,
    NtUserSetWindowPos,
    NtUserGetSystemMetrics,
    bridge_SetWindowLongPtrW,
};

#endif /* defined(__x86_64__) */
