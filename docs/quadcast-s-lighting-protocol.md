# HyperX QuadCast S RGB Lighting Protocol

A specification for driving the RGB lighting on the HyperX QuadCast S microphone via USB. This protocol is used by the QuadCast S, and likely by some other HyperX/HP microphones sharing the same control interface.

## Device Identification

### USB Devices

The protocol speaks to these vendor and product ID pairs (VID:PID):

| Vendor | Product ID | Notes |
|--------|------------|-------|
| 0x0951 (Kingston) | 0x171F | Kingston-era QuadCast S |
| 0x03F0 (HP) | 0x0F8B | HP QuadCast S variant |
| 0x03F0 (HP) | 0x068C | HP QuadCast S variant |
| 0x03F0 (HP) | 0x028C | HP QuadCast S lighting device |
| 0x03F0 (HP) | 0x048C | HP QuadCast S variant |
| 0x03F0 (HP) | 0x0D8B | HP QuadCast S variant |

**Hardware observation:** The HP QuadCast S enumerates as two separate USB devices behind an internal hub: one for audio (0x03F0:0294) and one for lighting (0x03F0:028C). All lighting communication uses the lighting device only. The audio device (0x0294) is therefore not in the table above: its interface 0 is the USB Audio Control interface, and a discovery pass that took it as the lighting interface would send lighting packets to the audio function.

### Interface

All packets are sent to **interface 0** of the lighting device.

On macOS, interface 0 is declared as HID class but typically has no driver bound by the kernel. Two transport methods are therefore available (see Transport section).

## Transport

Packets are 64-byte HID feature reports with report ID 0. The report ID byte is sent separately from the 64-byte payload (do not include it in the 64 bytes).

### Option A: HID SetReport via IOKit

When the kernel has bound an HID driver to the interface:

- Use `IOHIDDeviceSetReport` with report type `kIOHIDReportTypeFeature` and report ID 0.
- Pass the 64-byte payload (without a leading report-ID byte).
- This is the standard HID path and is tried first.

### Option B: Raw USB Class Request via IOUSBHost

When no HID driver is bound (common on macOS), use a USB class control request:

**Setup packet fields:**

| Field | Value | Meaning |
|-------|-------|---------|
| bmRequestType | 0x21 | Host-to-device, class, interface |
| bRequest | 0x09 | SET_REPORT |
| wValue | 0x0300 | Report type feature (3 << 8), report ID 0 |
| wIndex | 0x0000 | Interface 0 |
| wLength | 64 | Payload size in bytes |

Send the 64-byte payload as the request data.

**Per-transfer timeout:** 1000 ms (1 second).

### Discovery on macOS

Try Option A first, then Option B.

**Option A discovery:** ask the HID manager for devices matching any VID:PID above. Keep only a device whose USB interface number is 0; the `bInterfaceNumber` property may sit on the HID device's service or on one of its registry ancestors, so search upwards. Open it. On the test hardware no such HID device exists, so this path normally finds nothing.

**Option B discovery:** IOKit service matching dictionaries that combine the `IOUSBHostInterface` class with `idVendor`/`idProduct`/`bInterfaceNumber` keys return nothing on macOS 27. Instead:

1. Match on the class name `IOUSBHostInterface` alone and iterate every service.
2. For each service, read its `idVendor`, `idProduct` and `bInterfaceNumber` properties.
3. Keep the first service whose VID:PID is in the table above and whose interface number is 0, and open it as an IOUSBHost interface.

If neither path succeeds, report why (for example "no matching interface present", or the open error per candidate) so the user interface can show it.

### Device Lifecycle

- The lighting device can enumerate, disconnect, and re-enumerate independently of the audio device (for example, during sleep or after a user-initiated disconnect).
- A failed send on either transport indicates the interface handle is dead; the driver must re-discover and re-open it.
- Only one process may stream to the lighting interface at a time. Concurrent streams produce packet interleaving that corrupts the lighting display.

## Packet Formats

All packets are exactly 64 bytes. Bytes not specified below are 0x00.

### Colour Packet (Direct Colours)

