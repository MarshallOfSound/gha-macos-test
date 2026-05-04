#import <Cocoa/Cocoa.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <signal.h>
#include <sys/wait.h>
#include <spawn.h>

extern char **environ;
static const char *g_argv0;
static volatile int g_done = 0;

// --- Chromium/Electron-shaped NSApplication subclass ----------------------
// Mirrors CrApplication / ElectronApplication: overrides sendEvent: to track
// re-entrancy (CrAppProtocol), and overrides terminate: to NOT call super
// (Electron intercepts terminate and routes it through JS 'before-quit').
@interface ProbeApplication : NSApplication {
  BOOL _handlingSendEvent;
}
@end
@implementation ProbeApplication
- (BOOL)isHandlingSendEvent { return _handlingSendEvent; }
- (void)setHandlingSendEvent:(BOOL)b { _handlingSendEvent = b; }
- (void)sendEvent:(NSEvent *)event {
  BOOL prev = _handlingSendEvent;
  _handlingSendEvent = YES;
  [super sendEvent:event];
  _handlingSendEvent = prev;
}
- (void)terminate:(id)sender {
  // Electron does NOT call [super terminate:] here.
  fprintf(stderr, "[%d] terminate: intercepted\n", getpid());
}
@end

@interface ProbeDelegate : NSObject <NSApplicationDelegate>
@end

@implementation ProbeDelegate

- (void)handleGetURLEvent:(NSAppleEventDescriptor *)event
           withReplyEvent:(NSAppleEventDescriptor *)reply {
  fprintf(stderr, "[%d] AE GURL\n", getpid());
}
- (void)handleOpenDocsEvent:(NSAppleEventDescriptor *)event
             withReplyEvent:(NSAppleEventDescriptor *)reply {
  fprintf(stderr, "[%d] AE odoc\n", getpid());
}
- (void)handleQuitEvent:(NSAppleEventDescriptor *)event
         withReplyEvent:(NSAppleEventDescriptor *)reply {
  fprintf(stderr, "[%d] AE quit\n", getpid());
}

- (void)applicationWillFinishLaunching:(NSNotification *)n {
  fprintf(stderr, "[%d] WILL\n", getpid());
  // Electron registers these in -applicationWillFinishLaunching: — see
  // ElectronApplicationDelegate. Registering AE handlers here is what causes
  // the process to attach to appleeventsd before the runloop starts.
  NSAppleEventManager *m = [NSAppleEventManager sharedAppleEventManager];
  [m setEventHandler:self
         andSelector:@selector(handleGetURLEvent:withReplyEvent:)
       forEventClass:kInternetEventClass
          andEventID:kAEGetURL];
  [m setEventHandler:self
         andSelector:@selector(handleOpenDocsEvent:withReplyEvent:)
       forEventClass:kCoreEventClass
          andEventID:kAEOpenDocuments];
  [m setEventHandler:self
         andSelector:@selector(handleQuitEvent:withReplyEvent:)
       forEventClass:kCoreEventClass
          andEventID:kAEQuitApplication];
}

