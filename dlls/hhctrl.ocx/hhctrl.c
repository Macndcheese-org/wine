/*
 * hhctrl implementation
 *
 * Copyright 2004 Krzysztof Foltman
 * Copyright 2007 Jacek Caban for CodeWeavers
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Lesser General Public
 * License as published by the Free Software Foundation; either
 * version 2.1 of the License, or (at your option) any later version.
 *
 * This library is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
 * Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public
 * License along with this library; if not, write to the Free Software
 * Foundation, Inc., 51 Franklin St, Fifth Floor, Boston, MA 02110-1301, USA
 */

#include "wine/debug.h"

#include <stdarg.h>

#define COBJMACROS

#include "windef.h"
#include "winbase.h"
#include "winuser.h"
#include "winnls.h"
#include "htmlhelp.h"
#include "ole2.h"
#include "rpcproxy.h"

#define INIT_GUID
#include "hhctrl.h"

WINE_DEFAULT_DEBUG_CHANNEL(htmlhelp);

HINSTANCE hhctrl_hinstance;
BOOL hh_process = FALSE;


BOOL WINAPI DllMain(HINSTANCE hInstance, DWORD fdwReason, LPVOID lpvReserved)
{
    TRACE("(%p,%ld,%p)\n", hInstance, fdwReason, lpvReserved);

    switch (fdwReason)
    {
    case DLL_PROCESS_ATTACH:
        hhctrl_hinstance = hInstance;
        DisableThreadLibraryCalls(hInstance);
        break;
    }
    return TRUE;
}

static const char *command_to_string(UINT command)
{
#define X(x) case x: return #x
    switch (command)
    {
        X( HH_DISPLAY_TOPIC );
        X( HH_DISPLAY_TOC );
        X( HH_DISPLAY_INDEX );
        X( HH_DISPLAY_SEARCH );
        X( HH_SET_WIN_TYPE );
        X( HH_GET_WIN_TYPE );
        X( HH_GET_WIN_HANDLE );
        X( HH_ENUM_INFO_TYPE );
        X( HH_SET_INFO_TYPE );
        X( HH_SYNC );
        X( HH_RESERVED1 );
        X( HH_RESERVED2 );
        X( HH_RESERVED3 );
        X( HH_KEYWORD_LOOKUP );
        X( HH_DISPLAY_TEXT_POPUP );
        X( HH_HELP_CONTEXT );
        X( HH_TP_HELP_CONTEXTMENU );
        X( HH_TP_HELP_WM_HELP );
        X( HH_CLOSE_ALL );
        X( HH_ALINK_LOOKUP );
        X( HH_GET_LAST_ERROR );
        X( HH_ENUM_CATEGORY );
        X( HH_ENUM_CATEGORY_IT );
        X( HH_RESET_IT_FILTER );
        X( HH_SET_INCLUSIVE_FILTER );
        X( HH_SET_EXCLUSIVE_FILTER );
        X( HH_INITIALIZE );
        X( HH_UNINITIALIZE );
        X( HH_SAFE_DISPLAY_TOPIC );
        X( HH_PRETRANSLATEMESSAGE );
        X( HH_SET_GLOBAL_PROPERTY );
    default: return "???";
    }
#undef X
}

