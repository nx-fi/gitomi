// Linux process supervision for claim exec. Protocol validation stays in Zig.
// All allocation and argv/environment construction happens before fork. The
// guardian runs only syscall-style libc operations and never enters Zig code.
#define _GNU_SOURCE
#include <errno.h>
#include <stddef.h>
#include <stdint.h>
#include <signal.h>
#include <unistd.h>
#include <sys/wait.h>
#include <sys/prctl.h>
#include <sys/signalfd.h>
#include <sys/timerfd.h>
#include <sys/syscall.h>
#include <poll.h>
#include <time.h>
#include <fcntl.h>
#include <linux/audit.h>
#include <linux/filter.h>
#include <linux/seccomp.h>
#include <linux/sched.h>

// kind: 0 command success, 1 command failed, 2 deadline, 3 canceled, 4 setup/IO.
struct gt_claim_exec_result { int kind, status, error_number; };
static volatile sig_atomic_t interrupted;
static void interrupt_wait(int signo) { interrupted = signo; }
static const int handled[] = { SIGINT, SIGTERM, SIGHUP };

int gt_claim_exec_prepare(void) {
    // Required before even the Git reads used for fencing: Zig's process wait
    // API needs waitable children, including when a harness ignored SIGCHLD.
    struct sigaction normal = { .sa_handler = SIG_DFL };
    sigemptyset(&normal.sa_mask);
    return sigaction(SIGCHLD, &normal, NULL) ? errno : 0;
}

static void report(int fd, struct gt_claim_exec_result result) {
    const char *p = (const char *)&result;
    size_t left = sizeof(result);
    while (left) {
        ssize_t n = write(fd, p, left);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) break;
        p += n;
        left -= (size_t)n;
    }
}

static int64_t millis(clockid_t clock) {
    struct timespec t;
    if (clock_gettime(clock, &t)) return -1;
    return (int64_t)t.tv_sec * 1000 + t.tv_nsec / 1000000;
}

static int arm_timer(clockid_t clock, int64_t when, int cancel_on_set) {
    int fd = timerfd_create(clock, TFD_CLOEXEC | TFD_NONBLOCK);
    if (fd < 0) return -1;
    struct itimerspec t = { .it_value = { .tv_sec = when / 1000,
                                         .tv_nsec = (when % 1000) * 1000000 } };
    if (timerfd_settime(fd, TFD_TIMER_ABSTIME |
                       (cancel_on_set ? TFD_TIMER_CANCEL_ON_SET : 0), &t, NULL)) {
        int saved = errno;
        close(fd);
        errno = saved;
        return -1;
    }
    return fd;
}

// Keep all worker descendants in the killable process group. no_new_privs also
// prevents exec from gaining credentials that would defeat group cancellation.
// clone3 returns ENOSYS so libc can use clone; namespace creation and changing
// sessions/groups are unavailable inside this supervised command.
static int contain_group(pid_t guardian_pid) {
#if defined(__x86_64__) && !defined(__ILP32__)
#define CLAIM_ARCH AUDIT_ARCH_X86_64
#elif defined(__aarch64__)
#define CLAIM_ARCH AUDIT_ARCH_AARCH64
#else
    errno = ENOTSUP;
    return -1;
#endif
#ifdef CLAIM_ARCH
#define DENY (SECCOMP_RET_ERRNO | EPERM)
#define DENY_PID(syscall, argument) \
        BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, syscall, 0, 3), \
        BPF_STMT(BPF_LD | BPF_W | BPF_ABS, offsetof(struct seccomp_data, args[argument])), \
        BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, (uint32_t)guardian_pid, 0, 1), \
        BPF_STMT(BPF_RET | BPF_K, DENY), \
        BPF_STMT(BPF_LD | BPF_W | BPF_ABS, offsetof(struct seccomp_data, nr))
    struct sock_filter code[] = {
        BPF_STMT(BPF_LD | BPF_W | BPF_ABS, offsetof(struct seccomp_data, arch)),
        BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, CLAIM_ARCH, 1, 0),
        BPF_STMT(BPF_RET | BPF_K, SECCOMP_RET_KILL_PROCESS),
        BPF_STMT(BPF_LD | BPF_W | BPF_ABS, offsetof(struct seccomp_data, nr)),
