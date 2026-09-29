import type { CatalogEntry } from "@/components/dialogs/catalog";
import { memText } from "@/lib/format";
import { osBrand } from "@/lib/os-brand";
import { listOf } from "@/lib/wire";

const GUEST_OS_LABELS: ReadonlyArray<string> = ["Linux", "Windows", "FreeBSD", "macOS", "Other"];
const OTHER_OS = "Other";

/** One template of `GET /api/catalog` as a card; null when it lacks an id or a name. */
const catalogEntry = (template: unknown): CatalogEntry | null => {
  if (typeof template !== "object" || template === null) {
    return null;
  }
  const id = "id" in template && typeof template.id === "string" ? template.id : "";
  const name = "name" in template && typeof template.name === "string" ? template.name : "";
  if (id === "" || name === "") {
    return null;
  }
  const family = "guest_os" in template && typeof template.guest_os === "number" ? template.guest_os : -1;
  const os = GUEST_OS_LABELS[family] ?? OTHER_OS;
  const brand = osBrand(`${name} ${id}`, os);
  return {
    id,
    name,
    os,
    description: "description" in template && typeof template.description === "string" ? template.description : "",
    cpuCores: "cpu_cores" in template && typeof template.cpu_cores === "number" ? template.cpu_cores : 0,
    memory: memText("memory_mb" in template && typeof template.memory_mb === "number" ? template.memory_mb : 0),
    diskGb: "disk_size_gb" in template && typeof template.disk_size_gb === "number" ? template.disk_size_gb : 0,
    brandColor: brand.color,
    monogram: brand.text,
  };
};

/** Cards for `GET /api/catalog`; entries that cannot be shown are skipped. */
export const parseCatalog = (body: unknown): Array<CatalogEntry> =>
  (listOf(body) ?? []).map((template) => catalogEntry(template)).filter((entry) => entry !== null);
