/* iOdus d3d11 proxy.
 *
 * GameMaker (and other engines) ask CheckMultisampleQualityLevels for 8 and 16
 * samples at startup. Windows answers S_OK with 0 levels for an unsupported
 * sample count. D3DMetal answers E_INVALIDARG, and GameMaker then shows an
 * error dialog for each call. This DLL loads the real D3DMetal d3d11.dll from
 * the Wine DLL folder, passes all calls to it, and gives each new device a
 * copy of its function table with a fixed CheckMultisampleQualityLevels.
 *
 * D3DMetal keeps its devices and function tables in macOS memory, where
 * VirtualProtect cannot make the shared table writable. The device object is
 * writable, so the device gets its own table. D3DMetal does not check the
 * table address (tested: swap chain, render target view, Present, and
 * QueryInterface for IDXGIDevice and ID3D11Device1 work).
 *
 * Install: system32\d3d11.dll with the DLL override d3d11=native,builtin. */
#include <windows.h>
#include <d3d11.h>

typedef HRESULT (WINAPI *create_device_fn)(IDXGIAdapter *, D3D_DRIVER_TYPE, HMODULE, UINT, const D3D_FEATURE_LEVEL *,
                                           UINT, UINT, ID3D11Device **, D3D_FEATURE_LEVEL *, ID3D11DeviceContext **);
typedef HRESULT (WINAPI *create_device_swapchain_fn)(IDXGIAdapter *, D3D_DRIVER_TYPE, HMODULE, UINT, const D3D_FEATURE_LEVEL *,
                                                     UINT, UINT, const DXGI_SWAP_CHAIN_DESC *, IDXGISwapChain **,
                                                     ID3D11Device **, D3D_FEATURE_LEVEL *, ID3D11DeviceContext **);
typedef HRESULT (WINAPI *on12_fn)(IUnknown *, UINT, const D3D_FEATURE_LEVEL *, UINT, IUnknown *const *, UINT, UINT,
                                  ID3D11Device **, ID3D11DeviceContext **, D3D_FEATURE_LEVEL *);
typedef HRESULT (STDMETHODCALLTYPE *check_msaa_fn)(ID3D11Device *, DXGI_FORMAT, UINT, UINT *);

#define CHECK_MSAA_SLOT 30   /* ID3D11Device::CheckMultisampleQualityLevels */
#define TABLE_SIZE 128       /* Larger than the ID3D11Device5 table. */

static HMODULE real;
static create_device_fn real_create;
static create_device_swapchain_fn real_create_swapchain;
static on12_fn real_on12;
static check_msaa_fn real_check;
static SRWLOCK lock = SRWLOCK_INIT;

/* The real d3d11.dll: $IODUS_REAL_D3D11, or <WINEDLLDIR0>\x86_64-windows\d3d11.dll. */
static BOOL load_real(void)
{
    WCHAR path[MAX_PATH], dir[MAX_PATH];
    BOOL ok;

    AcquireSRWLockExclusive(&lock);
    if (!real)
    {
        if (!GetEnvironmentVariableW(L"IODUS_REAL_D3D11", path, MAX_PATH))
        {
            DWORD len = GetEnvironmentVariableW(L"WINEDLLDIR0", dir, MAX_PATH);
            const WCHAR *start = dir;
            if (!len || len >= MAX_PATH - 32) { ReleaseSRWLockExclusive(&lock); return FALSE; }
            if (!wcsncmp(start, L"\\??\\", 4)) start += 4;
            lstrcpyW(path, start);
            lstrcatW(path, L"\\x86_64-windows\\d3d11.dll");
        }
        if ((real = LoadLibraryW(path)))
        {
            real_create = (create_device_fn)GetProcAddress(real, "D3D11CreateDevice");
            real_create_swapchain = (create_device_swapchain_fn)GetProcAddress(real, "D3D11CreateDeviceAndSwapChain");
            real_on12 = (on12_fn)GetProcAddress(real, "D3D11On12CreateDevice");
        }
    }
    ok = real_create != NULL;
    ReleaseSRWLockExclusive(&lock);
    return ok;
}

static HRESULT STDMETHODCALLTYPE fixed_check(ID3D11Device *device, DXGI_FORMAT format, UINT count, UINT *levels)
{
    HRESULT hr = real_check(device, format, count, levels);
    if (hr == E_INVALIDARG && levels && count >= 2 && count <= D3D11_MAX_MULTISAMPLE_SAMPLE_COUNT)
    {
        *levels = 0;
        return S_OK;
    }
    return hr;
}

static void fix_device(ID3D11Device *device)
{
    void **vtbl, **copy;
    if (!device) return;
    AcquireSRWLockExclusive(&lock);
    vtbl = *(void ***)device;
    if (vtbl[CHECK_MSAA_SLOT] != (void *)fixed_check)
    {
        if (!real_check) real_check = (check_msaa_fn)vtbl[CHECK_MSAA_SLOT];
        /* Only a table with the known entry; anything else stays as it is. */
        if (vtbl[CHECK_MSAA_SLOT] == (void *)real_check &&
            (copy = HeapAlloc(GetProcessHeap(), 0, TABLE_SIZE * sizeof(void *))))
        {
            memcpy(copy, vtbl, TABLE_SIZE * sizeof(void *));
            copy[CHECK_MSAA_SLOT] = (void *)fixed_check;
            *(void ***)device = copy;   /* The copy stays for the life of the process. */
        }
    }
    ReleaseSRWLockExclusive(&lock);
}

HRESULT WINAPI D3D11CreateDevice(IDXGIAdapter *adapter, D3D_DRIVER_TYPE type, HMODULE sw, UINT flags,
                                 const D3D_FEATURE_LEVEL *levels, UINT count, UINT sdk, ID3D11Device **device,
                                 D3D_FEATURE_LEVEL *level, ID3D11DeviceContext **context)
{
    HRESULT hr;
    if (!load_real()) return E_FAIL;
    hr = real_create(adapter, type, sw, flags, levels, count, sdk, device, level, context);
    if (SUCCEEDED(hr) && device) fix_device(*device);
    return hr;
}

HRESULT WINAPI D3D11CreateDeviceAndSwapChain(IDXGIAdapter *adapter, D3D_DRIVER_TYPE type, HMODULE sw, UINT flags,
                                             const D3D_FEATURE_LEVEL *levels, UINT count, UINT sdk,
                                             const DXGI_SWAP_CHAIN_DESC *desc, IDXGISwapChain **swapchain,
                                             ID3D11Device **device, D3D_FEATURE_LEVEL *level, ID3D11DeviceContext **context)
{
    HRESULT hr;
    if (!load_real() || !real_create_swapchain) return E_FAIL;
    hr = real_create_swapchain(adapter, type, sw, flags, levels, count, sdk, desc, swapchain, device, level, context);
    if (SUCCEEDED(hr) && device) fix_device(*device);
    return hr;
}

HRESULT WINAPI D3D11On12CreateDevice(IUnknown *device12, UINT flags, const D3D_FEATURE_LEVEL *levels, UINT count,
                                     IUnknown *const *queues, UINT queue_count, UINT node, ID3D11Device **device,
                                     ID3D11DeviceContext **context, D3D_FEATURE_LEVEL *level)
{
    HRESULT hr;
    if (!load_real() || !real_on12) return E_FAIL;
    hr = real_on12(device12, flags, levels, count, queues, queue_count, node, device, context, level);
    if (SUCCEEDED(hr) && device) fix_device(*device);
    return hr;
}
