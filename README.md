# Wg Demo

Worldguard Demo - booting two isolated linuxes, in separate worlds on the same processor

This project is a self contained demonstration of how to use the RISC-V Worldguard feature to 
create two separate 'worlds', and boot an instance of linux in both worlds. These linux instances
are completely isolated from each other, and cannot access parts of each other. 
The mechanics of the isolation are such that the first world (world 0) is unrestricted, and behaves 
as a default configuration. World 1 on the other hand has its own physical address space, and has permissions
that only allow its world to access its memory. The Linux that boots in this world is quite limited. It 
contains only memory, a ramdisk, and a network apaptor. For both Linuxes, the initramfs image contains 
a busybox based set of userland and runtime code. Each utility is just a symbolic link to a statically linked busybox. 


## Name
Choose a self-explaining name for your project.

## Description

This project demonstrates address space isolation using the Worldguard feature of the RISC-V processor. 
At runtime, a docker container exexcutes which starts the QEMU simulator which starts up a RISC-V processor
with two harts, or cores. The OpenSBI system binary API runs to set up each hart, setting up two different
'world ids',creating two different memory areas, and subsequently branches to
a linux kernel for hart 0. Also, hart 1 evenually executes another linux kernel which is physically isolated from 
the first kernel. The system on hart 1 has only a ramdisk, memory, and a virtual network device. Hart 0's system 
has more of a default linux system, with an actual physical disk, memory, network devices, etc. On execution, the container
has an entrypoint of 'boot.sh', you will see the boot process for the hart 0 system as it starts up. In a separate 
terminal, you can 'telnet localhost 2323' to gain access to the console of the hart 1 system.  
The build process works as follows.
Using docker, we build a container called 'builder', within this container, we install all the requisite
packages required to complete the build. This is all based upon Ubuntu 22.04. First, we check out the qemu source tree 
from https://github.com/cwshu/qemu. This is Jim Shu's repo, he is at sifive.A branch there called 'riscv-wg-v4-alpha' is checked out. 
We then build qemu with a traget list of riscv64-softmmu. 
Next, we check out opensbi, from https://github.com/riscv-software-src/opensbi.git. We use the master branch. 
Next a patch process is run under python, using apply_wg_patch.py. This injects a world 1 boot block in fw_base.S in the firmware 
directory of the opensbi source tree. 
Next, we build opensbi code under the cross compile environment (riscv64-linux-gnu-). The creates fw_jump.bin. 
The next step is to wget  and build the linux kernel from https://cdn.kernel.org/pub/linux/kernel/v6.x/linux6.6/tar.xz..
We cross compile this as well. 
The next step is to clone busybox, from https://git.busybox.net/busybox. We create a cross compiled, statically linked instance 
of busybox, which will serve as entire userland utility code for both instances of linux running on the processor. 
There are init scripts for each world, as well as a selftest.sh program copied into the build directory for each hart's
space. Next, we build an initramfs image for each world, creating rootfs images and using cpio to emit images. 
The next and final step in the build process is to create device tree blobs for each linux. This is managed with the dtc program, 
and bases the dtb images on world0.dts and world1.dts, which are found in the docker build directory. 
Finally, a runtime container is built, based on the various componenets in the builder container. The runtime container 
is also based on Ubuntu 22.04. We install a few prerequisite componenets, copy in the qemu binary, the opensbi binary, 
the linxu Image file, both initramfs images, and the device tree files, followed by the boot.sh file. 
Boot.sh is then made executable, and set as the entrypoint for the container. Also, port 2323 is exposed to the outside 
world for access to the world 1 console through telnet. 

Highlights of the qemu bring up environment. Each hart is configured by opensbi with world IDs. WID 0 jumps to 
a linux at 0x80200000, with its console at ttyS0. WID 1, for hart 1 jumps to a linux at 0x88200000 with no console, and 
telnet access or virtio-net at host port 2323. 
When qemu starts, the -M parameter is '-M virt,worlds=on', which enables the worldguard mechanism. The bios blob used 
is fw_jump.bin, from opensbi. Then we load the linux image file (from /opt/wg-demo/Image) for world 0 at 0x80200000
as well as its initramfs blob at 0x84000000. Its dtb blob is loaded with the -dtb option. 
The other linux image, using the same image file is loaded at 0x88200000, with its 
initram image at 0x8c000000. World 1's dtb blob is loaded into memory at 0x8e000000 directly with a -device loader option. 
Finally, the -netdev option creates a tcp device at 2323, mapped out to the host. The -device virtio-net-device is mapped to 
that netdev port so world 1 can communicate with the outside. The -serial option is set to mon:stdio for world 0. 
Additionally, the -trace option just saves all trace information in /tmp/wg-trace.log. 
When the wg-demo container is run, both worlds will boot, the console of world 0 will show up on the default console. The 
console for world 1 can be accessed from another terminal session on the host, using 'telnet localhost 2323'

## Authors and acknowledgment
This project was created by Paul Heath of the Seagate Security Research group, using a few different AI models for examples and collaberation with 
the various parts of the code. 
The packaging of this project, specifically using a Dockerfile, and the docker system to create a single 
build command on nearly any platform, was inspired by an idea from Josip Relota, of the Seagate Security Research 
group. 

## License
For open source projects, say how it is licensed.

## Releases

1.00 - initial commit. container builds and runs properly. System boots and runs. 
1.01 - update to include selftest.sh, which runs on both systems, checking memory access of both worlds. 
       world 0 is unrestricted and trusted. It can see both address spaces.
       world 1 is restricted. It can see itself, but not world 0 address space. 


