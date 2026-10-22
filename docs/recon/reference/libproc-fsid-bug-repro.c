#include <libproc.h>
#include <sys/proc_info.h>
#include <sys/mount.h>
#include <sys/stat.h>
#include <stdio.h>
#include <stdlib.h>
#include <errno.h>
#include <string.h>
int main(int argc, char **argv) {
    pid_t pid = atoi(argv[1]); const char *vol = argv[2];
    struct statfs sf; statfs(vol, &sf); struct stat st; stat(vol, &st);
    uint64_t fsid64 = (uint64_t)(uint32_t)sf.f_fsid.val[0] | ((uint64_t)(uint32_t)sf.f_fsid.val[1] << 32);
    printf("st_dev=%d (0x%x) f_fsid=[0x%x,0x%x] fsid64=0x%llx\n", st.st_dev, st.st_dev, sf.f_fsid.val[0], sf.f_fsid.val[1], fsid64);
    uint64_t cands[] = { (uint64_t)st.st_dev, fsid64, (uint64_t)(uint32_t)sf.f_fsid.val[0] };
    const char *names[] = {"st_dev", "fsid64", "fsid.val[0]"};
    for (int i = 0; i < 3; i++) {
        struct proc_regionwithpathinfo r; errno = 0;
        int n = proc_pidinfo(pid, 23 /*PROC_PIDREGIONPATHINFO3*/, cands[i], &r, sizeof r);
        printf("REGIONPATHINFO3 arg=%s(0x%llx) -> %d errno=%d %s\n", names[i], cands[i], n, errno, n>0 ? r.prp_vip.vip_path : "");
    }
    return 0;
}
