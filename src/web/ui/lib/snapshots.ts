export type SnapshotItem = { readonly tag: string; readonly when: string; readonly age: string };

const SECONDS_PER_MINUTE = 60;
const SECONDS_PER_HOUR = 3600;
const SECONDS_PER_DAY = 86_400;
const MS_PER_SECOND = 1000;
const NO_SNAPSHOTS = "(none)";

/** "5 min ago" style age of a `YYYY-MM-DD HH:MM:SS` stamp; empty when it does not parse or lies ahead. */
export const relAge = (stamp: string, now: number = Date.now()): string => {
  const time = Date.parse(stamp.replace(" ", "T"));
  if (Number.isNaN(time)) {
    return "";
  }
  const seconds = Math.floor((now - time) / MS_PER_SECOND);
  if (seconds < 0) {
    return "";
  }
  if (seconds < SECONDS_PER_MINUTE) {
    return "just now";
  }
  if (seconds < SECONDS_PER_HOUR) {
    return `${Math.floor(seconds / SECONDS_PER_MINUTE)} min ago`;
  }
  if (seconds < SECONDS_PER_DAY) {
    return `${Math.floor(seconds / SECONDS_PER_HOUR)} h ago`;
  }
  return `${Math.floor(seconds / SECONDS_PER_DAY)} d ago`;
};

/** Parses `GET /api/vms/<n>/snapshots`: one `tag<TAB>when` line per snapshot, `(none)` when empty. */
export const parseSnapshotList = (text: string, now: number = Date.now()): Array<SnapshotItem> => {
  const body = text.trim();
  if (body === "" || body === NO_SNAPSHOTS) {
    return [];
  }
  const items: Array<SnapshotItem> = [];
  for (const line of body.split("\n")) {
    const [rawTag = "", rawWhen = ""] = line.split("\t");
    const tag = rawTag.trim();
    if (tag !== "") {
      const when = rawWhen.trim();
      items.push({ tag, when, age: when === "" ? "" : relAge(when, now) });
    }
  }
  return items;
};
