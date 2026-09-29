const MIB_PER_GIB = 1024;
const TENTHS = 10;
const BYTE_UNITS: ReadonlyArray<string> = ["B", "KiB", "MiB", "GiB", "TiB"];
const BYTES_PER_UNIT = 1024;
const FRACTION_DIGITS = 1;

const finiteOrZero = (quantity: number): number => (Number.isFinite(quantity) ? quantity : 0);

/** Binary gibibytes from the daemon's MiB, rounded to a tenth. Never a decimal "GB". */
export const memGiB = (mib: number): number => Math.round((finiteOrZero(mib) / MIB_PER_GIB) * TENTHS) / TENTHS;

/** Memory label from exact MiB: `512 MiB`, or `GiB` from 1024 up. */
export const memText = (mib: number): string => {
  const exact = finiteOrZero(mib);
  return exact >= MIB_PER_GIB ? `${memGiB(exact)} GiB` : `${exact} MiB`;
};

/** Byte count in binary units, or `?` when it is not a usable size. */
export const fmtBytes = (bytes: number): string => {
  if (!Number.isFinite(bytes) || bytes < 0) {
    return "?";
  }
  let unit = 0;
  let scaled = bytes;
  while (scaled >= BYTES_PER_UNIT && unit < BYTE_UNITS.length - 1) {
    scaled /= BYTES_PER_UNIT;
    unit += 1;
  }
  return `${unit === 0 ? scaled : scaled.toFixed(FRACTION_DIGITS)} ${BYTE_UNITS[unit] ?? ""}`;
};

const STATUS_LABELS: Readonly<Record<string, string>> = {
  running: "Running",
  paused: "Paused",
  suspended: "Suspended",
  stopped: "Stopped",
};

/** Display name of a VM status; an unknown value is shown as it came. */
export const statusLabel = (status: string): string => STATUS_LABELS[status] ?? (status === "" ? "Unknown" : status);

const FOLDER_TAG_PREFIX = "folder:";

/** Tags a user sees: the structural `folder:<path>` tag is not one of them. */
export const visibleTags = (tags: string): ReadonlyArray<string> =>
  tags
    .split(",")
    .map((tag) => tag.trim())
    .filter((tag) => tag !== "" && !tag.toLowerCase().startsWith(FOLDER_TAG_PREFIX));

const PERCENT = 100;

/** Whole-number percent of `part` in `whole`, capped at 100; 0 when `whole` is not positive. */
export const percentOf = (part: number, whole: number): number =>
  whole > 0 ? Math.min(PERCENT, Math.round((part / whole) * PERCENT)) : 0;
