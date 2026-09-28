#define _GNU_SOURCE 1
#define _DARWIN_C_SOURCE 1
#include "ShellProcess.h"

#include <errno.h>
#include <fcntl.h>
#include <spawn.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

extern char **environ;

int harness_spawn_shell(const char *shell, const char *cwd, const char *command,
                        pid_t *pid, int *stdout_fd, int *stderr_fd) {
    int out_pipe[2] = {-1, -1};
    int err_pipe[2] = {-1, -1};
    posix_spawn_file_actions_t actions;
    posix_spawnattr_t attributes;
    int actions_ready = 0;
    int attributes_ready = 0;
    int result = -1;

    if (pipe(out_pipe) != 0 || pipe(err_pipe) != 0) goto cleanup;
    if (posix_spawn_file_actions_init(&actions) != 0) goto cleanup;
    actions_ready = 1;
    if (posix_spawnattr_init(&attributes) != 0) goto cleanup;
    attributes_ready = 1;

    if (posix_spawn_file_actions_adddup2(&actions, out_pipe[1], STDOUT_FILENO) != 0 ||
        posix_spawn_file_actions_adddup2(&actions, err_pipe[1], STDERR_FILENO) != 0 ||
        posix_spawn_file_actions_addclose(&actions, out_pipe[0]) != 0 ||
        posix_spawn_file_actions_addclose(&actions, err_pipe[0]) != 0 ||
        posix_spawn_file_actions_addclose(&actions, out_pipe[1]) != 0 ||
        posix_spawn_file_actions_addclose(&actions, err_pipe[1]) != 0) goto cleanup;

#if defined(__APPLE__) || defined(__linux__)
    if (posix_spawn_file_actions_addchdir_np(&actions, cwd) != 0) goto cleanup;
#else
#error "A spawn file action for setting cwd is required on this platform"
#endif

    if (posix_spawnattr_setflags(&attributes, POSIX_SPAWN_SETPGROUP) != 0 ||
        posix_spawnattr_setpgroup(&attributes, 0) != 0) goto cleanup;

    char *const argv[] = {(char *)shell, (char *)"-lc", (char *)command, NULL};
    result = posix_spawn(pid, shell, &actions, &attributes, argv, environ);
    if (result != 0) goto cleanup;

    close(out_pipe[1]); out_pipe[1] = -1;
    close(err_pipe[1]); err_pipe[1] = -1;
    *stdout_fd = out_pipe[0]; out_pipe[0] = -1;
    *stderr_fd = err_pipe[0]; err_pipe[0] = -1;

cleanup:
    if (actions_ready) posix_spawn_file_actions_destroy(&actions);
    if (attributes_ready) posix_spawnattr_destroy(&attributes);
    if (out_pipe[0] >= 0) close(out_pipe[0]);
    if (out_pipe[1] >= 0) close(out_pipe[1]);
    if (err_pipe[0] >= 0) close(err_pipe[0]);
    if (err_pipe[1] >= 0) close(err_pipe[1]);
    return result;
}