static BOOL resolve_filename(const WCHAR *env_filename, WCHAR *fullname, DWORD buflen, WCHAR **index, WCHAR **window)
{
    DWORD env_len;
    WCHAR *filename, *extra;

    env_filename = skip_schema(env_filename);

    /* the format is "helpFile[::/index][>window]" */
    if (index) *index = NULL;
    if (window) *window = NULL;

    env_len = ExpandEnvironmentStringsW(env_filename, NULL, 0);
    if (!env_len)
        return 0;

    filename = malloc(env_len * sizeof(WCHAR));
    if (filename == NULL)
        return 0;

    ExpandEnvironmentStringsW(env_filename, filename, env_len);

    extra = wcschr(filename, '>');
    if (extra)
    {
        *extra = 0;
        if (window)
            *window = wcsdup(extra + 1);
    }

    extra = wcsstr(filename, L"::");
    if (extra)
    {
        *extra = 0;
        if (index)
            *index = wcsdup(extra + 2);
    }

    GetFullPathNameW(filename, buflen, fullname, NULL);
    if (GetFileAttributesW(fullname) == INVALID_FILE_ATTRIBUTES)
    {
        GetWindowsDirectoryW(fullname, buflen);
        lstrcatW(fullname, L"\\help\\");
        lstrcatW(fullname, filename);
    }

    free(filename);

    if (GetFileAttributesW(fullname) == INVALID_FILE_ATTRIBUTES)
    {
        if (window) free(*window);
        if (index) free(*index);
        return FALSE;
    }

    return TRUE;
}

