import type { Vm } from "@/lib/vm";

const STORAGE_KEY = "hangar.folders";

/** The VM's folder path (a `folder:<path>` tag on the daemon side); empty when it has none. */
export const vmFolder = (vm: Vm): string => vm.folder.trim();

/** Folder names in use, sorted, for the "move to folder" suggestions. */
export const folderNames = (vms: ReadonlyArray<Vm>): Array<string> =>
  [...new Set(vms.map((vm) => vmFolder(vm)).filter((folder) => folder !== ""))].toSorted();

const openState = new Map<string, boolean>();

/** Reads which folders the user collapsed. Storage that is blocked or holds bad JSON leaves every folder open. */
export const loadFolderState = async (): Promise<void> => {
  const stored = await Promise.resolve()
    .then(() => localStorage.getItem(STORAGE_KEY))
    .catch(() => null);
  const parsed: unknown = stored === null ? null : await new Response(stored).json().catch((): undefined => undefined);
  if (typeof parsed === "object" && parsed !== null) {
    for (const [name, open] of Object.entries(parsed)) {
      if (typeof open === "boolean") {
        openState.set(name, open);
      }
    }
  }
};

/** Whether a sidebar folder is expanded; folders start open. */
export const folderOpen = (name: string): boolean => openState.get(name) !== false;

/** Remembers the choice for this page and, where storage allows, for the next visit. */
export const setFolderOpen = (name: string, open: boolean): void => {
  openState.set(name, open);
  Promise.resolve()
    .then(() => localStorage.setItem(STORAGE_KEY, JSON.stringify(Object.fromEntries(openState))))
    .catch(() => undefined);
};
