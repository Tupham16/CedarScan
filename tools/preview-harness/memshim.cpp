// Counting allocator shim: tracks live + peak bytes of meshoptimizer's internal allocations.
#include "meshoptimizer.h"
#include <stdlib.h>
#include <stdint.h>
#include <string.h>

struct Hdr { size_t size; size_t pad; };
static size_t g_live = 0, g_peak = 0;

static void* countAlloc(size_t n) {
    Hdr* h = (Hdr*)malloc(sizeof(Hdr) + n);
    if (!h) return 0;
    h->size = n;
    g_live += n;
    if (g_live > g_peak) g_peak = g_live;
    return h + 1;
}
static void countFree(void* p) {
    if (!p) return;
    Hdr* h = (Hdr*)p - 1;
    g_live -= h->size;
    free(h);
}

extern "C" {
__declspec(dllexport) void shim_install(void) { meshopt_setAllocator(countAlloc, countFree); }
__declspec(dllexport) void shim_reset_peak(void) { g_peak = g_live; }
__declspec(dllexport) size_t shim_peak(void) { return g_peak; }
__declspec(dllexport) size_t shim_live(void) { return g_live; }
}