static HWND html_help_w(HWND caller, LPCWSTR filename, UINT command, DWORD_PTR data)
{
    WCHAR fullname[MAX_PATH];

    TRACE("(%p, %s, command=%s, data=%Ix)\n",
          caller, debugstr_w( filename ),
          command_to_string( command ), data);

    switch (command)
    {
    case HH_DISPLAY_TOPIC:
    case HH_DISPLAY_TOC:
    case HH_DISPLAY_INDEX:
    case HH_DISPLAY_SEARCH:{
        BOOL res;
        NMHDR nmhdr;
        HHInfo *info = NULL;
        WCHAR *window = NULL;
        const WCHAR *index = NULL;
        WCHAR *default_index = NULL;
        int tab_index = TAB_CONTENTS;

        if (!filename)
            return NULL;

        if (!resolve_filename(filename, fullname, MAX_PATH, &default_index, &window))
        {
            WARN("can't find %s\n", debugstr_w(filename));
            return 0;
        }
        index = default_index;

        if (window)
            info = find_window(window);

        info = CreateHelpViewer(info, fullname, caller);
        if(!info)
        {
            free(default_index);
            free(window);
            return NULL;
        }

        if(!index)
            index = info->WinType.pszFile;
        if(!info->WinType.pszType)
            info->WinType.pszType = info->stringsW.pszType = window;
        else
            free(window);

        /* called to load a specified topic */
        switch(command)
        {
        case HH_DISPLAY_TOPIC:
        case HH_DISPLAY_TOC:
            if (data)
            {
                static const WCHAR delimW[] = {':',':',0};
                const WCHAR *i = (const WCHAR *)data;

                index = wcsstr(i, delimW);
                if(index)
                {
                    if(memcmp(info->pCHMInfo->szFile, i, index-i))
                        FIXME("Opening a CHM file in the context of another is not supported.\n");
                    index += lstrlenW(delimW);
                }
                else
                    index = i;
            }
            break;
        }

        res = NavigateToChm(info, info->pCHMInfo->szFile, index);
        free(default_index);

        if(!res)
        {
            ReleaseHelpViewer(info);
            return NULL;
        }

        switch(command)
        {
        case HH_DISPLAY_TOPIC:
        case HH_DISPLAY_TOC:
            tab_index = TAB_CONTENTS;
            break;
        case HH_DISPLAY_INDEX:
            tab_index = TAB_INDEX;
            if (data)
                FIXME("Should select keyword '%s'.\n", debugstr_w((WCHAR *)data));
            break;
        case HH_DISPLAY_SEARCH:
            tab_index = TAB_SEARCH;
            if (data)
                FIXME("Should display search specified by HH_FTS_QUERY structure.\n");
            break;
        }
        /* open the requested tab */
        memset(&nmhdr, 0, sizeof(nmhdr));
        nmhdr.code = TCN_SELCHANGE;
        SendMessageW(info->hwndTabCtrl, TCM_SETCURSEL, (WPARAM)info->tabs[tab_index].id, 0);
        SendMessageW(info->WinType.hwndNavigation, WM_NOTIFY, 0, (LPARAM)&nmhdr);

        return info->WinType.hwndHelp;
    }
    case HH_HELP_CONTEXT: {
        WCHAR *window = NULL;
        HHInfo *info = NULL;
        LPWSTR url;

        if (!filename)
            return NULL;

        if (!resolve_filename(filename, fullname, MAX_PATH, NULL, &window))
        {
            WARN("can't find %s\n", debugstr_w(filename));
            return 0;
        }

        if (window)
            info = find_window(window);

        info = CreateHelpViewer(info, fullname, caller);
        if(!info)
        {
            free(window);
            return NULL;
        }

        if(!info->WinType.pszType)
            info->WinType.pszType = info->stringsW.pszType = window;
        else
            free(window);

        url = FindContextAlias(info->pCHMInfo, data);
        if(!url)
        {
            if(!data) /* there may legitimately be no context alias for id 0 */
                return info->WinType.hwndHelp;
            ReleaseHelpViewer(info);
            return NULL;
        }

        NavigateToUrl(info, url);
        free(url);
        return info->WinType.hwndHelp;
    }
    case HH_PRETRANSLATEMESSAGE: {
        static BOOL warned = FALSE;

        if (!warned)
        {
            FIXME("HH_PRETRANSLATEMESSAGE unimplemented\n");
            warned = TRUE;
        }
        return 0;
    }
    case HH_CLOSE_ALL: {
        HHInfo *info, *next;

        LIST_FOR_EACH_ENTRY_SAFE(info, next, &window_list, HHInfo, entry)
        {
            TRACE("Destroying window %s.\n", debugstr_w(info->WinType.pszType));
            ReleaseHelpViewer(info);
        }
        return 0;
    }
    case HH_SET_WIN_TYPE: {
        HH_WINTYPEW *wintype = (HH_WINTYPEW *)data;
        WCHAR *window = NULL;
        HHInfo *info = NULL;

        if (!filename && wintype->pszType)
            window = wcsdup(wintype->pszType);
        else if (!filename || !resolve_filename(filename, fullname, MAX_PATH, NULL, &window) || !window)
        {
            WARN("can't find window name: %s\n", debugstr_w(filename));
            return 0;
        }
        info = find_window(window);
        if (!info)
        {
            info = calloc(1, sizeof(HHInfo));
            info->WinType.pszType = info->stringsW.pszType = window;
            list_add_tail(&window_list, &info->entry);
        }
        else
            free(window);

        TRACE("Changing WINTYPE, fsValidMembers=0x%lx\n", wintype->fsValidMembers);

        MergeChmProperties(wintype, info, TRUE);
        UpdateHelpWindow(info);
        return 0;
    }
    case HH_GET_WIN_TYPE: {
        HH_WINTYPEW *wintype = (HH_WINTYPEW *)data;
        WCHAR *window = NULL;
        HHInfo *info = NULL;

        if (!filename || !resolve_filename(filename, fullname, MAX_PATH, NULL, &window) || !window)
        {
            WARN("can't find window name: %s\n", debugstr_w(filename));
            return 0;
        }
        info = find_window(window);
        if (!info)
        {
            WARN("Could not find window named %s.\n", debugstr_w(window));
            free(window);
            return (HWND)~0;
        }

        TRACE("Retrieving WINTYPE for %s.\n", debugstr_w(window));
        *wintype = info->WinType;
        free(window);
        return 0;
    }
    case HH_INITIALIZE:
        /* Return a non-zero cookie that is later passed back to
         * HH_UNINITIALIZE.  Applications check this value and treat a NULL
         * cookie as an initialization failure. */
        if (data)
            *(DWORD *)data = 1;
        return 0;
    case HH_UNINITIALIZE:
        return 0;
    default:
        FIXME("HH case %s not handled.\n", command_to_string( command ));
    }

    return 0;
}