- (void)applicationDidFinishLaunching:(NSNotification *)n {
  fprintf(stderr, "[%d] DID\n", getpid());

  if (getenv("PROBE_CHILD")) {
    exit(0);
  }

  // Parent mode: drive the experiment off-main so the runloop stays in [NSApp run].
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
    int N            = getenv("PROBE_N")          ? atoi(getenv("PROBE_N"))          : 12;
    int delay_ms     = getenv("PROBE_DELAY_MS")   ? atoi(getenv("PROBE_DELAY_MS"))   : 150;
    int skip_wait    = getenv("PROBE_SKIP_WAIT")  ? 1                                : 0;
    int leave_alive  = getenv("PROBE_LEAVE_ALIVE")? atoi(getenv("PROBE_LEAVE_ALIVE")): 0;
    int hold_s       = getenv("PROBE_HOLD")       ? atoi(getenv("PROBE_HOLD"))       : 0;

    fprintf(stderr, "[parent %d] N=%d delay_ms=%d skip_wait=%d leave_alive=%d\n",
            getpid(), N, delay_ms, skip_wait, leave_alive);

    setenv("PROBE_CHILD", "1", 1);
    char *child_argv[] = {(char *)g_argv0, NULL};

    // Reset SIGINT in children (AppKit may have set SIG_IGN in parent).
    posix_spawnattr_t attr; posix_spawnattr_init(&attr);
    sigset_t dfl; sigemptyset(&dfl); sigaddset(&dfl, SIGINT);
    posix_spawnattr_setsigdefault(&attr, &dfl);
    posix_spawnattr_setflags(&attr, POSIX_SPAWN_SETSIGDEF);

    pid_t alive[64]; int alive_n = 0;

    for (int i = 0; i < N; i++) {
      pid_t pid;
      if (posix_spawn(&pid, g_argv0, NULL, &attr, child_argv, environ) != 0) {
        fprintf(stderr, "[parent] spawn %d failed\n", i); continue;
      }
      usleep((useconds_t)delay_ms * 1000);
      if (leave_alive && alive_n < leave_alive) {
        alive[alive_n++] = pid;
        fprintf(stderr, "[parent] churn %2d -> %d (left alive)\n", i+1, pid);
        continue;
      }
      kill(pid, getenv("PROBE_SIGKILL") ? SIGKILL : SIGINT);
      if (!skip_wait) { int st; waitpid(pid, &st, 0); }
      fprintf(stderr, "[parent] churn %2d -> %d (SIGINT%s)\n", i+1, pid,
              skip_wait ? ", zombie" : "");
    }

    fprintf(stderr, "--- victim ---\n");
    pid_t victim;
    if (posix_spawn(&victim, g_argv0, NULL, &attr, child_argv, environ) != 0) {
      fprintf(stderr, "victim spawn failed\n"); exit(1);
    }
    fprintf(stderr, "[parent] victim pid %d\n", victim);

    int exited = 0;
    for (int i = 0; i < 100; i++) {
      int st;
      if (waitpid(victim, &st, WNOHANG) == victim) { exited = 1; break; }
      usleep(100 * 1000);
    }

    if (exited) {
      fprintf(stderr, "NOT REPRODUCED\n");
    } else {
      fprintf(stderr, "REPRODUCED (victim %d hung, no DID)\n", victim);
      if (hold_s) {
        fprintf(stderr, "[parent] holding %ds for lldb -p %d ...\n", hold_s, victim);
        sleep(hold_s);
      }
      kill(victim, SIGKILL); waitpid(victim, NULL, 0);
    }
    for (int i = 0; i < alive_n; i++) { kill(alive[i], SIGKILL); waitpid(alive[i], NULL, 0); }
    g_done = 1;
    // Wake the pump.
    dispatch_async(dispatch_get_main_queue(), ^{
      NSEvent *e = [NSEvent otherEventWithType:NSEventTypeApplicationDefined
                                      location:NSZeroPoint modifierFlags:0
                                     timestamp:0 windowNumber:0 context:nil
                                       subtype:0 data1:0 data2:0];
      [NSApp postEvent:e atStart:YES];
    });
  });
}

@end

int main(int argc, const char *argv[]) {
  g_argv0 = argv[0];
  @autoreleasepool {
    // Force our subclass regardless of NSPrincipalClass plumbing.
    [ProbeApplication sharedApplication];
    fprintf(stderr, "[%d] NSApp class=%s\n", getpid(),
            [NSStringFromClass([NSApp class]) UTF8String]);
    if (getenv("PROBE_REGULAR"))
      [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
    ProbeDelegate *d = [ProbeDelegate new];
    [NSApp setDelegate:d];

    // Emulate Chromium's MessagePumpNSApplication::DoRun:
    //   1. finishLaunching explicitly (fires WILL, installs AE handlers)
    //   2. heavy init (Node/Chromium) — child is AE-registered, oapp pending
    //   3. manual nextEventMatchingMask pump — first iteration delivers oapp -> DID
    // Never calls [NSApp run].
    [NSApp finishLaunching];
    fprintf(stderr, "[%d] finishLaunching returned\n", getpid());

    if (getenv("PROBE_CHILD") && getenv("PROBE_INIT_SLEEP_MS"))
      usleep((useconds_t)atoi(getenv("PROBE_INIT_SLEEP_MS")) * 1000);

    fprintf(stderr, "[%d] entering pump\n", getpid());
    while (!g_done) {
      @autoreleasepool {
        NSEvent *event = [NSApp nextEventMatchingMask:NSEventMaskAny
                                            untilDate:[NSDate dateWithTimeIntervalSinceNow:0.1]
                                               inMode:NSDefaultRunLoopMode
                                              dequeue:YES];
        if (event) [NSApp sendEvent:event];
      }
    }
    fprintf(stderr, "[%d] pump exited\n", getpid());
  }
  return 0;
}