#if defined(__x86_64__)
        BPF_JUMP(BPF_JMP | BPF_JSET | BPF_K, 0x40000000U, 0, 1),
        BPF_STMT(BPF_RET | BPF_K, DENY),
#endif
        // The guardian shares credentials with the command, so prevent the
        // command from stopping or killing the process that enforces its
        // deadline. kill(-1, ...) can target the guardian too.
        DENY_PID(__NR_kill, 0),
        BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, __NR_kill, 0, 3),
        BPF_STMT(BPF_LD | BPF_W | BPF_ABS, offsetof(struct seccomp_data, args[0])),
        BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, UINT32_MAX, 0, 1),
        BPF_STMT(BPF_RET | BPF_K, DENY),
        BPF_STMT(BPF_LD | BPF_W | BPF_ABS, offsetof(struct seccomp_data, nr)),
        DENY_PID(__NR_tkill, 0),
        DENY_PID(__NR_tgkill, 0),
        DENY_PID(__NR_tgkill, 1),
        DENY_PID(__NR_rt_sigqueueinfo, 0),
        DENY_PID(__NR_rt_tgsigqueueinfo, 0),
        DENY_PID(__NR_rt_tgsigqueueinfo, 1),
#ifdef __NR_pidfd_open
        DENY_PID(__NR_pidfd_open, 0),
#endif
#ifdef __NR_pidfd_send_signal
        // A seccomp filter cannot determine which process an fd denotes.
        BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, __NR_pidfd_send_signal, 0, 1),
        BPF_STMT(BPF_RET | BPF_K, DENY),
#endif
        BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, __NR_setsid, 0, 1),
        BPF_STMT(BPF_RET | BPF_K, DENY),
        BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, __NR_setpgid, 0, 1),
        BPF_STMT(BPF_RET | BPF_K, DENY),
        BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, __NR_setns, 0, 1),
        BPF_STMT(BPF_RET | BPF_K, DENY),
        BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, __NR_unshare, 0, 1),
        BPF_STMT(BPF_RET | BPF_K, DENY),
        BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, __NR_clone3, 0, 1),
        BPF_STMT(BPF_RET | BPF_K, SECCOMP_RET_ERRNO | ENOSYS),
        BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, __NR_clone, 0, 3),
        BPF_STMT(BPF_LD | BPF_W | BPF_ABS, offsetof(struct seccomp_data, args[0])),
        BPF_JUMP(BPF_JMP | BPF_JSET | BPF_K, CLONE_NEWPID | CLONE_NEWUSER, 0, 1),
        BPF_STMT(BPF_RET | BPF_K, DENY),
        BPF_STMT(BPF_RET | BPF_K, SECCOMP_RET_ALLOW),
    };
    struct sock_fprog filter = { .len = sizeof(code) / sizeof(code[0]), .filter = code };
    if (prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0)) return -1;
    return prctl(PR_SET_SECCOMP, SECCOMP_MODE_FILTER, &filter);
#undef DENY_PID
#endif
}

static void child_error(int fd) {
    int saved = errno;
    // Atomic, bounded pipe write; the reader remains in the guardian.
    while (write(fd, &saved, sizeof(saved)) < 0 && errno == EINTR) {}
    _exit(126);
}

