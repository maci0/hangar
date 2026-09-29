import { describe, expect, test } from "bun:test";
import {
  bodyKeys,
  buildSections,
  fieldLocked,
  firstError,
  initialValues,
  isDirty,
  lockNotice,
  settingsBody,
  validateSettings,
  type HardwareSlots,
} from "@/lib/settings";
import { sampleVm } from "@/lib/vm-fixture";

const SLOTS: HardwareSlots = { nics: 8, extraDisks: 4 };
const sections = buildSections(SLOTS);
const fresh = () => initialValues(sampleVm(), sections);

describe("sections", () => {
  test("keep the nav order and ids", () => {
    expect(sections.map((section) => section.id)).toEqual([
      "basic",
      "network_and_boot",
      "sharing",
      "autoprotect",
      "display_and_video",
      "storage_and_notes",
      "extra_disks",
      "advanced",
    ]);
  });

  test("follow the daemon's slot counts", () => {
    const small = buildSections({ nics: 3, extraDisks: 1 });
    const keys = small.flatMap((section) => section.fields.map((field) => field.key));
    expect(keys).toContain("nic3_vnet");
    expect(keys).not.toContain("nic4");
    expect(keys).toContain("extra0_format");
    expect(keys).not.toContain("extra1_path");
  });

  test("hold exactly the fields the request body carries", () => {
    const shown = sections.flatMap((section) => section.fields.map((field) => field.key)).toSorted();
    expect(shown).toEqual(bodyKeys(SLOTS).toSorted());
    expect(new Set(shown).size).toBe(shown.length);
  });
});

describe("initialValues", () => {
  test("read the VM the way the form always has", () => {
    const values = initialValues(
      sampleVm({ mem: 0, guest_tools: "true", hasSerial: "true", fw: "uefi", nic2_mode: "bridge", extra1_size: 40, autoprotect_interval: 0 }),
      sections,
    );
    expect(values.mem).toBe("2048");
    expect(values.guest_tools).toBe("1");
    expect(values.enable_serial).toBe("1");
    expect(values.firmware).toBe("uefi");
    expect(values.nic2).toBe("bridge");
    expect(values.nic3).toBe("none");
    expect(values.extra1_size).toBe("40");
    expect(values.ap_interval).toBe("60");
    expect(values.cloud_init).toBe("");
  });

  test("a select holding an unknown value starts on its first option", () => {
    expect(initialValues(sampleVm({ cpu_model: "Zen9" }), sections).cpu_model).toBe("host");
    expect(initialValues(sampleVm({ net: "tap0" }), sections).network).toBe("user");
  });
});

describe("settingsBody", () => {
  test("is the payload the daemon has always received", () => {
    expect(settingsBody(fresh(), SLOTS)).toBe(
      "name=web-01&mem=2048&cpu=2&cpu_sockets=1&cpu_model=host&disk=20&disk_format=0&disk_cache=0&iso_path=&mac_address=&network=user" +
        "&vnet=&firmware=bios&shared_folder=&usb=&usb_policy=0&guest_tools=0&autoprotect=0&ap_interval=60&ap_max=10&disk2_path=" +
        "&disk2_size=0&disk2_format=0&floppy=&portfw=&notes=&tags=&cloud_init=&enable_3d=0&gpu_device=2&display=3" +
        "&display_resolution=0&guest_os=0&audio=0&boot_order=0&rtc=0&accel=auto&embed_display=1&vnc_port=5900&spice_port=5901" +
        "&enable_serial=0&num_displays=1&favorite=0&guest_agent=0&virtio_rng=0&tpm=0&secure_boot=0&hyperv_enlightenments=0" +
        "&hugepages=0&watchdog=0&ballooning=0&host_autostart=0&io_threads=0&disk_bps_throttle=0&disk_iops_throttle=0" +
        "&video_stream=0&video_bitrate=0" +
        "&nic2=none&nic2_mac=&nic2_vnet=&nic3=none&nic3_mac=&nic3_vnet=&nic4=none&nic4_mac=&nic4_vnet=&nic5=none&nic5_mac=&nic5_vnet=" +
        "&nic6=none&nic6_mac=&nic6_vnet=&nic7=none&nic7_mac=&nic7_vnet=&nic8=none&nic8_mac=&nic8_vnet=" +
        "&extra0_path=&extra0_size=0&extra0_format=0&extra1_path=&extra1_size=0&extra1_format=0" +
        "&extra2_path=&extra2_size=0&extra2_format=0&extra3_path=&extra3_size=0&extra3_format=0",
    );
  });

  test("percent-encodes user text", () => {
    const body = settingsBody({ ...fresh(), name: "a b&c=d", notes: "x\ny" }, SLOTS);
    expect(body).toContain("name=a%20b%26c%3Dd&");
    expect(body).toContain("&notes=x%0Ay&");
  });
});

