# App icon

`AppIcon.icon` is the Icon Composer source. Its `Folder.png` artwork is also used to generate the
multi-size `AppIcon.icns` fallback.

Open `AppIcon.icon` in Icon Composer to edit the artwork. Keep its ICNS export in sync when changing the design.

`scripts/build.sh` runs `scripts/build-icon.py` before signing. Xcode’s `actool` compiles the layered source into
`Assets.car` for the system’s default, dark and tinted appearances. The bundle also includes the ICNS
fallback, and the compiler’s icon metadata is merged into its `Info.plist`. No Xcode project is needed.
