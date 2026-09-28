Executive Summary
This research documents a TOCTOU (Time-of-Check Time-of-Use) race condition in the USB DFU implementation of Apple A14 SecureROM. The race allows a malicious USB host (e.g., Raspberry Pi Pico) to corrupt the cached USB device descriptor of an iPhone in DFU mode, forcing the host to see a device with idVendor=0000, idProduct=0000.

Impact: DoS on iOS device restore via iTunes/Apple Configurator. The device becomes invisible to the host for ~200 ms, and after power-cycle can be restored normally.

Limitations: The primitive is fixed-size zero-write (10 bytes into dev_desc[8..17]). No control over source or destination was achievable. Not a jailbreak or privilege escalation vector.

Affected: Apple A14 (CPID 0x8101) SecureROM DFU, likely all Apple A-series SecureROM with similar DFU stack.

Disclosure: Recommended to Apple Product Security.

1. Background
1.1 DFU Protocol on Apple SecureROM
Apple SecureROM exposes DFU (Device Firmware Update) interface over USB. Enumeration:

idVendor = 0x05AC (Apple)

idProduct = 0x1227 (DFU Mode)

Serial descriptor (str4) contains CPID:XXXX ... identification

DFU interface supports:

DFU_DNLOAD (bRequest 0x01) — send firmware blocks

DFU_UPLOAD (bRequest 0x02) — read blocks (not supported on A14)

DFU_ABORT (bRequest 0x04)

DFU_CLRSTATUS, DFU_GETSTATE, DFU_GETSTATUS

1.2 The Race Condition
Standard DNLOAD flow:

text
Host: SETUP DNLOAD(wLength=N)  →  Device: ACK  [stores N]
Host: OUT DATA (chunks of 64)  →  Device: ACK  [bytes_received += 64]
... N/64 times
Host: (transfer complete)      →  Device: callback, memcpy(da0, buf, N)
Race trigger:

text
Host: SETUP DNLOAD(wLength=0x40) → Device: ACK  [wLength stored]
Host: SETUP ABORT                 → Device: ACK  [bytes_received = 0, wLength STALE]
Host: OUT DATA (8 bytes)          → Device: timeout, but memcpy(da0, NULL, 0x40) runs
Mechanism:

DNLOAD stores wLength=0x40 in internal state

ABORT resets bytes_received=0 but leaves wLength stale

OUT arrives in DATA phase; SecureROM runs completion callback

Callback checks bytes_received(0) + len ≤ limit → passes

memcpy(da0, hw_buffer, wLength) runs with NULL source (HW buffer cleared)

Result: 64-byte zero-write starting at da0

Observed: Only 10 bytes actually written (buffer padded), da0 = dev_desc + 8.

2. Primitive Characterization
2.1 Detected Behavior
Verified via USB logs:

State	dev_desc[0..17]
Before attack	12 01 00 02 00 00 00 40 AC 05 27 12 00 00 02 03 04 01
After hit (<100ms)	12 01 00 02 00 00 00 40 00 00 00 00 00 00 00 00 00 00
After recovery (~200ms)	12 01 00 02 00 00 00 40 AC 05 27 12 00 00 02 03 04 01
Zerowed bytes: idVendor, idProduct, bcdDevice, iManufacturer, iProduct, iSerialNumber, bNumConfigurations

Preserved bytes: bLength, bDescriptorType, bcdUSB, bDeviceClass, bDeviceSubClass, bDeviceProtocol, bMaxPacketSize

2.2 Trigger Conditions
Hit requires:

DNLOAD with wLength ≥ 0x40

ABORT arriving with hs2 == ACK (not NAK)

OUT with any payload length

Hit detection (soft vs hard):

text
Soft hit: OUT returns hs3=0 (timeout), then probe_alive returns 0 (busy)
Hard hit: OUT returns hs3=0 instantly, ABORT NAK → device dies
2.3 Sweep Results — What Does NOT Affect the Primitive
Parameter	Range tested	Effect
wLength	0x08, 0x10, 0x18, 0x20, 0x40, 0x80, 0x100, 0x200, 0x400, 0x800	Always 10 bytes written
wValue (DNLOAD)	0, 1, 144, 0x8000	No change
wIndex	0, 1	No change
bRequest	0x01, 0x02, 0x03, 0x04, 0x05, 0x0B	Only 0x01 (DNLOAD) triggers
PID	DATA0, DATA1	No change
Payload content	0x00, 0x41, 0xAA, target addr, 00..3F	Always zeros (source = NULL)
Prefill HW buffer	Full or partial	Blocks race
Multi-hit	Sequential	Device dies after first
Conclusion: The primitive is fixed: 10-byte zero-write at dev_desc+8.