static void guardian(int control, int output, int64_t deadline, int64_t margin,
                     char *const argv[], char *const envp[],
                     const sigset_t *original_mask, const struct sigaction *original_actions) {
    struct gt_claim_exec_result result = { 4, 0, 0 };
    int real_timer = -1, boot_timer = -1, signals = -1;
    int start[2] = { -1, -1 }, errors[2] = { -1, -1 };
    pid_t worker = -1;
    struct sigaction ignore = { .sa_handler = SIG_IGN };
    struct sigaction normal_child = { .sa_handler = SIG_DFL };
    sigemptyset(&ignore.sa_mask);
    sigemptyset(&normal_child.sa_mask);
    // An inherited SIG_IGN / SA_NOCLDWAIT would reap the leader implicitly,
    // invalidating the PID pin used for safe process-group cancellation.
    if (setsid() < 0 || sigaction(SIGPIPE, &ignore, NULL) ||
        sigaction(SIGCHLD, &normal_child, NULL) ||
        prctl(PR_SET_CHILD_SUBREAPER, 1, 0, 0, 0)) goto setup_failed;
    sigset_t mask;
    sigemptyset(&mask);
    sigaddset(&mask, SIGCHLD);
    for (size_t i = 0; i < sizeof(handled) / sizeof(handled[0]); ++i) sigaddset(&mask, handled[i]);
    signals = signalfd(-1, &mask, SFD_CLOEXEC | SFD_NONBLOCK);
    if (signals < 0) goto setup_failed;
    int64_t real = millis(CLOCK_REALTIME), boot = millis(CLOCK_BOOTTIME);
    if (real < 0 || boot < 0) goto setup_failed;
    int64_t stop = deadline - margin;
    if (stop <= real) { result.kind = 2; goto finish; }
    real_timer = arm_timer(CLOCK_REALTIME, stop, 1);
    boot_timer = arm_timer(CLOCK_BOOTTIME, boot + stop - real, 0);
    if (real_timer < 0 || boot_timer < 0 || pipe2(start, O_CLOEXEC) ||
        pipe2(errors, O_CLOEXEC | O_NONBLOCK)) goto setup_failed;
    pid_t guardian_pid = getpid();
    worker = fork();
    if (worker < 0) goto setup_failed;
    if (worker == 0) {
        close(start[1]); close(errors[0]); close(control); close(output);
        close(real_timer); close(boot_timer); close(signals);
        if (setpgid(0, 0) || prctl(PR_SET_PDEATHSIG, SIGKILL, 0, 0, 0)) child_error(errors[1]);
        if (getppid() != guardian_pid) _exit(126);
        for (size_t i = 0; i < sizeof(handled) / sizeof(handled[0]); ++i)
            if (sigaction(handled[i], &original_actions[i], NULL)) child_error(errors[1]);
        struct sigaction normal = { .sa_handler = SIG_DFL };
        sigemptyset(&normal.sa_mask);
        if (sigaction(SIGPIPE, &normal, NULL) || sigaction(SIGCHLD, &normal, NULL) ||
            sigprocmask(SIG_SETMASK, original_mask, NULL) || contain_group(guardian_pid)) child_error(errors[1]);
        char permit;
        ssize_t n;
        do { n = read(start[0], &permit, 1); } while (n < 0 && errno == EINTR);
        close(start[0]);
        if (n != 1 || permit != 'G') _exit(126);
        execvpe(argv[0], argv, envp);
        child_error(errors[1]);
    }
    close(start[0]); start[0] = -1;
    close(errors[1]); errors[1] = -1;
    // Establish the group from both sides before permitting any command code.
    if (setpgid(worker, worker) && errno != EACCES) goto setup_failed;
    struct pollfd fds[] = { { control, POLLIN, 0 }, { real_timer, POLLIN, 0 },
                           { boot_timer, POLLIN, 0 }, { signals, POLLIN, 0 } };
    if (poll(fds, 4, 0) < 0) goto setup_failed;
    if (fds[0].revents) { result.kind = 3; goto stop_worker; }
    if (fds[1].revents || fds[2].revents || millis(CLOCK_REALTIME) >= stop) {
        result.kind = 2; goto stop_worker;
    }
    if (write(start[1], "G", 1) != 1) goto setup_failed;
    close(start[1]); start[1] = -1;
    for (;;) {
        int64_t current = millis(CLOCK_REALTIME);
        if (current < 0) goto setup_failed;
        if (current >= stop) { result.kind = 2; goto stop_worker; }
        // WNOWAIT pins the group leader's PID until the final group signal.
        // Reaping first could allow that PID to be reused for an unrelated job.
        siginfo_t info = {0};
        if (waitid(P_PID, worker, &info, WEXITED | WNOHANG | WNOWAIT)) goto setup_failed;
        if (info.si_pid) {
            result.kind = info.si_code == CLD_EXITED && info.si_status == 0 ? 0 : 1;
            result.status = info.si_code == CLD_EXITED ? info.si_status : 128 + info.si_status;
            int failure;
            if (read(errors[0], &failure, sizeof(failure)) == sizeof(failure)) {
                result.kind = 4; result.error_number = failure;
            }
            goto stop_worker;
        }
        int n = poll(fds, 4, -1);
        if (n < 0 && errno == EINTR) continue;
        if (n < 0) goto setup_failed;
        if (fds[0].revents) { result.kind = 3; goto stop_worker; }
        if (fds[1].revents || fds[2].revents) { result.kind = 2; goto stop_worker; }
        if (fds[3].revents) {
            struct signalfd_siginfo signal_info;
            while (read(signals, &signal_info, sizeof(signal_info)) == sizeof(signal_info)) {
                if (signal_info.ssi_signo != SIGCHLD) { result.kind = 3; goto stop_worker; }
            }
        }
    }
setup_failed:
    result.kind = 4;
    result.error_number = errno;
stop_worker:
    if (worker > 0) {
        // Also remove background descendants after a successful foreground exit.
        // seccomp prevents escaping this group; subreaping collects descendants.
        kill(-worker, SIGKILL);
        kill(worker, SIGKILL); // Covers a pre-group setup failure.
        for (;;) {
            pid_t waited = waitpid(-1, NULL, 0);
            if (waited > 0 || (waited < 0 && errno == EINTR)) continue;
            break;
        }
    }
finish:
    report(output, result);
    _exit(0);
}

