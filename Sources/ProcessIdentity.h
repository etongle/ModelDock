#include <stdint.h>

uint64_t mm_process_start_time(int pid);
int mm_process_parent(int pid);
int mm_process_path(int pid, char *buffer, int capacity);
int mm_process_arguments(int pid, char *buffer, int capacity);
int mm_process_belongs_to(int pid, uint64_t expected, int root, uint64_t root_start);
int mm_system_metrics(uint64_t *values);
int mm_group_metrics(int root, uint64_t expected_start, uint64_t *records, int capacity);