3. DoS Attack
3.1 Re-enumeration Window
Key observation: After soft-hit, the corrupted dev_desc persists for ~79 ms before SecureROM restores it from immutable source.

Attack sequence:

text
1. Trigger primitive   (soft-hit → dev_desc[8..17] = 0)
2. USB bus reset       (~70 ms)
3. Re-enumerate        (~9 ms)
4. Query dev_desc      → returns idVendor=0000
Total time from hit to query: 78.9 ms — within the corruption window.

3.2 Practical Impact
Setup: Raspberry Pi Pico as USB proxy between Mac and iPhone (dual USB, or two Picos).

Effect:

Mac sees device with idVendor=0000, idProduct=0000

macOS does not load Apple DFU driver

iTunes/Apple Configurator do not recognize device

Restore operation fails

Recovery: Power-cycle iPhone. Device boots normally.

Persistent DoS? No — primitive is single-shot per boot. After first attempt device enters semi-functional state that does not accept further DNLOAD requests.

4. What Was Exhaustively Ruled Out
To achieve privilege escalation, one of the following would be needed:

Goal	Tested	Result
Control over source (write arbitrary data)	8 methods	Source always NULL
Control over destination (shift da0)	All USB parameters	da0 fixed at dev_desc+8
Control over length (extend beyond 10 bytes)	wLength sweep	Fixed at 10 bytes
Multi-shot (accumulate effect)	Sequential attempts	Device dies after first
Memory disclosure	Deep GET_DESCRIPTOR (512B)	Zeroes beyond descriptor
Reach nonce (str1)	Sweep	Not affected
Reach serial (str4)	Sweep	Not affected
Modify DFU state	GETSTATE/GETSTATUS	Not affected
Exhaustive USB surface sweep performed:

Standard descriptors: device, config, string (0-15), device qualifier, other-speed config, BOS

Class requests: DFU UPLOAD, GETSTATE, GETSTATUS, CLRSTATUS, SET_INTERFACE, SET_CONFIGURATION, SET_ADDRESS

Vendor requests: Apple class 0x40/0xC0, bRequest 0x00-0x0F

LANGID sweep: 16 languages

Huge wLength: up to 1024 bytes

Non-zero wIndex: 0-3

All returned to same primitive behavior.

5. USB Descriptor Reference (A14 SecureROM, CPID 0x8101)
For future researchers:

Device Descriptor (str 0x01, 18 bytes)
text
12 01 00 02 00 00 00 40 AC 05 27 12 00 00 02 03 04 01
Config Descriptor (str 0x02, 32 bytes)
text
09 02 19 00 01 01 05 80 FA 09 04 00 00 00 FE 01 00 00 07 21 01 0A 00 00 08
String Descriptors
str0: langid list 04 03 09 04 (US English)

str1: NONC:XXXXXXXXXX — SecureROM nonce (regenerated per boot)

str2: Apple Inc.

str3: Apple Mobile Device (DFU Mode)

str4: CPID:8101 CPRV:11 CPFM:03 SCEP:01 BDID:0C ECID:001C21023E01001E IBFL:3C SRTG:[iBoot-5281.0.0.100.45]

str5: duplicates str3

str6-15: empty

Device Qualifier (str 0x06)
text
0A 06 00 02 00 00 00 40 01 00
DFU State Machine
Default state: dfuIDLE (0x02)


Conclusion
We identified and characterized a TOCTOU race condition in Apple A14 SecureROM's DFU implementation. The primitive allows a malicious USB host to corrupt the cached device descriptor of an iPhone for ~200 ms, resulting in a re-enumeration DoS.

The race is real, the primitive is real, but the primitive is narrow. After exhaustive parameter sweep, we found no path to privilege escalation. This research is offered as:

A documented vulnerability for Apple to address

Reference material for the DFU/secure-boot research community

A starting point for investigating other SecureROM generations

DFU_GETSTATE returns 1 byte: 02

DFU_GETSTATUS returns 6 bytes: bStatus=00 pollTimeout=320000 bState=02 iString=00