void gt_claim_exec(char *const argv[], char *const envp[], int64_t deadline_ms,
                   int64_t margin_ms, struct gt_claim_exec_result *result) {
    *result = (struct gt_claim_exec_result){ 4, 0, 0 };
    int control[2] = { -1, -1 }, output[2] = { -1, -1 };
    struct sigaction old[3];
    size_t installed = 0;
    sigset_t blocked, original_mask;
    int mask_changed = 0;
    pid_t child = -1;
    interrupted = 0;
    if (pipe2(control, O_CLOEXEC) || pipe2(output, O_CLOEXEC)) goto failed;
    struct sigaction action = { .sa_handler = interrupt_wait };
    sigemptyset(&action.sa_mask);
    for (; installed < sizeof(handled) / sizeof(handled[0]); ++installed)
        if (sigaction(handled[installed], &action, &old[installed])) goto failed;
    sigemptyset(&blocked);
    sigaddset(&blocked, SIGCHLD);
    for (size_t i = 0; i < sizeof(handled) / sizeof(handled[0]); ++i) sigaddset(&blocked, handled[i]);
    if (sigprocmask(SIG_BLOCK, &blocked, &original_mask)) goto failed;
    mask_changed = 1;
    child = fork();
    if (child < 0) goto failed;
    if (child == 0) {
        close(control[1]); close(output[0]);
        guardian(control[0], output[1], deadline_ms, margin_ms, argv, envp, &original_mask, old);
    }
    close(control[0]); control[0] = -1;
    close(output[1]); output[1] = -1;
    sigprocmask(SIG_SETMASK, &original_mask, NULL);
    mask_changed = 0;
    char *p = (char *)result;
    size_t left = sizeof(*result);
    while (left) {
        if (interrupted && control[1] >= 0) { close(control[1]); control[1] = -1; }
        struct pollfd ready = { output[0], POLLIN, 0 };
        int available = poll(&ready, 1, 100);
        if (available < 0 && errno == EINTR) continue;
        if (available < 0) { *result = (struct gt_claim_exec_result){ 4, 0, errno }; break; }
        if (available == 0) continue;
        ssize_t n = read(output[0], p, left);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) { *result = (struct gt_claim_exec_result){ 4, 0, n < 0 ? errno : EIO }; break; }
        p += n; left -= (size_t)n;
    }
    goto finish;
failed:
    result->error_number = errno;
finish:
    if (control[1] >= 0) close(control[1]);
    if (control[0] >= 0) close(control[0]);
    if (output[1] >= 0) close(output[1]);
    if (output[0] >= 0) close(output[0]);
    if (child > 0) while (waitpid(child, NULL, 0) < 0 && errno == EINTR) {}
    if (mask_changed) sigprocmask(SIG_SETMASK, &original_mask, NULL);
    while (installed) { --installed; sigaction(handled[installed], &old[installed], NULL); }
}