static void wintypeAtoW(const HH_WINTYPEA *data, HH_WINTYPEW *wdata, struct wintype_stringsW *stringsW)
{
    memcpy(wdata, data, sizeof(*data));
    /* convert all of the ANSI strings to Unicode */
    wdata->pszType       = stringsW->pszType       = strdupAtoW(data->pszType);
    wdata->pszCaption    = stringsW->pszCaption    = strdupAtoW(data->pszCaption);
    wdata->pszToc        = stringsW->pszToc        = strdupAtoW(data->pszToc);
    wdata->pszIndex      = stringsW->pszIndex      = strdupAtoW(data->pszIndex);
    wdata->pszFile       = stringsW->pszFile       = strdupAtoW(data->pszFile);
    wdata->pszHome       = stringsW->pszHome       = strdupAtoW(data->pszHome);
    wdata->pszJump1      = stringsW->pszJump1      = strdupAtoW(data->pszJump1);
    wdata->pszJump2      = stringsW->pszJump2      = strdupAtoW(data->pszJump2);
    wdata->pszUrlJump1   = stringsW->pszUrlJump1   = strdupAtoW(data->pszUrlJump1);
    wdata->pszUrlJump2   = stringsW->pszUrlJump2   = strdupAtoW(data->pszUrlJump2);
    wdata->pszCustomTabs = stringsW->pszCustomTabs = strdupAtoW(data->pszCustomTabs);
}

static void wintypeWtoA(const HH_WINTYPEW *wdata, HH_WINTYPEA *data, struct wintype_stringsA *stringsA)
{
    memcpy(data, wdata, sizeof(*wdata));
    /* convert all of the Unicode strings to ANSI */
    data->pszType       = stringsA->pszType       = strdupWtoA(wdata->pszType);
    data->pszCaption    = stringsA->pszCaption    = strdupWtoA(wdata->pszCaption);
    data->pszToc        = stringsA->pszToc        = strdupWtoA(wdata->pszToc);
    data->pszIndex      = stringsA->pszFile       = strdupWtoA(wdata->pszIndex);
    data->pszFile       = stringsA->pszFile       = strdupWtoA(wdata->pszFile);
    data->pszHome       = stringsA->pszHome       = strdupWtoA(wdata->pszHome);
    data->pszJump1      = stringsA->pszJump1      = strdupWtoA(wdata->pszJump1);
    data->pszJump2      = stringsA->pszJump2      = strdupWtoA(wdata->pszJump2);
    data->pszUrlJump1   = stringsA->pszUrlJump1   = strdupWtoA(wdata->pszUrlJump1);
    data->pszUrlJump2   = stringsA->pszUrlJump2   = strdupWtoA(wdata->pszUrlJump2);
    data->pszCustomTabs = stringsA->pszCustomTabs = strdupWtoA(wdata->pszCustomTabs);
}

