# Matched userdata profile

21 October 2026. Fedora Rawhide AArch64, Uke / SM7675.

The `-singleboot` child RPM belongs to the same source family as its kernel,
modules, DTBs and boot containers. It selects the matching F2FS userdata image
through a descriptor and the family's existing boot symlink. The descriptor is
generated from the source family's kernel ABI; it cannot select another build.

Installing the profile performs no partition write, activation or reboot.
The original guarded updater, root classification, recovery route and separate
physical acceptance requirements remain in force. Package/build success does
not establish suspend, VRR or physical boot acceptance.