Used to set the colours of the two LEDs without saving to the device.

| Offset | Value | Meaning |
|--------|-------|---------|
| 0 | 0x81 | Colour packet marker (top LED) |
| 1 | R | Red channel (0–255) |
| 2 | G | Green channel (0–255) |
| 3 | B | Blue channel (0–255) |
| 4 | 0x81 | Colour packet marker (bottom LED) |
| 5 | R | Red channel (0–255) |
| 6 | G | Green channel (0–255) |
| 7 | B | Blue channel (0–255) |
| 8–63 | 0x00 | Padding |

### Register Write Packet

Sends a command or parameter to a register on the device.

| Offset | Value | Meaning |
|--------|-------|---------|
| 0 | 0x04 | Register write marker |
| 1 | Register | Register address |
| 2–6 | 0x00 | Reserved, must be zero |
| 7 | Parameter 1 | First parameter (often count or mode) |
| 8 | Parameter 2 | Second parameter (often control flag) |
| 9–63 | 0x00 | Padding |

**Register types and parameters:**

| Register | P1 | P2 | Function |
|----------|----|----|----------|
| 0xF2 | 0 | 1 | Apply colours (commit the last colour packet to the LEDs) |
| 0x53 | count | 0 | Begin save: allocate storage for `count` colour frames |
| 0x02 | 0 | 0 | Commit or finalize operation |
| 0x23 | count | 0 | End save: finalize saving `count` frames |

### End-of-Transfer Packet

Marks the end of a multi-packet sequence and specifies the number of frames.

| Offset | Value | Meaning |
|--------|-------|---------|
| 0 | 0x08 | End-of-transfer marker |
| 1–58 | 0x00 | Padding |
| 59 | 0x28 | Fixed footer byte |
| 60 | frames | Number of frames in this transfer (0–255) |
| 61 | 0x00 | Fixed footer byte |
| 62 | 0xAA | Fixed footer byte |
| 63 | 0x55 | Fixed footer byte |

## Sequences

All sequences use a 15 ms inter-packet delay between sends. Packets are sent in the order specified.

### Direct-Colour Update

Sends colours to the LEDs without persisting them to device memory. The colours remain active only while updates continue to arrive (see Keep-Alive).

**Packets (in order):**

1. Colour packet with both LED colours
2. Apply register (0xF2, P1=0, P2=1)

After the last packet, wait 15 ms before the next sequence.

### Keep-Alive

The microphone reverts to its saved memory colours shortly after direct updates stop (the exact timeout is not known). To maintain direct control:

- Re-send the full Direct-Colour Update every 50 ms, measured from the start of one update to the start of the next.
- If a send fails, the interface is dead; re-discover and try again.

### Save to Device

Persists one static frame to the microphone's memory so it displays those colours without the control application running.

**Note:** This sequence did not persist colours on test hardware (HP QuadCast S, October 2026). Colour persistence in the shipping application is achieved instead by:
- Remembering user-selected colours in application settings.
- Streaming those colours continuously while the app is running (either in a visible window or in the menu bar).
- Optionally starting the app automatically at system login.

**Packets (in order):**

1. Begin-save register (0x53, P1=1, P2=0)
2. Colour packet (same format as Direct-Colour Update)
3. Commit register (0x02, P1=0, P2=0)
4. End-save register (0x23, P1=1, P2=0)
5. End-of-transfer packet (frames=1)
6. Commit register (0x02, P1=0, P2=0)
7. Direct-Colour Update sequence (colour packet + apply register)

Each packet is followed by a 15 ms delay.

## Colour Format and Brightness

### Colour String Format

Colours are accepted in hexadecimal string format:

- Format: 6 hex digits (case-insensitive)
- Optional leading `#` character
- Examples: `FF0000`, `#00FF00`, `0000ff`

Parsing: Extract 6 hex digits, convert to three 8-bit values: R = first two digits, G = second two digits, B = last two digits.

### Brightness Scaling

Colours sent to the device are scaled by a brightness factor before transmission:

1. Accept a brightness value in the range [0.0, 1.0] (clamp to this range if outside).
2. For each colour channel (R, G, B):
   - Multiply the channel value (0–255) by the brightness factor.
   - Round the result to the nearest integer using standard rounding rules (0.5 rounds up).
   - Clamp to [0, 255] if needed (rounding should not exceed this range).

**Example:** Colour 0xC8 (200) with brightness 0.5:
- 200 × 0.5 = 100.0
- Round to 100
- Final value: 100 (0x64)

**Example:** Colour 0x64 (100) with brightness 0.5:
- 100 × 0.5 = 50.0
- Round to 50
- Final value: 50 (0x32)

## Runtime Behaviour

### Colour Persistence

- When the application is actively streaming (sending Direct-Colour Updates at the keep-alive interval), the microphone displays those colours.
- When the application stops streaming or crashes, the microphone reverts to colours stored in its memory shortly afterwards.
- The memory contents are set by the Save to Device sequence (though this did not persist on test hardware).

### Device Re-enumeration

- The lighting device may disconnect and re-enumerate at any time (user disconnect, sleep, internal recovery).
- Any pending I/O operation will fail when this occurs.
- The driver should treat a failed send as a signal to re-discover the device.
- Do not attempt to retry a failed send on a dead interface; re-discover first.

### Concurrency

- Only one process may hold an active stream to the lighting interface.
- If two processes send packets concurrently, the packets will be interleaved on the USB bus, corrupting the colour display.
- Applications should coordinate to ensure exclusive access (for example, via a system-wide lock or daemon architecture where one process owns the device).

## Test Vectors

The following examples are verified on an HP QuadCast S (VID 0x03F0, PID 0x028C) in October 2026.

### Colour Values

- Top LED: Red (0xFF1020, displayed as 100% red, 16% green, 13% blue)
- Bottom LED: Blue (0x0102FE, displayed as 1% red, 1% green, 100% blue)

### Direct Colour Packet (Top: FF1020, Bottom: 0102FE)

Full 64-byte payload in hexadecimal:

```
81 FF 10 20 81 01 02 FE 00 00 00 00 00 00 00 00
00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00
00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00
00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00
```

### Apply (Commit) Packet

Register 0xF2, P1=0, P2=1:

```
04 F2 00 00 00 00 00 00 01 00 00 00 00 00 00 00
00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00
00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00
00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00
```

### End-of-Transfer Packet (1 Frame)

```
08 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00
00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00
00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00
00 00 00 00 00 00 00 00 00 00 00 28 01 00 AA 55
```

### Save Sequence (Top: FF1020, Bottom: 0102FE)

Eight packets in order:

**Packet 1: Begin save (0x53, P1=1)**
```
04 53 00 00 00 00 00 01 00 00 00 00 00 00 00 00
00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00
00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00
00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00
```

**Packet 2: Colour frame**
```
81 FF 10 20 81 01 02 FE 00 00 00 00 00 00 00 00
00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00
00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00
00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00
```

**Packet 3: Commit (0x02)**
```
04 02 00 00 00 00 00 00 00 00 00 00 00 00 00 00
00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00
00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00
00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00
```

**Packet 4: End save (0x23, P1=1)**
```
04 23 00 00 00 00 00 01 00 00 00 00 00 00 00 00
00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00
00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00
00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00
```

**Packet 5: End-of-transfer (frames=1)**
```
08 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00
00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00
00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00
00 00 00 00 00 00 00 00 00 00 00 28 01 00 AA 55
```

**Packet 6: Commit (0x02)**
```
04 02 00 00 00 00 00 00 00 00 00 00 00 00 00 00
00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00
00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00
00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00
```

**Packet 7: Colour frame**
```
81 FF 10 20 81 01 02 FE 00 00 00 00 00 00 00 00
00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00
00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00
00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00
```

**Packet 8: Apply (0xF2, P1=0, P2=1)**
```
04 F2 00 00 00 00 00 00 01 00 00 00 00 00 00 00
00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00
00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00
00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00
```

Between each packet, wait 15 ms before sending the next one.

---

Derived from public community documentation of this device and from testing on an HP QuadCast S (03F0:028C), October 2026.
