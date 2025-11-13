# U-boot for PSC firmware management

## Introduction
ALS-U controls has planed to deploy hundreds of power supply controller for AR and SR.
We employed the u-boot to manage the firmwares for the different PSC kinds centrally.

Here's a brief description of the PSC unit's boot process:

1. When the system powered on, it reads the `u-boot` boot loader in the `Flash memory`.
2. u-boot sends the DHCP request to obtain the local ip address, TFTP server ip address and the boot script name
3. DHCP sends back these information to the requesters per ethenet address
4. u-boot executes the boot script that downloads the FPGA bit file and ELF file from the TFTP server
5. if necessary, u-boot updates the Flash memory with the downloaded bit and elf file
6. u-boot programs the FPGA and start the PSC application

![alt text](./psc_uboot_flow.png)

This approach requires DHCP and TFTP server in the network.
Each device should have uinque MAC and IP address.

To achieve the goal, we prepared following topics :
- [U-boot boot loader and environment script](#u-boot-boot-loader-and-environment-script)
- [TFTP boot script](#tftp-boot-script)
- [DHCP configuration](#dhcp-server-configuration)
- [PSC FreeRTOS app](#psc-freertos-app)
- [QSPI Flash update with SD card](#qspi-flash-update-with-sd-card)

<br>

## Prerequisites
*This document doesn't describe how to prepare/setup the prerequisites*

To get fully configured system you need to prepare following things :

- A well planned list of the unit name, Ethernet address, IP address
- Ubuntu 22, 24, Debian 12, Rocky 8.10
- Xilinx Environment: tested on 2020.2, likely a loose dependency
- SD card
- TFTP and DHCP server
- A screw driver to open the chassis cover (and switch the jumper SW1)

__NOTICE__ For thouse who don't want to access to the AMD site then download this squash file which contains Vitis 2020.2 and deploy into your /opt. 
This file size is 36 GB : [Vivado squash file](https://drive.google.com/file/d/163ZJ_rJzZPckpBfzCukem66jI8zC2MGq/view?usp=drive_link)

<br>

## U-boot boot loader and environment script
We utilize the `SD card` to write the `Flash memory` with U-boot. 
We are going to generate the boot loader and the scripts to configure the boot sequence.
*NOTE that the SD card is only used once to write the Flash memory.* 
 
- BOOT.bin     -- boot loader
- BOOT.env    -- a script to program the Flash memory
- QSPI.env -- to be dumped to Flash memory

<br>

[Picozed 7030 SOM](https://www.avnet.com/opasdata/d120001/medias/docus/126/$v2/5279-UG-PicoZed-7015-7030-V2_0.pdf) contains 16 MB (256MiB) of Flash memory which is enough space to hold not only the u-boot binary but also FPGA bit, PSC elf and other environment scripts.
Here's our plan for the 16 MB of Flash memory area

| Begin | End | Contents | Size |  NOTE |
| :--- | :--- | :--- | :--- | :-- |
| 0x000000 | 0x0FFFFF | BOOT.bin | 1MB |  U-boot boot loader |
| 0x100000 | 0x11FFFF | QSPI.env | 128KB |  QSPI Flash boot script |
| 0x120000 | 0x13FFFF | qspiboot-redund.env | 128KB | copy of QSPI.env |
| 0x200000 | 0x7FFFFF | psc.bit | 6MB | FPGA bitstream |
| 0x800000 | 0xAFFFFF | psc.elf | 2MB | PSC FreeRTOS application |
| 0xB00000 | 0xFFFFFF | Free space | 4MB | PSC unit parameters (calibration, FOFB network etc.,) |

__NOTICE__ --> PSC shipped to LBNL contains the PSC calibration data in the Flash memory address from 0x10000 to 0x4FFFF. We'd like to move the data with offset 0xB00000.

<br>
Let's start with Build U-boot image
<br>
<br>


## Build U-Boot image

Build U-Boot for Power Supply Controller,
based on [Picozed 7030 SOM](https://www.avnet.com/opasdata/d120001/medias/docus/126/$v2/5279-UG-PicoZed-7015-7030-V2_0.pdf) (Zynq-7000)

For more detail about u-boot, see upstream u-boot [README](README).

<br>

### <a name="fsbl"></a> Build fsbl.elf

Generate `fsbl.elf` with generate_fsbl.tcl in this repo:

```sh
# Debian system dependencies
sudo apt-get install git libssl-dev uuid-dev libgnutls28-dev
# If you system is Rocky Linux and in case when you encountered this error : "xlsclients is not available on the system" 
sudo dnf install xorg-x11-utils xorg-x11-app

# Common build steps
git clone ssh://git@git-local.als.lbl.gov:8022/alsu/configuration/u-boot.git

cd u-boot

# Assuming your xilinx environment is under /opt/Xilinx/Vitis
source /opt/Xilinx/Vitis/<Version>/settings64.sh

xsct -norlwrap generate_fsbl.tcl picozed xsa/System.xsa 
```

Now you should have `fsbl.elf`.

<br>

### Build U-boot


```sh
# Assuming you're in u-boot folder
make ARCH=arm CROSS_COMPILE=arm-linux-gnueabihf- distclean

make ARCH=arm CROSS_COMPILE=arm-linux-gnueabihf- xilinx_zynq_picozed_psc_defconfig

make ARCH=arm CROSS_COMPILE=arm-linux-gnueabihf- all
```

Result `u-boot.elf`.

<br>

### Assemble BOOT.bin

To create a bootable image, the resulting `u-boot.elf`
needs to be combined with an `fsbl.elf` using the `bootgen` tool.

```sh
# create uboot.bif
u_boot:
{
        [bootloader]fsbl.elf
        u-boot.elf
}

# generate bin files
bootgen -arch zynq -image uboot.bif -w -o BOOT.bin
```

`BOOT.bin` should now be exist.



<br>

### Generate initial environment: BOOT.env, QSPI.env
At this step we are going to create **environment binaries** for SD card and Flash memory.\
Let's prepare `bootenv_sd.txt` as follows and generate `BOOT.env` and `BOOT-REDUND.env` first.


```sh
#bootenv_sd.txt:

bootdelay=5
autostart=n
autoload=n
ubootfile=BOOT.bin
ubootenv=QSPI.env
memaddr=0x30000000
envaddr=0x30100000
ubootbinsize=0x100000
ubootenvsize=0x20000

bootcmd= echo "Writing Flash Rom"; \
   fatload mmc 0:1 ${memaddr} ${ubootfile}; \
   fatload mmc 0:1 ${envaddr} ${ubootenv}; \
   sf probe 0 0 0; \
   echo "Move unit parameters to Free space"; \
   sf read 0x38000000 0x10000 0x40000; \
   sf erase 0xB10000 0x40000; \
   sf write 0x38000000 0xB10000 0x40000; \
   echo "writing u-boot"; \
   sf erase 0x0 0x140000; \
   sf write ${memaddr} 0x0 ${ubootbinsize}; \
   echo "write env"; \
   sf write ${envaddr} 0x100000 ${ubootenvsize}; \
   sf write ${envaddr} 0x120000 ${ubootenvsize}; \
   echo "QSPI programming completed.. "
```
__NOTICE__ --> This script will move the existing PSC parameters in the Flash memory from the address of `0x10000` to `0xB10000`. This requires you to adjust the Flash memory offset in the PSC software together. Refer to `qspi_flash.h` and `qspi_flash.c` of [git.als.lbl.gov/alsu/nsls2/psc](https://git.als.lbl.gov/alsu/nsls2/psc).
If PSC already stores the parameters at 0xB10000 then you should use the script as below : 
```sh
#bootenv_sd.txt without data move :

bootdelay=5
autostart=n
autoload=n
ubootfile=BOOT.bin
ubootenv=QSPI.env
memaddr=0x30000000
envaddr=0x30100000
ubootbinsize=0x100000
ubootenvsize=0x20000

bootcmd= echo "Writing Flash Rom"; \
   fatload mmc 0:1 ${memaddr} ${ubootfile}; \
   fatload mmc 0:1 ${envaddr} ${ubootenv}; \
   sf probe 0 0 0; \
   echo "writing u-boot"; \
   sf erase 0x0 0x140000; \
   sf write ${memaddr} 0x0 ${ubootbinsize}; \
   echo "write env"; \
   sf write ${envaddr} 0x100000 ${ubootenvsize}; \
   sf write ${envaddr} 0x120000 ${ubootenvsize}; \
   echo "QSPI programming completed.. "
```

Now create `BOOT.env`

```sh
./tools/mkenvimage -r -s 0x20000 -o BOOT.env bootenv_sd.txt

cp BOOT.env BOOT-REDUND.env
```

You now have `BOOT.env` and `BOOT-REDUND.env`.


__NOTICE__ The `-r` and `-s` arguments must match u-boot build time configuration in `.config`.

The `-r` argument must be passed if `CONFIG_SYS_REDUNDAND_ENVIRONMENT` is enabled (default),
and omitted if it is not.  Failure to do so will result in `bad CRC`.

The value passed to `-s` should match `CONFIG_ENV_SIZE` from the u-boot `.config`.

__NOTICE__ The selection of 0x38000000 as the temporary load address must not
overlap with any of the address ranges used by `psc.elf`.
See `readelf` for details.

<br>

Next step is to create the **environment** for Flash memory <a name="qspienv"></a>

```sh
#bootenv_sf.txt:

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

Replace `xx:xx:xx:xx:xx:xx` with your unit's MAC address. However here's the break point.


For ALS-U deployment we decide not to specify MAC address at this stage but just to use 00:00:00:00:00:00. 
Once technicions update the Flash memory for all PSC units, we are going to change the MAC address one by one through serial terminal.


Now create `QSPI.env`  

```sh
./tools/mkenvimage -r -s 0x20000 -o QSPI.env bootenv_sf.txt
```

If you followed up the procedure correctly, you now have `BOOT.bin`, `BOOT.env`, `BOOT-REDUND.env` and `QSPI.env`. Copy these files to your SD card.

<br>

## TFTP boot script


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
__NOTE 1__: be aware of `bitname` and `elfname` for target location \
__NOTE 2__: you can reprogram the Flash memory by setting `setenv updateflash y` \
__NOTE 3__: you can trasnfer your NET.CNF file to the SD card `setenv updateNETCNF y` 

<br>

Now generate `psc-2ch-hss.scr`
```
./tools/mkimage -A arm -T script -C none -n "PSC-2CH-HSS Boot Script" -d psc_2ch_hss.txt psc-2ch-hss.scr
```

Other scripts (e.g. psc-4ch-mss.scr) can be generated accordingly.

<br>

Now you have psc-2ch-hss.scr, psc-4ch-mss.scr, psc-4ch-msf.scr, psc-4ch-hss.scr and psc-4ch-hsf.scr and move these files to your TFTP root directory
```sh
# Assuming TFTP root directory is /srv/tftp/ 
mv psc-*.scr /srv/tftp/
```

<br>

## DHCP server configuration
/etc/dhcp/dhcpd.conf : check this file if dhcpd.conf has following options configured correctly.

- hardware ethernet: MAC address
- fixed-address: unit's ip address
- next-server: TFTP server ip address
- filename: boot script in the TFTP

Example dhcpd.conf:
```sh
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


<br>

## PSC FreeRTOS app

PSC can read the MAC from the Flash memory at the boot time by adding/modifying these files : 

- local.h
- main.c
- qspi_flash.h
- qspi_flash.c

The changes are available at [git.als.lbl.gov/alsu/nsls2/psc](https://git.als.lbl.gov/alsu/nsls2/psc)

Once the firmware is compiled then copy the bit and elf files to TFTP root folder


## QSPI Flash update with SD card 

1. Connect the serial cable and open the terminal
2. Open the chassis cover and check the jumper switch (SW1) is in `SD CARD BOOT MODE`.[^1]
3. Insert the SD card and power on. Wait for 30 second and check the terminal.[^2]
4. Power Off and change the jumper to `QSPI BOOT MODE`
5. Close the chassis cover and power on
6. Check the terminal. Here's `break point`:
   -  Boot process should be done if you set your MAC address in `QSPI.env`: Refer to [generate initial environment](#qspienv)
   -  Boot process failed if you didn't set. You should reboot and press any key within 5 secs before entering auto boot: Refer to the [next section](#if-your-flash-contains-incorrect-mac-address)


[^1]: Refer to Figure 5 of the page 28 of [Picozed 7030 SOM](https://www.avnet.com/opasdata/d120001/medias/docus/126/$v2/5279-UG-PicoZed-7015-7030-V2_0.pdf) manual.

[^2]: Remove the SD card from the slot. However, the SD card can remain in the slot if PSC looks for the NET.CNF file in the SD card for network configuration.

### If your Flash contains incorrect MAC address
Intended or unintended you didn't set the correct MAC address then you can correct it
through the serial terminal. 

```sh
sf probe
# here assuming your MAC is 00:11:22:33:44:55
setenv -f ethaddr 00:11:22:33:44:55
saveenv   # save environment to env redundant area
saveenv   # save environment to env area
```
you need to type saveenv twice. 

and verify if your variable is set or not by dumping Flash memory:
```sh
sf read 0x36000000 0x100000 0x10000

md 0x36000000
```

The output looks like this...
```sh
Zynq> sf probe
SF: Detected n25q128a13 with page size 256 Bytes, erase size 64 KiB, total 16 MiB
Zynq> setenv -f ethaddr 00:11:22:33:44:55
Zynq> saveenv
Saving Environment to SPIFlash... Erasing SPI flash...Writing to SPI flash...done
Valid environment: 2
OK
Zynq> saveenv
Saving Environment to SPIFlash... Erasing SPI flash...Writing to SPI flash...done
Valid environment: 1
OK
Zynq> sf read 0x36000000 0x100000 0x10000
device 0 offset 0x100000, size 0x10000
SF: 65536 bytes @ 0x100000 Read: 
OK
Zynq> md 0x36000000
36000000: df40c609 74756101 616f6c6f 006e3d64  ..@..autoload=n.
36000010: 6f747561 72617473 006e3d74 73746962  autostart=n.bits
36000020: 3d657a69 30367830 30303030 6f6f6200  ize=0x600000.boo
36000030: 646d6374 6e75723d 74656e20 6f6f625f  tcmd=run net_boo
36000040: 7c7c2074 6e757220 70737120 6f625f69  t || run qspi_bo
36000050: 7c20746f 6365207c 22206f68 41544146  ot || echo "FATA
36000060: 41203a4c 62206c6c 20746f6f 72756f73  L: All boot sour
36000070: 20736563 6c696166 222e6465 6f62003b  ces failed.";.bo
36000080: 6564746f 3d79616c 6c650035 7a697366  otdelay=5.elfsiz
36000090: 78303d65 30303032 65003030 64616874  e=0x200000.ethad
360000a0: 303d7264 31313a30 3a32323a 343a3333  dr=00:11:22:33:4
360000b0: 35353a34 74646600 746e6f63 616c6f72  4:55.fdtcontrola
360000c0: 3d726464 66616533 30353737 6d656d00  ddr=3eaf7750.mem
360000d0: 72646461 3378303d 30303030 00303030  addr=0x30000000.
360000e0: 5f74656e 746f6f62 20200a3d 68636520  net_boot=.   ech
360000f0: 2d22206f 4c202d2d 6964616f 6620676e  o "--- Loading f
Zynq>
```

<br>

## Appendix

### Network boot

Example output for network boot

```sh
U-Boot 2024.01-psc-gcab72928-dirty (Nov 12 2025 - 17:00:05 -0800)

CPU:   Zynq 7z030
Silicon: v3.1
Model: Zynq PicoZed Board
DRAM:  ECC disabled 1 GiB
Core:  19 devices, 15 uclasses, devicetree: board
Flash: 0 Bytes
NAND:  0 MiB
MMC:   mmc@e0100000: 0
Loading Environment from SPIFlash... SF: Detected n25q128a13 with page size 256 Bytes, erase size 64 KiB, totalB
OK
In:    serial@e0001000
Out:   serial@e0001000
Err:   serial@e0001000
Net:   
ZYNQ GEM: e000b000, mdio bus e000b000, phyaddr 0, interface rgmii-id
eth0: ethernet@e000b000
Hit any key to stop autoboot:  0 
--- Loading firmware from Network ---
BOOTP broadcast 1
DHCP client bound to address 10.16.18.184 (1 ms)
Using ethernet@e000b000 device
TFTP from server 10.16.18.12; our IP address is 10.16.18.184
Filename 'psc-4ch-hss.scr'.
Load address: 0x30000000
Loading: #
         260.7 KiB/s
done
Bytes transferred = 1335 (537 hex)
## Executing script at 30000000
--- Loading firmware from Network ---
BOOTP broadcast 1
DHCP client bound to address 10.16.18.184 (1 ms)
Loading bitstream from TFTP...
Using ethernet@e000b000 device
TFTP from server 10.16.18.12; our IP address is 10.16.18.184
Filename 'psc/psc-4ch-hss.bit'.
Load address: 0x31000000
Loading: #################################################################
         #################################################################
         #################################################################
         #################################################################
         #################################################################
         #################################################################
         ##################
         14.7 MiB/s
done
Bytes transferred = 5980015 (5b3f6f hex)
Loading ELF from TFTP...
Using ethernet@e000b000 device
TFTP from server 10.16.18.12; our IP address is 10.16.18.184
Filename 'psc/psc-4ch-hss.elf'.
Load address: 0x32000000
Loading: #################################################################
         #################################################################
         #######
         14.8 MiB/s
done
Bytes transferred = 2000864 (1e87e0 hex)
Writing bitstream into FPGA...
  design filename = "top;UserID=0XFFFFFFFF;Version=2022.2"
  part number = "7z030sbg485"
  date = "2025/09/04"
  time = "12:10:50"
  bytes in bitstream = 5979916
zynq_align_dma_buffer: Align buffer at 31000063 to 31000040(swap 1)
INFO:post config was not run, please run manually if needed
## Starting application at 0x00100000 ...
Power Supply Controller
Module ID Number: E1C00100
Module Version Number: 91
Project ID Number: E1C00010
Project Version Number: 91
Git Checksum: 22AC09D9
Project Compilation Timestamp: 2025-09-04 18:50:25
Si570 Registers before re-programming...
Read si570 registers
Stat: 0:   val0:21  
Stat: 0:   val0:C2  
Stat: 0:   val0:BC  
Stat: 0:   val0:10  
Stat: 0:   val0:EB  
Stat: 0:   val0:9E  

Si570 Registers after re-programming...
Read si570 registers
Stat: 0:   val0:0  
Stat: 0:   val0:C2  
Stat: 0:   val0:BB  
Stat: 0:   val0:BE  
Stat: 0:   val0:6E  
Stat: 0:   val0:69  


Reading PSC Settings from EEPROM...
Invalid Number of Channel Setting...
Invalid Resolution Setting...
Invalid Bandwidth Setting
Invalid Polarity Setting


Resetting EVR GTX...
Setting FOFB IP Address to 10.0.142.100...
Main thread running
Decoded MAC address from U-Boot env: 00:19:24:00:21:02
MAC: 00:19:24:00:21:02
Start PHY autonegotiation 
Waiting for PHY to complete autonegotiation.
autonegotiation complete 
link speed for phy address 0: 1000
unable to determine type of EMAC with baseaddress 0xE000B000
DINFO: Starting HFO: Starting ststats daemon
Iaz datNFO: Starting 10Hz data daemon
INFO: Starting Snapshot data daemon
INFO: Starting console daemon
Server ready on port 3000
Running PSC Menu (len = 11)

Select an option:
  A:  Display PSC Settings
  B:  Set Number of Channels (2 or 4)
  C:  Set Resolution (High or Medium)
  D:  Set Bandwidth (Fast or Slow)
  E:  Set Polarity (Bipolar or Unipolar)
  F:  Display Snapshot Stats
  G:  Print FreeRTOS Stats
  H:  Dump EEPROM
  I:  Clear EEPROM
  J:  Test EEPROM
  K:  Dave Bergman Calibration Mode
  Q:  quit
DHCP address assigned: 10.16.18.184/255.255.255.0 gw: 10.16.18.1

```

