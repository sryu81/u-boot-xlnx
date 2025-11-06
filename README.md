# U-boot for PSC firmware management

## Introduction
ALS-U controls has planed to deploy hundreds of power supply controller for AR and SR.
We employed the u-boot to manage the firmware for the different PSC kinds centrally.

Here's a brief description of the PSC unit's boot process:

1. System powered on it reads the `u-boot` in the `Flash memory`.
2. u-boot sends the DHCP request to obtain the local ip address, TFTP server ip address and the boot script name
3. DHCP sends back these information to the requesters per ethenet address
4. u-boot executes the boot script that downloads the FPGA bit file and ELF file from the TFTP server
5. if necessary, u-boot updates the Flash memory with the downloaded bit and elf file
6. u-boot programs the FPGA and start the PSC application

This approach requires DHCP and TFTP server in the network.
Each device should have uinque MAC and IP address.

## Prerequisite
*This document doesn't describe how to prepare/setup the prerequisites*

To get fully configured system you need to prepare following things :

- A well planned list which contains the unit name, Ethernet address, IP address
- Ubuntu 22 / Debian 12 system (Rocky is not recommended) with Xilinx Environment > 2020.2
- SD card : this is only used for updating the flash memory at the beginning
- TFTP and DHCP server in your network : configuration for u-boot setup will be described in the following sections
- A screw driver to open the chassis cover (and switch the jumper SW1)

For thouse who can't access to the AMD site then download this squash file and deploy into your /opt. Be aware this is 36 GB : [Vivado squash file](https://drive.google.com/file/d/163ZJ_rJzZPckpBfzCukem66jI8zC2MGq/view?usp=drive_link)


## Preparation

We are going to use `SD card` to install u-boot to the `Flash memory`.
So we need 2 uboot binaries, one for SD card booting and the other for QSPI booting, and their relevant environment files.
We have 4 things to follow up as below


### 1. u-boot images for SD card

Files to prepare:
- BOOT.bin
- uboot.env, uboot-redund.env

