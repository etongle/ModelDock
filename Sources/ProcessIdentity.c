#include <libproc.h>
#include <stdint.h>
#include <sys/proc_info.h>
#include <sys/resource.h>
#include <sys/sysctl.h>
#include <mach/mach.h>
#include <mach/mach_time.h>
#include <stdlib.h>
#include <string.h>

int mm_process_parent(int pid) {
    struct proc_bsdinfo info = {0};
    return proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, sizeof(info)) == sizeof(info) ? info.pbi_ppid : 0;
}

int mm_process_path(int pid, char *buffer, int capacity) {
    return proc_pidpath(pid, buffer, capacity);
}

// Return actual argv entries, separated by NUL, without logging command lines.
int mm_process_arguments(int pid, char *buffer, int capacity) {
    int mib[] = {CTL_KERN, KERN_PROCARGS2, pid};
    char bytes[65536]; size_t size = sizeof(bytes);
    if (sysctl(mib, 3, bytes, &size, NULL, 0) != 0 || size <= sizeof(int)) return 0;
    int argc = 0; memcpy(&argc, bytes, sizeof(argc));
    char *cursor = bytes + sizeof(int), *end = bytes + size;
    while (cursor < end && *cursor) cursor++;
    while (cursor < end && !*cursor) cursor++;
    int written = 0;
    for (int index = 0; index < argc && cursor < end; index++) {
        size_t length = strnlen(cursor, end - cursor);
        if (cursor + length >= end || written + length + 1 > (size_t)capacity) break;
        memcpy(buffer + written, cursor, length + 1);
        written += length + 1; cursor += length + 1;
    }
    return written;
}

int mm_process_belongs_to(int pid, uint64_t expected, int root, uint64_t root_start) {
    struct proc_bsdinfo leader = {0}, info = {0};
    if (!root_start || proc_pidinfo(root, PROC_PIDTBSDINFO, 0, &leader, sizeof(leader)) != sizeof(leader)) return 0;
    if (leader.pbi_start_tvsec * 1000000ULL + leader.pbi_start_tvusec != root_start) return 0;
    if (proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, sizeof(info)) != sizeof(info)) return 0;
    uint64_t birth = info.pbi_start_tvsec * 1000000ULL + info.pbi_start_tvusec;
    if (!expected || birth != expected || birth < root_start) return 0;
    if (pid == root || (leader.pbi_pgid == (uint32_t)root && info.pbi_pgid == (uint32_t)root)) return 1;
    for (int hop = 0; hop < 64 && info.pbi_ppid > 1; hop++) {
        int parent = info.pbi_ppid;
        if (parent == root) return 1;
        if (proc_pidinfo(parent, PROC_PIDTBSDINFO, 0, &info, sizeof(info)) != sizeof(info)) break;
    }
    return 0;
}

// Kernel start time survives exec and distinguishes a recycled PID.
uint64_t mm_process_start_time(int pid) {
    struct proc_bsdinfo info = {0};
    int count = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, sizeof(info));
    if (count != sizeof(info)) return 0;
    return info.pbi_start_tvsec * 1000000ULL + info.pbi_start_tvusec;
}

