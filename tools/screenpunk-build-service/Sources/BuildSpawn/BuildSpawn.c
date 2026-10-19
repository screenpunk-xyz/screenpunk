#include "BuildSpawn.h"
#include <errno.h>
#include <fcntl.h>
#include <spawn.h>
#include <pthread.h>
#include <signal.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>
#include <sys/wait.h>
#include <unistd.h>

static pthread_mutex_t spawn_limit_lock = PTHREAD_MUTEX_INITIALIZER;

int sp_build_spawn(const char *executable, const char *script, const char *source,
                   const char *output, const char *home, int log_fd, pid_t *pid) {
    posix_spawnattr_t attributes;
    posix_spawn_file_actions_t actions;
    int error = posix_spawnattr_init(&attributes);
    if (error) return error;
    error = posix_spawn_file_actions_init(&actions);
    if (error) { posix_spawnattr_destroy(&attributes); return error; }
    short flags = POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT;
    if (!(error = posix_spawnattr_setflags(&attributes, flags)))
        error = posix_spawnattr_setpgroup(&attributes, 0);
    if (!error) error = posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0);
    if (!error) error = posix_spawn_file_actions_adddup2(&actions, log_fd, STDOUT_FILENO);
    if (!error) error = posix_spawn_file_actions_adddup2(&actions, log_fd, STDERR_FILENO);
    if (!error) {
        char *const args[] = {(char *)executable, "--jitless", (char *)script,
                              (char *)source, (char *)output, NULL};
        size_t home_length = strlen(home);
        char *home_var = malloc(home_length + sizeof("HOME="));
        char *tmp_var = malloc(home_length + sizeof("TMPDIR="));
        const char *last_slash = strrchr(executable, '/');
        size_t bin_length = last_slash ? (size_t)(last_slash - executable) : 0;
        char *path_var = malloc(bin_length + sizeof("PATH="));
        if (!home_var || !tmp_var || !path_var || !last_slash) error = ENOMEM;
        else {
            memcpy(home_var, "HOME=", sizeof("HOME=") - 1);
            memcpy(home_var + sizeof("HOME=") - 1, home, home_length + 1);
            memcpy(tmp_var, "TMPDIR=", sizeof("TMPDIR=") - 1);
            memcpy(tmp_var + sizeof("TMPDIR=") - 1, home, home_length + 1);
            memcpy(path_var, "PATH=", sizeof("PATH=") - 1);
            memcpy(path_var + sizeof("PATH=") - 1, executable, bin_length);
            path_var[sizeof("PATH=") - 1 + bin_length] = '\0';
            char *const environment[] = {"NODE_ENV=production", home_var, tmp_var, path_var, NULL};
            struct rlimit original;
            if (pthread_mutex_lock(&spawn_limit_lock) != 0) error = EBUSY;
            else {
                if (getrlimit(RLIMIT_FSIZE, &original) != 0) error = errno;
                else {
                    struct rlimit limited = original;
                    const rlim_t maximum_file = 256ULL * 1024ULL * 1024ULL;
                    if (limited.rlim_cur > maximum_file) limited.rlim_cur = maximum_file;
                    if (setrlimit(RLIMIT_FSIZE, &limited) != 0) error = errno;
                    else {
                        error = posix_spawn(pid, executable, &actions, &attributes, args, environment);
                        if (setrlimit(RLIMIT_FSIZE, &original) != 0 && error == 0) {
                            int restoration_error = errno;
                            kill(-*pid, SIGKILL);
                            waitpid(*pid, NULL, 0);
                            error = restoration_error;
                        }
                    }
                }
                pthread_mutex_unlock(&spawn_limit_lock);
            }
        }
        free(home_var);
        free(tmp_var);
        free(path_var);
    }
    posix_spawn_file_actions_destroy(&actions);
    posix_spawnattr_destroy(&attributes);
    return error;
}
