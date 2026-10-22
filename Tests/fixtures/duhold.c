// duhold <mode> <path>: hold a file on a test volume, print "ready <mode> <pid>", then sleep until killed.
//   fd       open O_RDONLY, keep the fd
//   fdw      open O_WRONLY|O_APPEND, keep the fd (a writer)
//   mmap     mmap PROT_READ  MAP_SHARED, close the fd (mmap-only holder)
//   mmapw    mmap PROT_READ|PROT_WRITE MAP_SHARED, close the fd (writable mapping)
//   mmapp    mmap PROT_READ|PROT_WRITE MAP_PRIVATE, write one byte (copy-on-write: must NOT count as a writer)
//   mmapwc   mmap PROT_READ|PROT_WRITE MAP_SHARED, then minherit(VM_INHERIT_COPY): a writable mapping that WRITES the
//            file although its inheritance says "copy" (must count as a writer: the SM_COW confirmation decides)
//   evtonly  open O_EVTONLY (never blocks an unmount; must NOT be reported)
// Built by Tests/fixtures/make-busy-volume.sh into .build/fixtures/duhold. Never touches pages after it reports ready
// (a forced unmount would SIGBUS a page touch).
#include <fcntl.h>
#include <mach/vm_inherit.h>
#include <stdio.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

int main(int argc, char **argv) {
    if (argc != 3) { fprintf(stderr, "usage: duhold fd|fdw|mmap|mmapw|mmapp|mmapwc|evtonly <path>\n"); return 64; }
    const char *mode = argv[1], *path = argv[2];
    int fd = -1;
    if (!strcmp(mode, "fd")) fd = open(path, O_RDONLY);
    else if (!strcmp(mode, "fdw")) fd = open(path, O_WRONLY | O_APPEND);
    else if (!strcmp(mode, "evtonly")) fd = open(path, O_EVTONLY);
    else if (!strcmp(mode, "mmap") || !strcmp(mode, "mmapw")) {
        int w = !strcmp(mode, "mmapw");
        fd = open(path, w ? O_RDWR : O_RDONLY);
        struct stat st;
        if (fd < 0 || fstat(fd, &st) != 0 || st.st_size == 0) { perror(path); return 1; }
        void *p = mmap(NULL, (size_t)st.st_size, PROT_READ | (w ? PROT_WRITE : 0), MAP_SHARED, fd, 0);
        if (p == MAP_FAILED) { perror("mmap"); return 1; }
        close(fd);                       // only the mapping remains
        fd = 0;
    } else if (!strcmp(mode, "mmapwc")) {
        fd = open(path, O_RDWR);
        struct stat st;
        if (fd < 0 || fstat(fd, &st) != 0 || st.st_size == 0) { perror(path); return 1; }
        void *p = mmap(NULL, (size_t)st.st_size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
        if (p == MAP_FAILED) { perror("mmap"); return 1; }
        if (minherit(p, (size_t)st.st_size, VM_INHERIT_COPY) != 0) { perror("minherit"); return 1; }
        close(fd);
        fd = 0;
    } else if (!strcmp(mode, "mmapp")) {
        fd = open(path, O_RDONLY);
        struct stat st;
        if (fd < 0 || fstat(fd, &st) != 0 || st.st_size == 0) { perror(path); return 1; }
        char *p = mmap(NULL, (size_t)st.st_size, PROT_READ | PROT_WRITE, MAP_PRIVATE, fd, 0);
        if (p == MAP_FAILED) { perror("mmap"); return 1; }
        p[0] = 1;                        // private copy of the page; the file is never written
        close(fd);
        fd = 0;
    } else { fprintf(stderr, "unknown mode %s\n", mode); return 64; }
    if (fd < 0) { perror(path); return 1; }
    printf("ready %s %d\n", mode, getpid());
    fflush(stdout);
    for (;;) pause();
}