int mm_system_metrics(uint64_t *values) {
    mach_port_t host = mach_host_self();
    host_cpu_load_info_data_t cpu = {0};
    mach_msg_type_number_t cpu_count = HOST_CPU_LOAD_INFO_COUNT;
    vm_statistics64_data_t vm = {0};
    mach_msg_type_number_t vm_count = HOST_VM_INFO64_COUNT;
    vm_size_t page_size = 0;
    uint64_t total = 0; size_t total_size = sizeof(total);
    int valid = host_statistics(host, HOST_CPU_LOAD_INFO, (host_info_t)&cpu, &cpu_count) == KERN_SUCCESS &&
        host_statistics64(host, HOST_VM_INFO64, (host_info64_t)&vm, &vm_count) == KERN_SUCCESS &&
        host_page_size(host, &page_size) == KERN_SUCCESS && sysctlbyname("hw.memsize", &total, &total_size, NULL, 0) == 0;
    mach_port_deallocate(mach_task_self(), host);
    if (!valid) return 0;
    for (int i = 0; i < CPU_STATE_MAX; i++) values[i] = cpu.cpu_ticks[i];
    uint64_t internal = vm.internal_page_count > vm.purgeable_count ? vm.internal_page_count - vm.purgeable_count : 0;
    uint64_t used = (internal + vm.wire_count + vm.compressor_page_count) * page_size;
    values[4] = used > total ? total : used;
    values[5] = total;
    values[6] = vm.compressor_page_count * (uint64_t)page_size;
    values[7] = vm.external_page_count * (uint64_t)page_size;
    return 1;
}

// Each record is PID, kernel birth time, cumulative CPU nanoseconds, footprint.
// Include descendants and members of a service's own process group.
int mm_group_metrics(int root, uint64_t expected_start, uint64_t *records, int capacity) {
    mach_timebase_info_data_t timebase = {0};
    if (mach_timebase_info(&timebase) != KERN_SUCCESS || !timebase.denom) return -1;
    struct proc_bsdinfo root_info = {0};
    if (root <= 1 || capacity <= 0 || proc_pidinfo(root, PROC_PIDTBSDINFO, 0, &root_info, sizeof(root_info)) != sizeof(root_info)) return -1;
    uint64_t start = root_info.pbi_start_tvsec * 1000000ULL + root_info.pbi_start_tvusec;
    if (expected_start && start != expected_start) return -1;
    int allocation = proc_listallpids(NULL, 0) + 256;
    if (allocation <= 0 || allocation > 131072) return -1;
    int *pids = calloc(allocation, sizeof(int));
    struct proc_bsdinfo *infos = calloc(allocation, sizeof(struct proc_bsdinfo));
    unsigned char *selected = calloc(allocation, 1);
    if (!pids || !infos || !selected) { free(pids); free(infos); free(selected); return -1; }
    int count = proc_listallpids(pids, allocation * sizeof(int));
    if (count > allocation) count = allocation;
    for (int i = 0; i < count; i++) {
        if (proc_pidinfo(pids[i], PROC_PIDTBSDINFO, 0, &infos[i], sizeof(infos[i])) != sizeof(infos[i])) continue;
        if (pids[i] == root || (root_info.pbi_pgid == (uint32_t)root && infos[i].pbi_pgid == (uint32_t)root)) selected[i] = 1;
    }
    for (int pass = 0; pass < 64; pass++) {
        int added = 0;
        for (int i = 0; i < count; i++) if (!selected[i] && infos[i].pbi_pid) {
            for (int parent = 0; parent < count; parent++) if (selected[parent] && infos[i].pbi_ppid == (uint32_t)pids[parent]) { selected[i] = 1; added = 1; break; }
        }
        if (!added) break;
    }
    int written = 0;
    for (int i = 0; i < count && written < capacity; i++) if (selected[i]) {
        struct rusage_info_v2 usage = {0};
        if (proc_pid_rusage(pids[i], RUSAGE_INFO_V2, (rusage_info_t *)&usage) != 0) continue;
        records[written * 4] = pids[i];
        records[written * 4 + 1] = infos[i].pbi_start_tvsec * 1000000ULL + infos[i].pbi_start_tvusec;
        // proc_pid_rusage reports Mach absolute ticks on Apple Silicon.
        __uint128_t cpu_ticks = (__uint128_t)usage.ri_user_time + usage.ri_system_time;
        records[written * 4 + 2] = (uint64_t)(cpu_ticks * timebase.numer / timebase.denom);
        records[written * 4 + 3] = usage.ri_phys_footprint;
        written++;
    }
    free(pids); free(infos); free(selected);
    return written > 0 ? written : -1;
}