Refer to [U-boot Image preparation](#ubootimage) section for more detail.
These files should be copied to SD card.

---
### 2. u-boot images for Flash memory
[Picozed 7030 SOM](https://www.avnet.com/opasdata/d120001/medias/docus/126/$v2/5279-UG-PicoZed-7015-7030-V2_0.pdf) contains 16 MB (256MiB) of Flash memory which is enough space to hold not only the u-boot binary but also FPGA bit, PSC elf and other environment scripts. We are going to use a **SD card** to program it only once at the beginning. Once it is updated then **SD card is no longer needed** for booting. [^1]

Files to prepare:
- qspiboot.bin
- qspiboot.env

Refer to [U-boot Image preparation](#ubootimage) section for more detail. These files should be copied to SD card.

---
### 3. boot scripts for TFTP server
We need 5 psc boot scripts:
- psc-2ch-hss.scr
- psc-4ch-mss.scr
- psc-4ch-msf.scr
- psc-4ch-hss.scr
- psc-4ch-hsf.scr

Refer to [Generate boot scripts](#bootscript) section.
These files should be in the tftp root directory. (e.g. /srv/tftp/ )

---
### 4. DHCP server configuration
/etc/dhcp/dhcpd.conf : check this file if dhcpd.conf has following options configured correctly.

- hardware ethernet: MAC address
- fixed-address: unit's ip address
- next-server: TFTP server ip address
- filename: boot script in the TFTP

Example dhcpd.conf:
```
subnet 10.16.18.0 netmask 255.255.255.0 {
    option subnet-mask 255.255.255.0;
    option broadcast-address 10.16.255.255;  # broadcast to other subnets
    option domain-name "als.private.lbl.gov";
    option routers 10.16.18.1;               # check correct router to use

    host psc-01 {
        hardware ethernet 00:19:24:00:21:01;      
        fixed-address 10.16.17.11;         # ip address to be assigned to psc
        next-server 10.16.18.12;           # TFTP server ip address
        filename "psc-2ch-hss.scr";        # boot script in the TFTP
    }

    host psc-02 {
        hardware ethernet 00:19:24:00:21:02;
        fixed-address 10.16.17.12;
        next-server 10.16.18.12;
        filename "psc-4ch-mss.scr";
    }  
    
    ...

    host psc-FF {
        hardware ethernet 00:19:24:00:23:FF;
        fixed-address 10.16.17.12;
        next-server 10.16.18.12;
        filename "psc-4ch-hss.scr";
    }
}

```
__NOTICE__ Check firewall setting and routers to receive/send dhcp request and response packets between the different subnets.


---
### 5. QSPI Flash Memory Map


| Begin | End | Contents | Size |
| :--- | :--- | :--- | :--- |
| `0x000000` | `0x0FFFFF` | BOOT.bin | 1MB |
| `0x100000` | `0x11FFFF` | uboot.env | 128KB |
| `0x120000` | `0x13FFFF` | uboot_redun.env | 128KB |
| `0x200000` | `0x7FFFFF` | psc.bit | 6MB |
| `0x800000` | `0xAFFFFF` | psc.elf | 2MB |
| `0xB00000` | `0xFFFFFF` | Free space | 4MB |

**Free space should be used for the PSC calibration and configuration parameters**

---
## <a name="ubootimage"></a> U-boot Image preparation

Build U-Boot for Power Supply Controller,
based on [Picozed 7030 SOM](https://www.avnet.com/opasdata/d120001/medias/docus/126/$v2/5279-UG-PicoZed-7015-7030-V2_0.pdf) . (Zynq-7000)

For more detail about u-boot, see upstream u-boot [README](README).

---

### Requirements

- Xilinx Vitis (tested on 2020.2, likely a loose dependency)
- A `fsbl.elf` generated by Vitis along with the target application
- You should also generate the other version of `fsbl.elf` using generate_fsbl.tcl in the following section

### <a name="fsbl"></a> Build fsbl.elf
You need two different `fsbl.elf`, one for SD card boot and the other for QSPI boot. 

`fsbl.elf` in the Vivado project doesn't support QSPI boot. 

1. bring your `fsbl.elf` from your Vivado/Vitis project and change the name to `fsbl_sd.elf`

2. generate `fsbl_sf.elf` with following method:

```sh
source /opt/Xilinx/Vitis/<Version>/settings64.sh

xsct -norlwrap generate_fsbl.tcl picozed xsa/System.xsa 

cp picozed/System/fsbl/Debug/fsbl.elf ./fsbl_sf.elf
```

Now you should have `fsbl_sd.elf` and `fsbl_sf.elf` 

### <a name="builduboot"></a>  Build u-boot

Tested on Rocky8.10, Debian 12 and Ubuntu 24.01 LTS

```sh
# Debian system dependencies
sudo apt-get install git libssl-dev uuid-dev libgnutls28-dev

# Rocky 8.10
sudo dnf install 

# Common build steps
git clone ssh://git@git-local.als.lbl.gov:8022/alsu/configuration/u-boot.git

cd u-boot

# Assuming your xilinx environment is under /opt/Xilinx/Vitis

source /opt/Xilinx/Vitis/<Version>/settings64.sh

make ARCH=arm CROSS_COMPILE=arm-linux-gnueabihf- distclean

make ARCH=arm CROSS_COMPILE=arm-linux-gnueabihf- xilinx_zynq_picozed_psc_defconfig

make ARCH=arm CROSS_COMPILE=arm-linux-gnueabihf- all
```

Result `u-boot.elf`.

---

### <a name="assemblebin"></a> Assemble BOOT.bin, qspiboot.bin

To create a bootable image, the resulting `u-boot.elf`
needs to be combined with an `fsbl.elf` using the `bootgen` tool.

```sh
# create u-boot_sd.bif
u_boot:
{
        [bootloader]fsbl_sd.elf
        u-boot.elf
}

#create u-boot_sf.bif
u_boot:
{
        [bootloader]fsbl_sf.elf
        u-boot.elf
}

# generate bin files
bootgen -arch zynq -image u-boot_sd.bif -w -o BOOT.bin
bootgen -arch zynq -image u-boot_sf.bif -w -o qspiboot.bin
```

`BOOT.bin` and `qspiboot.bin` should now be exist.

---

### <a name="generateenv"></a> Generate initial environment: uboot.env, qspiboot.env

Create a file `uboot_env_sd.txt` and `uboot_env_sf.txt` with the following initial contents.


```sh
#uboot_env_sd.txt:

bootdelay=5
autostart=n
autoload=n
ubootfile=qspiboot.bin
ubootenv=qspiboot.env
memaddr=0x30000000
envaddr=0x30100000
ubootbinsize=0x100000
ubootenvsize=0x20000

bootcmd= echo "Writing Flash Rom"; \
   fatload mmc 0:1 ${memaddr} ${ubootfile}; \
   fatload mmc 0:1 ${envaddr} ${ubootenv}; \
   sf probe 0 0 0; \
   echo "Move unit parameters to Free space"; \
   sf read 0x38000000 0x0 0x40000; \
   sf erase 0xB00000 0x40000; \
   sf write 0x38000000 0xB00000 0x40000; \
   echo "writing u-boot"; \
   sf erase 0x0 0x140000; \
   sf write ${memaddr} 0x0 ${ubootbinsize}; \
   echo "write env"; \
   sf write ${envaddr} 0x100000 ${ubootenvsize}; \
   sf write ${envaddr} 0x120000 ${ubootenvsize}; \
   echo "QSPI programming completed.. "
```

Now create `uboot.env`  : before creating this check `.config` first!!! 

```sh
./tools/mkenvimage -r -s 0x20000 -o uboot.env env.txt

cp uboot.env uboot-redund.env
```

__NOTICE__ The `-r` and `-s` arguments must match u-boot build time configuration in `.config`.

The `-r` argument must be passed if `CONFIG_SYS_REDUNDAND_ENVIRONMENT` is enabled (default),
and omitted if it is not.  Failure to do so will result in `bad CRC`.

The value passed to `-s` should match `CONFIG_ENV_SIZE` from the u-boot `.config`.

__NOTICE__ The selection of 0x38000000 as the temporary load address must not
overlap with any of the address ranges used by `psc.elf`.
See `readelf` for details.


```sh
#uboot_env_sf.txt:

ethaddr=xx:xx:xx:xx:xx:xx
bootdelay=5
autostart=n
autoload=n
memaddr=0x30000000
bitsize=0x600000
elfsize=0x200000

net_boot=\
   echo "--- Loading firmware from Network ---";\
   dhcp;\
   tftpboot ${memaddr} ${bootfile};\
   source ${memaddr}

qspi_boot=\
   echo "--- Loading from QSPI Flash ---"; \
   sf probe 0 0 0; \
   sf read ${memaddr} 0x200000 ${bitsize}; \
   fpga loadb 0 ${memaddr} 0x1;\
   sf read ${memaddr} 0x800000 ${elfsize}; \
   setenv autostart y; \
   bootelf ${memaddr};

bootcmd=run net_boot || run qspi_boot || echo "FATAL: All boot sources failed.";
```

Replace `xx:xx:xx:xx:xx:xx` with actual device MAC address.


### <a name="bootscript"></a> Generate boot script : psc-xch-xxx.scr


Here's the example of `psc-2ch-hss.txt` :

```sh
#memaddr=0x30000000
#bitsize=0x600000
#elfsize=0x200000

setenv bitname psc/psc-2ch-hss.bit
setenv elfname psc/psc-2ch-hss.elf

setenv bitaddr 0x31000000
setenv elfaddr 0x32000000

setenv autostart n
setenv autoload n
setenv updateflash n
setenv updateNETCNF n

echo "--- Loading firmware from Network ---"
dhcp
echo "Loading bitstream from TFTP..."
tftpboot ${bitaddr} ${bitname}
echo "Loading ELF from TFTP...";
tftpboot ${elfaddr} ${elfname};

if test "${updateflash}" = "y"; then
    echo "Updating the firmware in your flash memory is enabled. Executing commands..."
    sf probe 0 0 0;
    echo "write FPGA bitstream to Flash memory";
    sf erase 0x200000 ${bitsize};
    sf write ${bitaddr} 0x200000 ${bitsize};
    echo "write ELF executable to Flash memory";
    sf erase 0x800000 ${elfsize};
    sf write ${elfaddr} 0x800000 ${elfsize};
    echo "Update finished"
fi

if test "${updateNETCNF}" = "y"; then
    echo "Updating the NET.CNF in SD card is enabled. Executing commands..."
    mmc info;
    tftpboot 0x33000000 psc/NET.CNF;
    md 0x33000000;
    fatwrite mmc 0:1 0x33000000 NET.CNF $filesize;
    echo "Update finished";
fi

echo "Writing bitstream into FPGA...";
fpga loadb 0 ${bitaddr} ${filesize};

setenv autostart y
bootelf ${elfaddr}
```

Now generate `psc-2ch-hss.scr` and `psc-4ch-hss.scr`
```
./tools/mkimage -A arm -T script -C none -n "PSC-2CH-HSS Boot Script" -d psc_2ch_hss.txt psc-2ch-hss.scr
./tools/mkimage -A arm -T script -C none -n "PSC-4CH-HSS Boot Script" -d psc_4ch_hss.txt psc-4ch-hss.scr
```

__NOTICE__: you can reprogram the Flash memory by setting `setenv updateflash y`

---

## U-boot Deployment

1. Copy boot scripts (psc-Xch-XXX.scr) to the TFTP root folder
2. Format the SD card with FAT and copy the following files : 
   - `BOOT.bin`   - FSBL + u-boot
   - `uboot.env`, `uboot-redund.env` - SD card environment
   - `qspiboot.bin` - FSBL + u-boot
   - `qspiboot.env` - Flash environment
3. Connect the serial cable and open the terminal
4. Open the chassis cover and check the jumper switch (SW1) is in `SD CARD BOOT MODE` : Refer to Figure 5 of the page 28 of [Picozed 7030 SOM](https://www.avnet.com/opasdata/d120001/medias/docus/126/$v2/5279-UG-PicoZed-7015-7030-V2_0.pdf) manual. 
5. Insert SD card to the unit and power on. Check the terminal if everything's done
6. Power Off and change the jumper to `QSPI BOOT MODE`
7. Power On and check the terminal if boot process is done


[^1]: However, the SD card should remain in the slot because PSC application look for the NET.CNF file in the SD card for network device setup.