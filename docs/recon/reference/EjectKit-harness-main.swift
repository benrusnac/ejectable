import Foundation
import DiskArbitration
// test harness: testmain scan <vol> | testmain eject <vol> [--force]   (eject only allowed on DUTEST* volumes)
let a = CommandLine.arguments
if a[1] == "scan" {
    let t0 = Date(); let r = scanVolumeHolders(a[2])
    print("scan \(a[2]): \(r.holders.count) holders, \(r.denied.count) denied, \(Int(Date().timeIntervalSince(t0)*1000))ms")
    for h in r.holders { print("  \(h.pid) uid=\(h.uid) \(h.app?.localizedName ?? (h.executable as NSString).lastPathComponent) \(h.reasons)") }
} else {
    precondition(["/Volumes/DUTESTEXFAT", "/Volumes/DUTESTHFS", "/Volumes/DUTESTAPFS"].contains(a[2]), "refusing")
    let s = DASessionCreate(nil)!; DASessionSetDispatchQueue(s, .main)
    let t0 = Date()
    ejectLikeFinder(volumePath: a[2], force: a.contains("--force"), session: s) { r in
        print("ejectLikeFinder(\(a[2])) -> \(r) after \(Int(Date().timeIntervalSince(t0)*1000))ms")
        if case .busy = r { for h in scanVolumeHolders(a[2]).holders { print("  holder \(h.pid) \(h.executable) \(h.reasons)") } }
        exit(0)
    }
    dispatchMain()
}
