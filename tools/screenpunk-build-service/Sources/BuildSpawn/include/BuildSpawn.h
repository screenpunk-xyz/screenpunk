#include <sys/types.h>

int sp_build_spawn(const char *executable, const char *script, const char *source,
                   const char *output, const char *home, int log_fd, pid_t *pid);