describe("isDirty", () => {
  test("is false until a value differs, and false again when it is put back", () => {
    const initial = fresh();
    expect(isDirty(initial, initial)).toBe(false);
    expect(isDirty({ ...initial, notes: "hi" }, initial)).toBe(true);
    expect(isDirty({ ...initial, notes: "" }, initial)).toBe(false);
  });
});

describe("validateSettings", () => {
  test("accepts a fresh form", () => {
    expect(validateSettings(fresh(), SLOTS)).toEqual({});
  });

  test("requires a name that is not blank", () => {
    expect(validateSettings({ ...fresh(), name: "   " }, SLOTS).name).toEqual({ message: "Name is required.", severity: "error" });
  });

  test("checks the memory, cpu and disk ranges", () => {
    const issues = validateSettings({ ...fresh(), mem: "127", cpu: "0", disk: "65537" }, SLOTS);
    expect(issues.mem?.message).toBe("Memory must be 128-65536 MB.");
    expect(issues.cpu?.message).toBe("CPU cores must be 1-256.");
    expect(issues.disk?.message).toBe("Disk size must be 1-65536 GB.");
    expect(validateSettings({ ...fresh(), mem: "", cpu: "256" }, SLOTS).mem).toBeDefined();
    expect(validateSettings({ ...fresh(), mem: "128", cpu: "256", disk: "65536" }, SLOTS)).toEqual({});
  });

  test("checks the MAC of the first and every extra NIC", () => {
    const issues = validateSettings({ ...fresh(), mac_address: "zz", nic8_mac: "52:54:00:12:34:5" }, SLOTS);
    expect(issues.mac_address?.message).toBe("Use XX:XX:XX:XX:XX:XX.");
    expect(issues.nic8_mac).toBeDefined();
    expect(validateSettings({ ...fresh(), mac_address: "52:54:00:12:34:56", nic2_mac: "52-54-00-12-34-56" }, SLOTS)).toEqual({});
  });

  test("checks the display ports", () => {
    expect(validateSettings({ ...fresh(), vnc_port: "0" }, SLOTS).vnc_port?.message).toBe("Port must be 1-65535.");
    expect(validateSettings({ ...fresh(), spice_port: "65536" }, SLOTS).spice_port).toBeDefined();
  });

  test("accepts both port forward notations and rejects the rest", () => {
    expect(validateSettings({ ...fresh(), portfw: "8080:80, 2222:22" }, SLOTS)).toEqual({});
    expect(validateSettings({ ...fresh(), portfw: "8080:10.0.2.15:80" }, SLOTS)).toEqual({});
    expect(validateSettings({ ...fresh(), portfw: "8080" }, SLOTS).portfw?.message).toBe("Use host:guest or host:ip:guest entries.");
  });

  test("warns, without blocking, when the embedded display cannot show in the browser", () => {
    const issues = validateSettings({ ...fresh(), embed_display: "1", display: "0" }, SLOTS);
    expect(issues.display?.severity).toBe("warning");
    expect(firstError(sections, issues)).toBeNull();
  });

  test("warns about virgl over VNC", () => {
    const issues = validateSettings({ ...fresh(), embed_display: "1", display: "3", enable_3d: "1", gpu_device: "0" }, SLOTS);
    expect(issues.gpu_device?.severity).toBe("warning");
    expect(firstError(sections, issues)).toBeNull();
  });

  test("firstError names the first blocking field in nav order and its section", () => {
    const issues = validateSettings({ ...fresh(), name: "", vnc_port: "0", mac_address: "zz" }, SLOTS);
    expect(firstError(sections, issues)).toEqual({ key: "name", section: "basic" });
    expect(firstError(sections, validateSettings({ ...fresh(), vnc_port: "0", mac_address: "zz" }, SLOTS))).toEqual({
      key: "mac_address",
      section: "network_and_boot",
    });
  });
});

describe("locking", () => {
  test("a live or saved VM keeps identity fields editable and locks hardware", () => {
    for (const status of ["running", "paused", "suspended"] as const) {
      expect(fieldLocked("mem", status)).toBe(true);
      expect(fieldLocked("iso_path", status)).toBe(true);
      expect(fieldLocked("name", status)).toBe(false);
      expect(fieldLocked("autoprotect", status)).toBe(false);
    }
  });

  test("a stopped VM has nothing locked", () => {
    expect(fieldLocked("mem", "stopped")).toBe(false);
  });

  test("the notice names the state", () => {
    expect(lockNotice("paused")).toStartWith("This VM is paused: virtual hardware is locked.");
  });
});
