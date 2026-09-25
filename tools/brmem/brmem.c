// brmem: the memory picture of the iPad (run over SSH as root). Lists every process with its resident and virtual
// size, biggest first, and the system's free / active / inactive / wired memory. jetsam kills the frontmost app when
// the system runs short, so what the browser can use depends on everything else that is running (tweaks loaded into
// SpringBoard or into every app included).
// Usage: brmem [count]   (default: every process)
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <mach/mach.h>

// libproc (in libSystem; the iOS SDK has no header for it)
int proc_listallpids(void *buffer, int buffersize);
int proc_pidinfo(int pid, int flavor, uint64_t arg, void *buffer, int buffersize);
int proc_name(int pid, void *buffer, uint32_t buffersize);
#define BR_PROC_PIDTASKINFO 4

struct br_proc_taskinfo {
    uint64_t pti_virtual_size;
    uint64_t pti_resident_size;
    uint64_t pti_total_user;
    uint64_t pti_total_system;
    uint64_t pti_threads_user;
    uint64_t pti_threads_system;
    int32_t pti_policy;
    int32_t pti_faults;
    int32_t pti_pageins;
    int32_t pti_cow_faults;
    int32_t pti_messages_sent;
    int32_t pti_messages_received;
    int32_t pti_syscalls_mach;
    int32_t pti_syscalls_unix;
    int32_t pti_csw;
    int32_t pti_threadnum;
    int32_t pti_numrunning;
    int32_t pti_priority;
};

struct row {
    int pid;
    uint64_t resident, virt;
    char name[64];
};

static int by_resident(const void *a, const void *b)
{
    const struct row *x = a, *y = b;
    return x->resident < y->resident ? 1 : x->resident > y->resident ? -1 : 0;
}

int main(int argc, char **argv)
{
    int limit = argc > 1 ? atoi(argv[1]) : 0;
    int cap = 1024;
    int *pids = calloc((size_t)cap, sizeof(int));
    int n = proc_listallpids(pids, cap * (int)sizeof(int));
    if (n <= 0) { fprintf(stderr, "proc_listallpids failed\n"); return 1; }
    struct row *rows = calloc((size_t)n, sizeof(struct row));
    int count = 0;
    uint64_t total = 0;
    for (int i = 0; i < n; i++) {
        struct br_proc_taskinfo ti;
        if (pids[i] <= 0) continue;
        if (proc_pidinfo(pids[i], BR_PROC_PIDTASKINFO, 0, &ti, sizeof(ti)) != (int)sizeof(ti)) continue;
        rows[count].pid = pids[i];
        rows[count].resident = ti.pti_resident_size;
        rows[count].virt = ti.pti_virtual_size;
        if (proc_name(pids[i], rows[count].name, sizeof(rows[count].name)) <= 0) strcpy(rows[count].name, "?");
        total += ti.pti_resident_size;
        count++;
    }
    qsort(rows, (size_t)count, sizeof(struct row), by_resident);

    vm_size_t page = 4096;
    host_page_size(mach_host_self(), &page);
    vm_statistics_data_t vm;
    mach_msg_type_number_t vmCount = HOST_VM_INFO_COUNT;
    if (host_statistics(mach_host_self(), HOST_VM_INFO, (host_info_t)&vm, &vmCount) == KERN_SUCCESS) {
        double mb = (double)page / (1024.0 * 1024.0);
        printf("system: free %.0f MB, active %.0f MB, inactive %.0f MB, wired %.0f MB, purgeable %.0f MB (page %lu bytes)\n",
               vm.free_count * mb, vm.active_count * mb, vm.inactive_count * mb, vm.wire_count * mb, vm.purgeable_count * mb, (unsigned long)page);
    }
    printf("%d processes, %.0f MB resident together (shared pages counted in each)\n", count, total / 1048576.0);
    printf("%6s %8s %9s  %s\n", "pid", "res MB", "virt MB", "name");
    for (int i = 0; i < count && (!limit || i < limit); i++) {
        printf("%6d %8.1f %9.0f  %s\n", rows[i].pid, rows[i].resident / 1048576.0, rows[i].virt / 1048576.0, rows[i].name);
    }
    return 0;
}
