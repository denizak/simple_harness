#ifndef SHELL_PROCESS_H
#define SHELL_PROCESS_H

#include <sys/types.h>

int harness_spawn_shell(const char *shell, const char *cwd, const char *command,
                        pid_t *pid, int *stdout_fd, int *stderr_fd);

#endif