static HWND html_help_a(HWND caller, LPCSTR filename, UINT command, DWORD_PTR data)
{
    WCHAR *wfile = strdupAtoW( filename );
    HWND result = 0;

    if (data)
    {
        switch(command)
        {
        case HH_ALINK_LOOKUP:
        case HH_DISPLAY_SEARCH:
        case HH_DISPLAY_TEXT_POPUP:
        case HH_GET_LAST_ERROR:
        case HH_KEYWORD_LOOKUP:
        case HH_SYNC:
            FIXME("structures not handled yet\n");
            break;

        case HH_SET_WIN_TYPE:
        {
            struct wintype_stringsW stringsW;
            HH_WINTYPEW wdata;

            wintypeAtoW((HH_WINTYPEA *)data, &wdata, &stringsW);
            result = html_help_w( caller, wfile, command, (DWORD_PTR)&wdata );
            wintype_stringsW_free(&stringsW);
            goto done;
        }
        case HH_GET_WIN_TYPE:
        {
            HH_WINTYPEW wdata;
            HHInfo *info;

            result = html_help_w( caller, wfile, command, (DWORD_PTR)&wdata );
            if (!wdata.pszType) break;
            info = find_window(wdata.pszType);
            if (!info) break;
            wintype_stringsA_free(&info->stringsA);
            wintypeWtoA(&wdata, (HH_WINTYPEA *)data, &info->stringsA);
            goto done;
        }

        case HH_DISPLAY_INDEX:
        case HH_DISPLAY_TOPIC:
        case HH_DISPLAY_TOC:
        case HH_GET_WIN_HANDLE:
        case HH_SAFE_DISPLAY_TOPIC:
        {
            WCHAR *wdata = strdupAtoW( (const char *)data );
            result = html_help_w( caller, wfile, command, (DWORD_PTR)wdata );
            free(wdata);
            goto done;
        }

        case HH_CLOSE_ALL:
        case HH_HELP_CONTEXT:
        case HH_INITIALIZE:
        case HH_PRETRANSLATEMESSAGE:
        case HH_TP_HELP_CONTEXTMENU:
        case HH_TP_HELP_WM_HELP:
        case HH_UNINITIALIZE:
            /* either scalar or pointer to scalar - do nothing */
            break;

        default:
            FIXME("Unknown command: %s (%d)\n", command_to_string(command), command);
            break;
        }
    }

    result = html_help_w( caller, wfile, command, data );
done:
    free(wfile);
    return result;
}

/* The viewer runs in a thread of its own, as it does on Windows unless the
 * application asks for it to run in the thread that calls HtmlHelp, and its
 * windows are served by that thread's message loop. Running them in the
 * thread of the application leaves their keyboard input to the message loop
 * of the application, which knows nothing of them. */
#define WM_HH_CALL (WM_USER + 1)

struct html_help_call
{
    HWND caller;
    const void *filename;
    UINT command;
    DWORD_PTR data;
    BOOL unicode;
    HWND result;
};

static HWND hh_thread_window;
static INIT_ONCE hh_thread_once = INIT_ONCE_STATIC_INIT;

static void call_html_help(struct html_help_call *call)
{
    if (call->unicode)
        call->result = html_help_w(call->caller, call->filename, call->command, call->data);
    else
        call->result = html_help_a(call->caller, call->filename, call->command, call->data);
}

static LRESULT CALLBACK hh_thread_wndproc(HWND hwnd, UINT message, WPARAM wparam, LPARAM lparam)
{
    if (message != WM_HH_CALL)
        return DefWindowProcW(hwnd, message, wparam, lparam);

    call_html_help((struct html_help_call *)lparam);
    return 0;
}

static DWORD WINAPI hh_thread_proc(void *param)
{
    HANDLE ready = param;
    WNDCLASSW wc = {0};
    MSG msg;

    wc.lpfnWndProc = hh_thread_wndproc;
    wc.hInstance = hhctrl_hinstance;
    wc.lpszClassName = L"HH Thread";
    RegisterClassW(&wc);
    hh_thread_window = CreateWindowW(wc.lpszClassName, NULL, 0, 0, 0, 0, 0, HWND_MESSAGE,
                                     NULL, hhctrl_hinstance, NULL);
    SetEvent(ready);

    while (hh_thread_window && GetMessageW(&msg, NULL, 0, 0))
    {
        TranslateMessage(&msg);
        DispatchMessageW(&msg);
    }
    return 0;
}

static BOOL CALLBACK start_hh_thread(INIT_ONCE *once, void *param, void **context)
{
    HANDLE ready = CreateEventW(NULL, FALSE, FALSE, NULL), thread;
    HMODULE module;

    /* the thread outlives any call, so keep its code loaded */
    GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_PIN,
                       (const WCHAR *)hh_thread_proc, &module);
    if ((thread = CreateThread(NULL, 0, hh_thread_proc, ready, 0, NULL)))
    {
        WaitForSingleObject(ready, INFINITE);
        CloseHandle(thread);
    }
    CloseHandle(ready);
    return TRUE;
}

