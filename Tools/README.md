# Tools

`make-icon.swift` draws Ejectable's app icon with CoreGraphics (an orange external drive with an eject mark on a light
tile; no SF Symbol artwork, whose licence excludes app icons) and writes `Resources/AppIcon.icns` through `iconutil`.

```sh
swift Tools/make-icon.swift                                  # regenerate Resources/AppIcon.icns
swift Tools/make-icon.swift /tmp/x.icns --preview /tmp/x.png # write elsewhere, plus a 1024 px preview PNG
```

`build.sh` copies the committed `.icns` into the app bundle; run this only when the artwork changes.