static HWND html_help(HWND caller, const void *filename, UINT command, DWORD_PTR data, BOOL unicode)
{
    struct html_help_call call = { caller, filename, command, data, unicode };

    /* hh.exe is the process of the viewer, and its message loop serves the windows */
    if (!hh_process)
        InitOnceExecuteOnce(&hh_thread_once, start_hh_thread, NULL, NULL);

    if (hh_thread_window)
        SendMessageW(hh_thread_window, WM_HH_CALL, 0, (LPARAM)&call);
    else
        call_html_help(&call);
    return call.result;
}

/******************************************************************
 *		HtmlHelpA (HHCTRL.OCX.14)
 */
HWND WINAPI HtmlHelpA(HWND caller, LPCSTR filename, UINT command, DWORD_PTR data)
{
    return html_help(caller, filename, command, data, FALSE);
}

/******************************************************************
 *		HtmlHelpW (HHCTRL.OCX.15)
 */
HWND WINAPI HtmlHelpW(HWND caller, LPCWSTR filename, UINT command, DWORD_PTR data)
{
    return html_help(caller, filename, command, data, TRUE);
}

/******************************************************************
 *		doWinMain (HHCTRL.OCX.13)
 */
int WINAPI doWinMain(HINSTANCE hInstance, LPSTR szCmdLine)
{
    MSG msg;
    int len, buflen, mapid = -1;
    WCHAR *filename;
    char *endq = NULL;
    HWND hwnd;

    hh_process = TRUE;

    /* Parse command line option of the HTML Help command.
     *
     * Note: The only currently handled action is "mapid",
     *  which corresponds to opening a specific page.
     */
    while(*szCmdLine == '-')
    {
        LPSTR space, ptr;

        ptr = szCmdLine + 1;
        space = strchr(ptr, ' ');
        if(!strncmp(ptr, "mapid", space-ptr))
        {
            char idtxt[10];

            ptr += strlen("mapid")+1;
            space = strchr(ptr, ' ');
            /* command line ends without number */
            if (!space)
                return 0;
            memcpy(idtxt, ptr, space-ptr);
            idtxt[space-ptr] = '\0';
            mapid = atoi(idtxt);
            szCmdLine = space+1;
        }
        else
        {
            FIXME("Unhandled HTML Help command line parameter! (%.*s)\n", (int)(space-szCmdLine), szCmdLine);
            return 0;
        }
    }

    /* FIXME: Check szCmdLine for bad arguments */
    if (*szCmdLine == '\"')
        endq = strchr(++szCmdLine, '\"');

    if (endq)
        len = endq - szCmdLine;
    else
        len = strlen(szCmdLine);

    /* no filename given */
    if (!len)
        return 0;

    buflen = MultiByteToWideChar(CP_ACP, 0, szCmdLine, len, NULL, 0) + 1;
    filename = malloc(buflen * sizeof(WCHAR));
    MultiByteToWideChar(CP_ACP, 0, szCmdLine, len, filename, buflen);
    filename[buflen-1] = 0;

    /* Open a specific help topic */
    if(mapid != -1)
        hwnd = HtmlHelpW(GetDesktopWindow(), filename, HH_HELP_CONTEXT, mapid);
    else
        hwnd = HtmlHelpW(GetDesktopWindow(), filename, HH_DISPLAY_TOPIC, 0);

    free(filename);

    if (!hwnd)
    {
        ERR("Failed to open HTML Help file '%s'.\n", szCmdLine);
        return 0;
    }

    while (GetMessageW(&msg, 0, 0, 0))
    {
        TranslateMessage(&msg);
        DispatchMessageW(&msg);
    }

    return 0;
}

/******************************************************************
 *		DllGetClassObject (HHCTRL.OCX.@)
 */
HRESULT WINAPI DllGetClassObject(REFCLSID rclsid, REFIID riid, LPVOID *ppv)
{
    FIXME("(%s %s %p)\n", debugstr_guid(rclsid), debugstr_guid(riid), ppv);
    return CLASS_E_CLASSNOTAVAILABLE;
}
